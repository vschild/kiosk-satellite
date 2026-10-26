import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/btproxy/bt_proxy_manager.dart';
import 'package:kiosk_satellite/managers/device/wifi_mac.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsManager> settingsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final bus = EventBus();
    final log = Logger();
    final settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    return settings;
  }

  test('setting off means no identity, stored or not', () async {
    final settings = await settingsWith({
      'ks.internal.esphome_adopted_mac': '80:30:49:CD:D6:5F',
    });
    expect(await adoptedWifiMac(settings), isNull);
  });

  test('a stored adoption is returned without asking the platform', () async {
    final settings = await settingsWith({
      'ks.esphome.real_mac': true,
      'ks.internal.esphome_adopted_mac': '80:30:49:CD:D6:5F',
    });
    // No device_details channel exists in tests; a platform read would
    // come back null and fail this expectation.
    expect(await adoptedWifiMac(settings), '80:30:49:CD:D6:5F');
  });

  test('an unreadable address adopts nothing and stores nothing', () async {
    final settings = await settingsWith({'ks.esphome.real_mac': true});
    expect(await adoptedWifiMac(settings), isNull);
    expect(settings.internal('esphome_adopted_mac'), isEmpty);
    expect((await wifiMacIdentity(settings)).source, WifiMacSource.none);
  });

  // The hand-typed address (issue #300): the fallback once the platform
  // has come back empty, never adopted, never ahead of a hardware read.
  test('a typed address stands in when the platform reveals nothing', () async {
    final settings = await settingsWith({
      'ks.esphome.real_mac': true,
      'ks.esphome.mac_override': '80:30:49:CD:D6:5F',
    });
    final identity = await wifiMacIdentity(settings);
    expect(identity.mac, '80:30:49:CD:D6:5F');
    expect(identity.source, WifiMacSource.manual);
    expect(await adoptedWifiMac(settings), '80:30:49:CD:D6:5F');
    // Read live, not adopted: editing the field is how a typo gets fixed.
    expect(settings.internal('esphome_adopted_mac'), isEmpty);
  });

  test('a typed address is ignored while the setting is off', () async {
    final settings = await settingsWith({
      'ks.esphome.mac_override': '80:30:49:CD:D6:5F',
    });
    expect(await adoptedWifiMac(settings), isNull);
  });

  test('a stored hardware adoption beats a typed address', () async {
    final settings = await settingsWith({
      'ks.esphome.real_mac': true,
      'ks.internal.esphome_adopted_mac': '1C:4D:66:4C:7E:A1',
      'ks.esphome.mac_override': '80:30:49:CD:D6:5F',
    });
    final identity = await wifiMacIdentity(settings);
    expect(identity.mac, '1C:4D:66:4C:7E:A1');
    expect(identity.source, WifiMacSource.hardware);
  });

  // Issue #736: a ROM that first reported a placeholder (a Broadcom driver
  // default) and later the real address left the placeholder adopted for
  // good. Turning the switch off is the way to let go of it.
  group('turning the switch off forgets the adoption', () {
    Future<SettingsManager> boot(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      final bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      final settings = SettingsManager(bus, commands, log);
      await settings.init();
      final proxy = BtProxyManager(bus, commands, log, settings);
      addTearDown(proxy.dispose);
      await proxy.init();
      return settings;
    }

    test('off drops the stored address', () async {
      final settings = await boot({
        'ks.esphome.real_mac': true,
        'ks.internal.esphome_adopted_mac': '00:90:4C:1A:09:00',
      });
      await settings.set(defs.esphomeRealMac, false);
      await Future<void>.delayed(Duration.zero);
      expect(settings.internal('esphome_adopted_mac'), isEmpty);
    });

    test('another ESPHome setting keeps it', () async {
      final settings = await boot({
        'ks.esphome.real_mac': true,
        'ks.internal.esphome_adopted_mac': '00:90:4C:1A:09:00',
      });
      await settings.set(defs.esphomeMacOverride, '80:30:49:CD:D6:5F');
      await Future<void>.delayed(Duration.zero);
      expect(settings.internal('esphome_adopted_mac'), '00:90:4C:1A:09:00');
    });
  });

  // Only the device owner can read the address. A kiosk that became the
  // device owner after its first start (an Echo image's installer) moves
  // the running server to the real address, and the adoption keeps it.
  group('the device owner arriving', () {
    late List<String?> started;
    late String? platformMac;
    late EventBus bus;

    Future<SettingsManager> boot(Map<String, Object> values) async {
      started = [];
      platformMac = null;
      SharedPreferences.setMockInitialValues({
        'ks.esphome.enabled': true,
        ...values,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('kiosk_satellite/bluetooth_proxy'),
        (call) async {
          if (call.method != 'start') return null;
          started.add((call.arguments as Map)['macOverride'] as String?);
          return 'kiosk-satellite-ad603b';
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('kiosk_satellite/device_details'),
        (call) async => call.method == 'wifiMac' ? platformMac : null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('kiosk_satellite/bluetooth_proxy'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('kiosk_satellite/device_details'),
          null,
        );
      });
      bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      final settings = SettingsManager(bus, commands, log);
      await settings.init();
      final proxy = BtProxyManager(bus, commands, log, settings);
      addTearDown(proxy.dispose);
      await proxy.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return settings;
    }

    test('restarts the server on the real address', () async {
      final settings = await boot({'ks.esphome.real_mac': true});
      expect(started, [null]);
      platformMac = '1C:4D:66:4C:7E:A1';
      bus.publish(const DeviceOwnerChanged());
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(started, [null, '1C:4D:66:4C:7E:A1']);
      expect(settings.internal('esphome_adopted_mac'), '1C:4D:66:4C:7E:A1');
    });

    test('still unreadable: no restart', () async {
      await boot({'ks.esphome.real_mac': true});
      bus.publish(const DeviceOwnerChanged());
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(started, [null]);
    });

    test('the setting off: no restart', () async {
      await boot({});
      platformMac = '1C:4D:66:4C:7E:A1';
      bus.publish(const DeviceOwnerChanged());
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(started, [null]);
    });
  });

  test('a typed address that is not a usable one is ignored', () async {
    // Written past the validator (an old export, a hand-edited prefs
    // file): the identity must not trust it.
    final settings = await settingsWith({
      'ks.esphome.real_mac': true,
      'ks.esphome.mac_override': '01:00:5E:00:00:01',
    });
    expect(await adoptedWifiMac(settings), isNull);
    expect((await wifiMacIdentity(settings)).source, WifiMacSource.none);
  });
}
