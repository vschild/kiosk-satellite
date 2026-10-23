import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/headless.dart';
import '../../core/manager.dart';

/// The ROM's system update as BiscuitService reports it.
@immutable
class SystemUpdateStatus {
  const SystemUpdateStatus({
    required this.current,
    required this.latest,
    required this.available,
    required this.notes,
    required this.url,
    required this.state,
    required this.progress,
    required this.error,
    required this.checkError,
    required this.checked,
  });

  factory SystemUpdateStatus.fromJson(Map<String, Object?> json) {
    String s(String key) => json[key] is String ? json[key] as String : '';
    final progress = json['progress'];
    final checked = json['checked'];
    return SystemUpdateStatus(
      current: s('current'),
      latest: s('latest'),
      available: json['available'] == true,
      notes: s('notes'),
      url: s('url'),
      state: s('state').isEmpty ? 'idle' : s('state'),
      progress: progress is num ? progress.toDouble().clamp(0.0, 1.0) : null,
      error: s('error'),
      checkError: s('checkError'),
      checked: checked is num ? checked.toInt() : 0,
    );
  }

  /// The installed image release, such as 2026.10.4.
  final String current;

  /// The newest release on GitHub, or [current] when there is none.
  final String latest;
  final bool available;

  /// What changed since [current]: every newer release's notes, newest
  /// first, each under a "# Version" heading.
  final String notes;

  /// The newest release's GitHub page.
  final String url;

  /// idle, checking, downloading, verifying, installing or failed.
  final String state;

  /// 0 to 1 while downloading or installing, otherwise null.
  final double? progress;

  /// Why the last install failed, empty when it did not.
  final String error;

  /// Why the last check failed, empty when it did not.
  final String checkError;

  /// When GitHub last answered, in milliseconds since the epoch, 0 before.
  final int checked;

  /// A download or install runs: no check or second install until it ends.
  bool get busy =>
      state == 'downloading' || state == 'verifying' || state == 'installing';

  Map<String, Object?> toJson() => {
    'supported': true,
    'currentVersion': current,
    'availableVersion': available ? latest : null,
    'availableNotes': available ? notes : null,
    'releaseUrl': url,
    'state': state,
    'progress': progress,
    'lastError': error,
    'checkError': checkError,
    'checked': checked,
  };
}

/// System updates of the Echo Dot's Kiosk Satellite Edition image
/// (BiscuitSystemUpdate.kt).
///
/// The image checks its GitHub releases itself, a minute after every boot
/// and when asked, and installs the newest through TWRP: it downloads the
/// zip, checks its signature and reboots twice, once for each slot, taking
/// the kiosk with it. This manager relays that to the remote admin's About
/// page and the Home Assistant Firmware entity. Elsewhere it registers its
/// commands and reports itself unsupported.
class SystemUpdateManager extends Manager {
  SystemUpdateManager(super.bus, super.commands, super.log);

  @override
  String get name => 'system-update';

  static const _channel = MethodChannel('kiosk_satellite/system_update');

  /// The longest a check waits for GitHub before reporting what it has.
  static const _checkWait = Duration(seconds: 45);

  final status = ValueNotifier<SystemUpdateStatus?>(null);

  bool get supported => Headless.systemUpdate;

  Timer? _timer;

  @override
  Future<void> init() async {
    commands
      ..register(
        Command(
          name: 'getSystemUpdateStatus',
          description:
              'The Echo Dot image release, the newer GitHub release if any, '
              'and the state of its download and install. supported=false '
              'on any other device',
          quiet: true,
          handler: (_) async {
            if (!supported) return const CommandResult.ok({'supported': false});
            await refresh();
            final s = status.value;
            if (s == null) {
              return CommandResult.fail('BiscuitService did not answer');
            }
            return CommandResult.ok(s.toJson());
          },
        ),
      )
      ..register(
        Command(
          name: 'checkSystemUpdateNow',
          description:
              'Ask GitHub for a newer Echo Dot image release now and report '
              'the result in getSystemUpdateStatus shape, plus '
              'reachable=false when GitHub could not be queried',
          handler: (_) async {
            if (!supported) return _unsupported();
            final s = await check();
            if (s == null) {
              return CommandResult.fail('BiscuitService did not answer');
            }
            return CommandResult.ok({
              ...s.toJson(),
              'reachable': s.checkError.isEmpty,
            });
          },
        ),
      )
      ..register(
        Command(
          name: 'installSystemUpdate',
          description:
              'Download the newer Echo Dot image release, check its '
              'signature and install it. The Dot reboots into TWRP twice and '
              'is offline for about a minute and a half each time',
          handler: (_) async {
            if (!supported) return _unsupported();
            await refresh();
            final s = status.value;
            if (s == null) {
              return CommandResult.fail('BiscuitService did not answer');
            }
            if (s.busy) {
              return CommandResult.fail('an update is already running');
            }
            if (!s.available) {
              return CommandResult.fail('no update available');
            }
            if (!await install()) {
              return CommandResult.fail('the update did not start');
            }
            return const CommandResult.ok(true);
          },
        ),
      );
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
      return null;
    });
    await refresh();
    // The image checks a minute after every boot. A Dot that runs for
    // weeks also hears about a release through this.
    _timer = Timer.periodic(
      const Duration(hours: 12),
      (_) => unawaited(check()),
    );
  }

  CommandResult _unsupported() =>
      CommandResult.fail('system updates need the Echo Dot image');

  /// Reads the status again and publishes it when it changed.
  Future<void> refresh() async {
    if (!supported) return;
    SystemUpdateStatus? next;
    try {
      final raw = await _channel.invokeMethod<String>('status');
      if (raw != null && raw.isNotEmpty) {
        next = SystemUpdateStatus.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
      }
    } catch (e) {
      log.warn(name, 'status failed: $e');
    }
    if (next == null) return;
    final changed =
        jsonEncode(next.toJson()) != jsonEncode(status.value?.toJson());
    status.value = next;
    if (changed) bus.publish(const SystemUpdateStateChanged());
  }

  /// Asks GitHub through the image and waits for the answer. Null when
  /// BiscuitService could not be reached.
  Future<SystemUpdateStatus?> check() async {
    if (!supported) return null;
    await refresh();
    final before = status.value;
    if (before == null) return null;
    if (before.busy) return before;
    try {
      await _channel.invokeMethod<bool>('check');
    } catch (e) {
      log.warn(name, 'check failed: $e');
      return before;
    }
    final deadline = DateTime.now().add(_checkWait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      final s = status.value;
      if (s != null && s.state != 'checking') return s;
    }
    return status.value;
  }

  Future<bool> install() async {
    try {
      final started = await _channel.invokeMethod<bool>('install') ?? false;
      log.info(name, 'install ${started ? 'started' : 'refused'}');
      await refresh();
      return started;
    } catch (e) {
      log.warn(name, 'install failed: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
  }
}
