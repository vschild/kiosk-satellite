import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Expose kiosk entities is on for new installs. A kiosk set up before
/// keeps what it had, so ESPHome running only for the Bluetooth proxy does
/// not start serving every entity after an update.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsManager> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final log = Logger();
    final settings = SettingsManager(EventBus(), CommandRegistry(log), log);
    await settings.init();
    return settings;
  }

  test('a new install exposes the entities', () async {
    final settings = await build({});
    expect(settings.get(defs.esphomeEntities), isTrue);
  });

  test('a new install keeps the default once it is set up', () async {
    final prefs = <String, Object>{};
    var settings = await build(prefs);
    await settings.set(defs.startUrl, 'https://ha.example.com/');
    final saved = await SharedPreferences.getInstance();
    settings = await build({
      for (final key in saved.getKeys()) key: saved.get(key)!,
    });
    expect(settings.get(defs.esphomeEntities), isTrue);
  });

  test('a configured kiosk that never chose keeps them off', () async {
    final settings = await build({
      'ks.browser.start_url': 'https://ha.example.com/lovelace/0',
      'ks.esphome.enabled': true,
    });
    expect(settings.get(defs.esphomeEntities), isFalse);
  });

  test('a configured kiosk that chose keeps its choice', () async {
    final settings = await build({
      'ks.browser.start_url': 'https://ha.example.com/lovelace/0',
      'ks.esphome.entities': true,
    });
    expect(settings.get(defs.esphomeEntities), isTrue);
  });
}
