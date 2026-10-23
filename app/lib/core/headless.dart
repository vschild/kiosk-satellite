import 'package:flutter/services.dart';

/// Whether this device runs without a screen (Headless.kt).
///
/// Speaker hardware running Android, such as an Echo Dot on LineageOS,
/// reports a 1x1 stub display. The kiosk runs headless there: no Activity,
/// no WebView, no screensaver and no cameras, with voice, audio and the
/// remote admin carrying the device. Read once before the container starts,
/// so every manager's init sees the answer.
abstract final class Headless {
  static const _channel = MethodChannel('kiosk_satellite/background');

  static bool _active = false;

  static bool _volumeClaim = false;

  static bool _pryon = false;

  static bool _systemUpdate = false;

  static bool get active => _active;

  /// Whether the ROM lets the kiosk claim the volume buttons, so they can
  /// steer a player or a group instead of the device's own volume
  /// (BiscuitVolumeButtons.kt). Only on a device without a screen.
  static bool get volumeClaim => _volumeClaim;

  /// Whether the ROM runs Amazon's wake word engine as a service
  /// (PryonCatalog). Only on a device without a screen.
  static bool get pryon => _pryon;

  /// Whether the ROM updates itself from its GitHub releases
  /// (SystemUpdateManager). Only on a device without a screen.
  static bool get systemUpdate => _systemUpdate;

  static Future<void> detect() async {
    try {
      _active = await _channel.invokeMethod<bool>('isHeadless') ?? false;
      if (_active) {
        _volumeClaim =
            await _channel.invokeMethod<bool>('volumeClaim') ?? false;
        _pryon = await _channel.invokeMethod<bool>('pryon') ?? false;
        _systemUpdate =
            await _channel.invokeMethod<bool>('systemUpdate') ?? false;
      }
    } catch (_) {
      // No native side (a test): a device with a screen.
    }
  }

  /// Tests only.
  static set debugActive(bool value) => _active = value;

  /// Tests only.
  static set debugVolumeClaim(bool value) => _volumeClaim = value;

  /// Tests only.
  static set debugPryon(bool value) => _pryon = value;

  /// Tests only.
  static set debugSystemUpdate(bool value) => _systemUpdate = value;
}
