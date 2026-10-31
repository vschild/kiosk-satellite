import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/echo_image_settings.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Echo images keep Capture mode and Capture format hidden and on the
/// raw microphone and the automatic format on every start, whatever was
/// stored before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late Logger log;
  late SettingsManager settings;
  EchoImageSettings? pins;

  Future<void> boot(Map<String, Object> prefs, String? updater) async {
    SharedPreferences.setMockInitialValues(prefs);
    bus = EventBus();
    log = Logger();
    settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    pins = EchoImageSettings(settings, bus, log, updater: () async => updater);
    await pins!.init();
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  tearDown(() async {
    await pins?.dispose();
    pins = null;
    defs.deviceHiddenKeys.clear();
    defs.devicePinnedKeys.clear();
  });

  for (final updater in ['biscuit', 'echo']) {
    group('the $updater image', () {
      test('hides Capture mode and Capture format and pins them', () async {
        await boot({}, updater);
        for (final def in [defs.micCaptureMode, defs.micCaptureFormat]) {
          expect(defs.deviceHiddenKeys, contains(def.key));
          expect(defs.devicePinnedKeys, contains(def.key));
        }
        expect(settings.get(defs.micCaptureMode), 'mic');
        expect(settings.get(defs.micCaptureFormat), 'auto');
      });

      test('stored values go back to the raw microphone and the automatic '
          'format', () async {
        await boot({
          'ks.audio.mic_capture_mode': 'voice_communication',
          'ks.audio.mic_capture_format': 'hardware',
        }, updater);
        expect(settings.get(defs.micCaptureMode), 'mic');
        expect(settings.get(defs.micCaptureFormat), 'auto');
      });

      test('a later change is put back', () async {
        await boot({}, updater);
        await settings.set(defs.micCaptureMode, 'voice_communication');
        await settings.set(defs.micCaptureFormat, 'hardware');
        await settle();
        expect(settings.get(defs.micCaptureMode), 'mic');
        expect(settings.get(defs.micCaptureFormat), 'auto');
      });
    });
  }

  test('any other device keeps the setting and its value', () async {
    await boot({'ks.audio.mic_capture_mode': 'voice_communication'}, null);
    expect(defs.deviceHiddenKeys, isNot(contains(defs.micCaptureMode.key)));
    expect(defs.devicePinnedKeys, isNot(contains(defs.micCaptureMode.key)));
    expect(settings.get(defs.micCaptureMode), 'voice_communication');
  });

  test('no native side changes nothing', () async {
    SharedPreferences.setMockInitialValues({
      'ks.audio.mic_capture_mode': 'voice_communication',
    });
    bus = EventBus();
    log = Logger();
    settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    await EchoImageSettings(
      settings,
      bus,
      log,
      updater: () async => throw StateError('no channel'),
    ).init();
    expect(settings.get(defs.micCaptureMode), 'voice_communication');
  });
}
