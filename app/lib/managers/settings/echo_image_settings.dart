import 'dart:async';

import '../../core/event_bus.dart';
import '../../core/events.dart';
import '../../core/logging.dart';
import '../update/system_update_source.dart';
import 'definitions.dart' as defs;
import 'settings_manager.dart';

/// Settings the Echo images (`jxlarrea/lineageos-echo-kiosk-satellite`)
/// hold at one value on every start, unlike EchoDefaults
/// (echo_defaults.dart), which only sets a fresh install's first values.
///
/// The images always record from the raw microphone in the automatic
/// format, so Capture mode and Capture format are hidden
/// from both settings UIs and kept on Raw microphone and Automatic. A
/// value stored before, imported or pushed by Fleet goes back, at boot and
/// on any later change, the same way HeadlessSettings
/// (headless_settings.dart) pins its values.
///
/// The image is told apart by its updater (SystemUpdateBridge.kt): `biscuit`
/// is the Echo Dot image and `echo` an Echo Show image.
class EchoImageSettings {
  EchoImageSettings(
    this._settings,
    this._bus,
    this._log, {
    this.updater = RomSystemUpdateSource.detect,
  });

  final SettingsManager _settings;
  final EventBus _bus;
  final Logger _log;

  /// The ROM's updater (SystemUpdateBridge.kt). Tests swap it.
  final Future<String?> Function() updater;

  StreamSubscription<SettingChanged>? _sub;

  /// The values each updater pins.
  static Map<defs.SettingDef<Object>, Object> forUpdater(String? updater) =>
      switch (updater) {
        'biscuit' ||
        'echo' => {defs.micCaptureMode: 'mic', defs.micCaptureFormat: 'auto'},
        _ => const {},
      };

  /// Before any manager reads its settings and any page renders.
  Future<void> init() async {
    String? rom;
    try {
      rom = await updater();
    } catch (_) {
      // No native side (a test, another platform): not an Echo image.
      return;
    }
    final pinned = forUpdater(rom);
    if (pinned.isEmpty) return;
    for (final entry in pinned.entries) {
      defs.deviceHiddenKeys.add(entry.key.key);
      defs.devicePinnedKeys.add(entry.key.key);
      await _pin(entry.key, entry.value);
    }
    _sub = _bus.on<SettingChanged>().listen((e) {
      for (final entry in pinned.entries) {
        if (entry.key.key == e.key) unawaited(_pin(entry.key, entry.value));
      }
    });
  }

  Future<void> _pin(defs.SettingDef<Object> def, Object value) async {
    if (_settings.get(def) == value) return;
    _log.info('settings', '${def.key} is $value on the Echo image');
    await _settings.set(def, value, source: 'Echo image');
  }

  Future<void> dispose() async => _sub?.cancel();
}
