import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/kiosk/kiosk_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Issue #1102: the Full screen switch of issue #1076 became a Hide status
/// bar and a Hide navigation bar switch, and kiosk mode and lockdown hide
/// both bars whatever those say.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsManager settings;

  Future<void> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final log = Logger();
    settings = SettingsManager(EventBus(), CommandRegistry(log), log);
    await settings.init();
  }

  test('both bars hide by default', () async {
    await build({});
    expect(hidesStatusBar(settings), isTrue);
    expect(hidesNavigationBar(settings), isTrue);
  });

  for (final stored in [true, false]) {
    test('a stored Full screen switch ($stored) sets both bars', () async {
      await build({'ks.screen.full_screen': stored});
      expect(settings.get(defs.screenHideStatusBar), stored);
      expect(settings.get(defs.screenHideNavigationBar), stored);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.get('ks.screen.full_screen'), isNull);
    });
  }

  test('an imported Full screen switch sets both bars', () async {
    await build({});
    expect(await settings.setFromJson('screen.full_screen', false), isTrue);
    expect(settings.get(defs.screenHideStatusBar), isFalse);
    expect(settings.get(defs.screenHideNavigationBar), isFalse);
  });

  test('each bar follows its own switch', () async {
    await build({});
    await settings.set(defs.screenHideStatusBar, true);
    await settings.set(defs.screenHideNavigationBar, false);
    expect(hidesStatusBar(settings), isTrue);
    expect(hidesNavigationBar(settings), isFalse);
  });

  for (final mode in [defs.kioskEnabled, defs.lockdownEnabled]) {
    test('${mode.key} hides both bars', () async {
      await build({});
      await settings.set(defs.screenHideStatusBar, false);
      await settings.set(defs.screenHideNavigationBar, false);
      await settings.set(mode, true);
      expect(hidesStatusBar(settings), isTrue);
      expect(hidesNavigationBar(settings), isTrue);
    });
  }
}
