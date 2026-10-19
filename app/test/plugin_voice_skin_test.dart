import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/plugins/plugin_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plugin voice skins (issue #1027): a plugin that declares voice.skin is a
/// choice in the Skin setting, and draws the turn while it runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const skin = 'plugin:hello-world';
  late EventBus bus;
  late Logger log;
  late SettingsManager settings;
  late PluginManager plugins;

  Map<String, Object?> plugin({
    String id = 'hello-world',
    bool running = true,
    List<String> capabilities = const ['overlay', 'host.read', 'voice.skin'],
  }) => {
    'id': id,
    'name': 'Hello World',
    'running': running,
    'capabilities': capabilities,
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    bus = EventBus();
    log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    plugins = PluginManager(bus, commands, log);
    settings.pluginVoiceSkins = () => plugins.voiceSkinOptions;
  });
  tearDown(() async {
    await settings.dispose();
    await bus.dispose();
    log.dispose();
  });

  test('plugins that declare voice.skin are named in the Skin setting', () {
    plugins.installed.value = [
      plugin(),
      plugin(id: 'clock', capabilities: const ['overlay', 'host.read']),
    ];
    expect(plugins.voiceSkinOptions, {skin: 'Hello World'});
    final schema = settings.describe().firstWhere(
      (s) => s['key'] == voiceSkin.key,
    );
    expect(schema['options'], contains(skin));
    expect(schema['options'], isNot(contains('plugin:clock')));
    expect((schema['optionLabels'] as Map)[skin], 'Hello World');
  });

  test('a picked plugin skin stays picked when the plugin goes', () async {
    expect(await settings.setFromJson(voiceSkin.key, skin), true);
    plugins.installed.value = [];
    expect(settings.optionsFor(voiceSkin), contains(skin));
    expect(settings.optionLabel(voiceSkin, skin), 'Unavailable plugin skin');
    final schema = settings.describe().firstWhere(
      (s) => s['key'] == voiceSkin.key,
    );
    expect((schema['optionLabels'] as Map)[skin], 'Unavailable plugin skin');
    expect(await settings.setFromJson(voiceSkin.key, 'plugin:../bad'), false);
    expect(await settings.setFromJson(voiceSkin.key, 'plugin:a:b'), false);
    expect(await settings.setFromJson(voiceSkin.key, 'jarvis'), true);
  });

  test(
    'a plugin skin shows the picture it ships, read once per package',
    () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PluginManager.channel, (call) async {
            if (call.method != 'voiceSkinThumbnail') return null;
            reads++;
            expect(call.arguments, {'id': 'hello-world'});
            return png;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PluginManager.channel, null),
      );
      plugins.installed.value = [
        {...plugin(), 'sha256': 'a', 'voiceSkinThumbnail': 'voice-skin.png'},
        plugin(id: 'plain'),
      ];
      expect(await plugins.voiceSkinThumbnail('hello-world'), png);
      expect(await plugins.voiceSkinThumbnail('hello-world'), png);
      expect(reads, 1);
      // A plugin that ships none, and one not installed, show the mark.
      expect(await plugins.voiceSkinThumbnail('plain'), isNull);
      expect(await plugins.voiceSkinThumbnail('missing'), isNull);
      expect(reads, 1);
      // An update reads the new package's picture.
      plugins.installed.value = [
        {...plugin(), 'sha256': 'b', 'voiceSkinThumbnail': 'voice-skin.png'},
      ];
      await plugins.voiceSkinThumbnail('hello-world');
      expect(reads, 2);
    },
  );

  test('the plugin draws the turn only while it runs', () {
    plugins.installed.value = [plugin()];
    plugins.enabled.value = true;
    expect(plugins.voiceSkinRunning(skin), true);
    expect(plugins.voiceSkinRunning('plugin:other'), false);
    expect(plugins.voiceSkinRunning('kiosk-satellite'), false);

    // Plugins switched off, the plugin stopped or without the capability:
    // the overlay falls back to a built-in skin.
    plugins.enabled.value = false;
    expect(plugins.voiceSkinRunning(skin), false);
    plugins.enabled.value = true;
    plugins.installed.value = [plugin(running: false)];
    expect(plugins.voiceSkinRunning(skin), false);
    plugins.installed.value = [
      plugin(capabilities: const ['overlay', 'host.read']),
    ];
    expect(plugins.voiceSkinRunning(skin), false);
  });
}
