import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/plugins/plugin_directory.dart';
import 'package:kiosk_satellite/managers/plugins/plugin_manager.dart';

/// Community Plugins with a fixed answer to "is this repository listed".
class _Directory extends PluginDirectory {
  _Directory(this.listed);
  final Set<String> listed;

  @override
  Future<bool?> lists(String repository) async => listed.contains(repository);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late PluginManager plugins;
  late List<String> activity;
  late List<Map<String, Object?>> installed;
  var failInstall = false;

  Map<String, Object?> plugin(String id) => {
    'id': id,
    'name': id,
    'version': '1.0.0',
    'enabled': false,
    'running': false,
  };

  setUp(() async {
    activity = [];
    installed = [plugin('existing')];
    failInstall = false;
    plugins = PluginManager(
      EventBus(),
      CommandRegistry(Logger()),
      Logger(),
      directory: _Directory({'https://github.com/listed/radar'}),
    )..onActivity = activity.add;
    messenger.setMockMethodCallHandler(PluginManager.channel, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      if (call.method == 'install') {
        if (failInstall) {
          throw PlatformException(code: 'plugin_error', message: 'bad zip');
        }
        final id = '${args['id'] ?? 'new-plugin'}';
        if (!installed.any((p) => p['id'] == id)) installed.add(plugin(id));
      }
      if (call.method == 'remove') {
        installed.removeWhere((p) => p['id'] == args['id']);
      }
      return {'enabled': true, 'plugins': installed};
    });
    await plugins.refresh();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(PluginManager.channel, null);
  });

  // The counts land after the install returns: the directory lookup that
  // names the source runs on its own.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a new plugin counts by where it came from', () async {
    await plugins.update('install', {
      'id': 'radar',
      'source': jsonEncode({'repository': 'https://github.com/listed/radar'}),
    });
    await plugins.update('install', {
      'id': 'tool',
      'source': jsonEncode({'repository': 'https://github.com/me/tool'}),
    });
    await plugins.update('install', {'id': 'zip-one', 'bytes': 'x'});
    await settle();
    expect(activity, [
      'plugin_installs_directory',
      'plugin_installs_github',
      'plugin_installs_zip',
    ]);
  });

  test('installing over a plugin already there is an update', () async {
    await plugins.update('install', {'id': 'existing', 'bytes': 'x'});
    await settle();
    expect(activity, ['plugin_updates']);
  });

  test('removals and failed installs count, fleet pushes do not', () async {
    await plugins.update('remove', {'id': 'existing'});
    failInstall = true;
    await expectLater(
      plugins.update('install', {'id': 'broken', 'bytes': 'x'}),
      throwsA(isA<PlatformException>()),
    );
    failInstall = false;
    await plugins.fleetInstall(Uint8List.fromList([1, 2, 3]), sha256: 'abc');
    await plugins.fleetRemove('new-plugin');
    await settle();
    expect(activity, ['plugin_removals', 'plugin_install_failures']);
  });

  test('settings changes are not install activity', () async {
    await plugins.update('enable', {'id': 'existing'});
    await plugins.update('disable', {'id': 'existing'});
    await settle();
    expect(activity, isEmpty);
  });
}
