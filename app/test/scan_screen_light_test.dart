import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screen/screen_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
// ignore: depend_on_referenced_packages
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// The barcode scanner's screen light (issue #1148) holds the window at full
/// brightness, and brightness writes made meanwhile land underneath it.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// The window override: null when none is up.
class _Window extends ScreenBrightnessPlatform {
  double? level;

  @override
  Future<void> setApplicationScreenBrightness(double brightness) async =>
      level = brightness;

  @override
  Future<void> resetApplicationScreenBrightness() async => level = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kiosk_satellite/brightness');

  late List<double> writes;
  late bool grant;
  late _Window window;
  late ScreenManager screen;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> build({required bool canWrite}) async {
    writes = [];
    grant = canWrite;
    window = _Window();
    ScreenBrightnessPlatform.instance = window;
    wakelockPlusPlatformInstance = _NoopWakelock();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'get':
              return 0.5;
            case 'set':
              if (!grant) return false;
              writes.add((call.arguments as Map)['level'] as double);
              return true;
            default:
              return null;
          }
        });
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    screen = ScreenManager(bus, commands, log, settings);
    await screen.init();
    await settle();
  }

  tearDown(() => screen.dispose());

  test(
    'with the system grant, writes move the setting under the light',
    () async {
      await build(canWrite: true);
      await screen.holdScanLight(true);
      expect(window.level, 1.0);
      await screen.setBrightness(0.3);
      await settle();
      expect(writes.last, 0.3);
      expect(window.level, 1.0, reason: 'the light stays up');
      await screen.holdScanLight(false);
      expect(window.level, isNull);
    },
  );

  test('without the grant, the override from before comes back', () async {
    await build(canWrite: false);
    await screen.setBrightness(0.3);
    await settle();
    expect(window.level, 0.3);
    await screen.holdScanLight(true);
    expect(window.level, 1.0);
    await screen.setBrightness(0.4);
    await settle();
    expect(window.level, 1.0, reason: 'the light stays up');
    await screen.holdScanLight(false);
    expect(window.level, 0.4);
  });
}
