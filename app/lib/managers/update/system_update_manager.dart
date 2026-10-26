import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import 'system_update_source.dart';
import 'update_http_client.dart';

export 'system_update_source.dart';

/// A release of the image the device moves to by hand ([ImageSuccessor]).
@immutable
class ManualImageUpdate {
  const ManualImageUpdate({
    required this.version,
    required this.notes,
    required this.url,
  });

  /// The release, such as 2026.10.6, without the device's tag prefix.
  final String version;

  /// The release's notes.
  final String notes;

  /// The guide to the move.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is ManualImageUpdate &&
      other.version == version &&
      other.notes == notes &&
      other.url == url;

  @override
  int get hashCode => Object.hash(version, notes, url);
}

/// System updates of the system image, through its own updater
/// ([SystemUpdateSource]).
///
/// The updater checks the image's GitHub releases itself and installs the
/// newest, rebooting the device. This manager relays that to the remote
/// admin's About page and the Home Assistant Firmware entity. On an image
/// that moves to a newer one by hand, it also reads the new image's
/// releases and reports the newest as an update to install by hand. On a
/// device whose image has no updater it registers its commands and reports
/// itself unsupported.
class SystemUpdateManager extends Manager {
  SystemUpdateManager(super.bus, super.commands, super.log);

  @override
  String get name => 'system-update';

  /// The longest a check waits for GitHub before reporting what it has.
  static const _checkWait = Duration(seconds: 45);

  final status = ValueNotifier<SystemUpdateStatus?>(null);

  /// The newest release of the image this one moves to by hand, if any.
  final manual = ValueNotifier<ManualImageUpdate?>(null);

  /// Finds the image's updater, null when the image has none. Tests swap
  /// it.
  Future<SystemUpdateSource?> Function() detectSource = _detectSource;

  /// The client for the successor image's releases. Tests swap it.
  http.Client Function() clientFactory = createUpdateHttpClient;

  SystemUpdateSource? _source;

  bool get supported => _source != null;

  Timer? _timer;

  static Future<SystemUpdateSource?> _detectSource() async {
    switch (await RomSystemUpdateSource.detect()) {
      case 'biscuit':
        final android = await DeviceInfoPlugin().androidInfo;
        return BiscuitSystemUpdateSource(
          sdkInt: android.version.sdkInt,
          device: android.device,
        );
      case 'echo':
        return EchoSystemUpdateSource();
    }
    return null;
  }

  @override
  Future<void> init() async {
    try {
      _source = await detectSource();
    } catch (e) {
      log.warn(name, 'could not detect the system updater: $e');
    }
    commands
      ..register(
        Command(
          name: 'getSystemUpdateStatus',
          description:
              'The system image release, the newer GitHub release if any, '
              'and the state of its download and install. manualVersion is '
              'a newer image that installs by hand, with its guide in '
              'manualUrl. supported=false on a device whose image does not '
              'update itself',
          quiet: true,
          handler: (_) async {
            if (!supported) return const CommandResult.ok({'supported': false});
            await refresh();
            final s = status.value;
            if (s == null) return _noAnswer();
            return CommandResult.ok(_json(s));
          },
        ),
      )
      ..register(
        Command(
          name: 'checkSystemUpdateNow',
          description:
              'Ask GitHub for a newer system image release now and report '
              'the result in getSystemUpdateStatus shape, plus '
              'reachable=false when GitHub could not be queried',
          handler: (_) async {
            if (!supported) return _unsupported();
            final s = await check();
            if (s == null) return _noAnswer();
            return CommandResult.ok({
              ..._json(s),
              'reachable': s.checkError.isEmpty,
            });
          },
        ),
      )
      ..register(
        Command(
          name: 'installSystemUpdate',
          description:
              'Download the newer system image release, check its signature '
              'and install it. The device reboots into TWRP and back and is '
              'offline meanwhile',
          handler: (_) async {
            if (!supported) return _unsupported();
            await refresh();
            final s = status.value;
            if (s == null) return _noAnswer();
            if (s.busy) {
              return CommandResult.fail('an update is already running');
            }
            if (!s.available) {
              final m = manual.value;
              if (m != null) {
                return CommandResult.fail(
                  'version ${m.version} is a new image that installs by '
                  'hand, see ${m.url}',
                );
              }
              return CommandResult.fail('no update available');
            }
            if (!await install()) {
              return CommandResult.fail('the update did not start');
            }
            return const CommandResult.ok(true);
          },
        ),
      );
    final source = _source;
    if (source == null) return;
    source.listen(() => unawaited(refresh()));
    await refresh();
    unawaited(_checkSuccessor());
    // The image checks a minute after every boot. A device that runs for
    // weeks also hears about a release through this.
    _timer = Timer.periodic(
      const Duration(hours: 12),
      (_) => unawaited(check()),
    );
  }

