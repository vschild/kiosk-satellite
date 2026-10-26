import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The system image's update as its updater reports it.
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

/// A newer image the device moves to by hand, because its updater cannot
/// install it: the Echo Dot's LineageOS 18.1 image on a Dot that runs the
/// CM14.1 one, where the move needs an erased data partition.
@immutable
class ImageSuccessor {
  const ImageSuccessor({
    required this.repository,
    required this.device,
    required this.guide,
  });

  /// The new image's repository, as owner/name.
  final String repository;

  /// The device's codename (`ro.product.device`). Each device has releases
  /// of its own in the repository, tagged with its codename and a dash.
  final String device;

  /// How to move to the new image.
  final String guide;

  Uri get releasesUrl => Uri.parse(
    'https://api.github.com/repos/$repository/releases?per_page=100',
  );
}

/// The image's own updater, which checks the image's releases, downloads
/// and installs them. SystemUpdateManager turns it into the remote admin's
/// update rows and the Home Assistant Firmware entity, so another updater
/// plugs in here without touching either.
abstract interface class SystemUpdateSource {
  /// What the Firmware entity calls the image.
  String get title;

  /// The image's source code on GitHub.
  String get repository;

  /// The image this one moves to by hand, or null when its updater has the
  /// newest image.
  ImageSuccessor? get successor;

  /// The updater's status, or null when it did not answer.
  Future<SystemUpdateStatus?> status();

  /// Starts a check for a newer release. The status says when it ends.
  Future<void> check();

  /// Starts downloading and installing the newer release. False when the
  /// updater refused.
  Future<bool> install();

  /// Calls [onChanged] whenever the updater reports a change of its own.
  void listen(VoidCallback onChanged);
}

/// The updater of a Kiosk Satellite Edition ROM, reached through
/// SystemUpdateBridge.kt. The Echo Dot image runs BiscuitService and the
/// Echo Show images run EchoService. Both keep one contract and install the
/// newest release through TWRP, so only what the remote admin and the
/// Firmware entity call the image differs.
abstract class RomSystemUpdateSource implements SystemUpdateSource {
  static const _channel = MethodChannel('kiosk_satellite/system_update');

  static const image = 'jxlarrea/lineageos-echo-kiosk-satellite';

  /// The ROM's updater, read from its property on any device: `biscuit`
  /// (`ro.biscuit.ota`), `echo` (`ro.echo.ota`) or null.
  static Future<String?> detect() => _channel.invokeMethod<String>('updater');

  @override
  Future<SystemUpdateStatus?> status() async {
    final raw = await _channel.invokeMethod<String>('status');
    if (raw == null || raw.isEmpty) return null;
    return SystemUpdateStatus.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<void> check() => _channel.invokeMethod<bool>('check');

  @override
  Future<bool> install() async =>
      await _channel.invokeMethod<bool>('install') ?? false;

  @override
  void listen(VoidCallback onChanged) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') onChanged();
      return null;
    });
  }
}

/// BiscuitService, inside the Echo Dot image's system_server. It installs
/// the newest release through TWRP, rebooting twice. Both Dot images have
/// it (`ro.biscuit.ota`), each reading the releases of its own repository.
class BiscuitSystemUpdateSource extends RomSystemUpdateSource {
  BiscuitSystemUpdateSource({required this.sdkInt, required this.device});

  /// The CM14.1 image, which gets no more releases.
  static const _cm14Image = 'jxlarrea/lineageos-biscuit-kiosk-satellite';

  static const guide =
      'https://github.com/${RomSystemUpdateSource.image}/blob/main/docs/'
      'echo-dot.md#moving-from-the-cm141-image';

  /// Android 7.1 on the CM14.1 image, Android 11 on the new one.
  final int sdkInt;
  final String device;

  bool get _cm14 => sdkInt < 30;

  @override
  String get title => 'LineageOS for the Echo Dot';

  @override
  String get repository =>
      'https://github.com/${_cm14 ? _cm14Image : RomSystemUpdateSource.image}';

  @override
  ImageSuccessor? get successor => _cm14
      ? ImageSuccessor(
          repository: RomSystemUpdateSource.image,
          device: device,
          guide: guide,
        )
      : null;
}

/// EchoService, the Echo Show images' updater (`ro.echo.ota`). It reads
/// only the releases tagged with the Show's codename.
class EchoSystemUpdateSource extends RomSystemUpdateSource {
  @override
  String get title => 'LineageOS for the Echo Show';

  @override
  String get repository => 'https://github.com/${RomSystemUpdateSource.image}';

  @override
  ImageSuccessor? get successor => null;
}
