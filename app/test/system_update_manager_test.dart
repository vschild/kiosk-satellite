import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/headless.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/update/system_update_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kiosk_satellite/system_update');

  late EventBus bus;
  late CommandRegistry commands;
  late SystemUpdateManager manager;
  late Map<String, Object?> rom;
  late List<String> calls;
  var changes = 0;

  // BiscuitService as the bridge reaches it: a check answers once a few
  // status reads have passed, an install starts only with an update.
  setUp(() {
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    manager = SystemUpdateManager(bus, commands, log);
    changes = 0;
    bus.on<SystemUpdateStateChanged>().listen((_) => changes++);
    calls = [];
    rom = {
      'current': '2026.10.4',
      'latest': '2026.10.4',
      'available': false,
      'notes': '',
      'url': '',
      'state': 'idle',
      'error': '',
      'checkError': '',
      'checked': 0,
    };
    var checkingReads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'status':
              if (rom['state'] == 'checking' && ++checkingReads >= 2) {
                rom
                  ..['state'] = 'idle'
                  ..['latest'] = '2026.10.5'
                  ..['available'] = true
                  ..['notes'] = '# Version 2026.10.5\n\n- A fix.'
                  ..['checked'] = 1;
              }
              return jsonEncode(rom);
            case 'check':
              rom['state'] = 'checking';
              return true;
            case 'install':
              if (rom['available'] != true) return false;
              rom['state'] = 'downloading';
              rom['progress'] = 0;
              return true;
          }
          return null;
        });
  });

  tearDown(() {
    Headless.debugActive = false;
    Headless.debugSystemUpdate = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('elsewhere the commands say the image is needed', () async {
    await manager.init();
    final status = await commands.execute('getSystemUpdateStatus', const {});
    expect(status.data, {'supported': false});
    final install = await commands.execute('installSystemUpdate', const {});
    expect(install.ok, isFalse);
    expect(install.error, contains('Echo Dot image'));
    expect(calls, isEmpty);
    await manager.dispose();
  });

  group('on the Echo Dot image', () {
    setUp(() {
      Headless.debugActive = true;
      Headless.debugSystemUpdate = true;
    });

    test('the status reads in the update command shape', () async {
      await manager.init();
      final status = await commands.execute('getSystemUpdateStatus', const {});
      expect(status.data, {
        'supported': true,
        'currentVersion': '2026.10.4',
        'availableVersion': null,
        'availableNotes': null,
        'releaseUrl': '',
        'state': 'idle',
        'progress': null,
        'lastError': '',
        'checkError': '',
        'checked': 0,
      });
      await manager.dispose();
    });

    test('a check waits for GitHub and reports the release', () async {
      await manager.init();
      final before = changes;
      final result = await commands.execute('checkSystemUpdateNow', const {});
      final data = result.data! as Map;
      expect(data['reachable'], isTrue);
      expect(data['availableVersion'], '2026.10.5');
      expect(data['availableNotes'], contains('A fix.'));
      expect(calls, contains('check'));
      expect(changes, greaterThan(before));
      await manager.dispose();
    });

    test('a failed check is reported as unreachable', () async {
      await manager.init();
      rom['checkError'] = 'Could not check for updates: timeout';
      final result = await commands.execute('checkSystemUpdateNow', const {});
      expect((result.data! as Map)['reachable'], isFalse);
      await manager.dispose();
    });

    test('install needs a newer release and starts once', () async {
      await manager.init();
      var install = await commands.execute('installSystemUpdate', const {});
      expect(install.error, 'no update available');
      await commands.execute('checkSystemUpdateNow', const {});
      install = await commands.execute('installSystemUpdate', const {});
      expect(install.ok, isTrue);
      expect(manager.status.value!.busy, isTrue);
      expect(manager.status.value!.progress, 0);
      install = await commands.execute('installSystemUpdate', const {});
      expect(install.error, 'an update is already running');
      await manager.dispose();
    });
  });
}