  CommandResult _unsupported() =>
      CommandResult.fail('system updates need the Echo Dot or Echo Show image');

  CommandResult _noAnswer() =>
      CommandResult.fail('the system updater did not answer');

  Map<String, Object?> _json(SystemUpdateStatus s) {
    final m = manual.value;
    return {
      ...s.toJson(),
      'title': _source?.title,
      'repository': _source?.repository,
      'manualVersion': m?.version,
      'manualNotes': m?.notes,
      'manualUrl': m?.url,
    };
  }

  /// Reads the status again and publishes it when it changed.
  Future<void> refresh() async {
    final source = _source;
    if (source == null) return;
    SystemUpdateStatus? next;
    try {
      next = await source.status();
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
  /// the updater could not be reached.
  Future<SystemUpdateStatus?> check() async {
    final source = _source;
    if (source == null) return null;
    final successor = _checkSuccessor();
    try {
      return await _checkSource(source);
    } finally {
      await successor;
    }
  }

  Future<SystemUpdateStatus?> _checkSource(SystemUpdateSource source) async {
    await refresh();
    final before = status.value;
    if (before == null) return null;
    if (before.busy) return before;
    try {
      await source.check();
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
    final source = _source;
    if (source == null) return false;
    try {
      final started = await source.install();
      log.info(name, 'install ${started ? 'started' : 'refused'}');
      await refresh();
      return started;
    } catch (e) {
      log.warn(name, 'install failed: $e');
      return false;
    }
  }

  /// Reads the releases of the image this one moves to by hand, which its
  /// updater never sees. Keeps what it knew when GitHub does not answer.
  Future<void> _checkSuccessor() async {
    final successor = _source?.successor;
    if (successor == null) return;
    final client = clientFactory();
    try {
      final res = await client
          .get(
            successor.releasesUrl,
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(_checkWait);
      if (res.statusCode != 200) {
        log.warn(
          name,
          'new image check failed: HTTP ${res.statusCode} from '
          '${successor.repository}',
        );
        return;
      }
      final next = newestManualUpdate(
        jsonDecode(res.body) as List<Object?>,
        successor,
      );
      if (next == manual.value) return;
      log.info(
        name,
        next == null
            ? 'no ${successor.device} release in ${successor.repository}'
            : 'new image ${next.version} in ${successor.repository}, '
                  'installs by hand',
      );
      manual.value = next;
      bus.publish(const SystemUpdateStateChanged());
    } catch (e) {
      log.warn(name, 'new image check failed: $e');
    } finally {
      client.close();
    }
  }

  /// The newest of the device's own releases in a GitHub releases list:
  /// tagged with its codename and a dash, neither draft nor prerelease.
  /// Never GitHub's latest release, which can be another device's.
  @visibleForTesting
  static ManualImageUpdate? newestManualUpdate(
    List<Object?> releases,
    ImageSuccessor successor,
  ) {
    final prefix = '${successor.device}-';
    ManualImageUpdate? newest;
    List<int>? newestParts;
    for (final r in releases.whereType<Map<Object?, Object?>>()) {
      if (r['draft'] == true || r['prerelease'] == true) continue;
      final tag = r['tag_name'];
      if (tag is! String || !tag.startsWith(prefix)) continue;
      final version = tag.substring(prefix.length);
      final parts = _versionParts(version);
      if (parts == null) continue;
      if (newestParts != null && _compare(parts, newestParts) <= 0) continue;
      newestParts = parts;
      newest = ManualImageUpdate(
        version: version,
        notes: r['body'] is String ? (r['body'] as String).trim() : '',
        url: successor.guide,
      );
    }
    return newest;
  }

  static List<int>? _versionParts(String version) {
    final parts = version.split('.').map(int.tryParse).toList();
    if (parts.isEmpty || parts.contains(null)) return null;
    return parts.cast<int>();
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length || i < b.length; i++) {
      final d = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
  }
}
