import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  late List<Uri> fetched;
  // What SystemUpdateBridge.kt read from the ROM's properties.
  String? updater;
  var changes = 0;

  // The new image's releases: other devices', a draft and a beta around
  // the Dot's own.
  final releases = [
    {'tag_name': 'crown-2026.11.1', 'body': 'Show 8'},
    {'tag_name': 'biscuit-2026.12.1', 'draft': true, 'body': 'Draft'},
    {'tag_name': 'biscuit-2026.11.2', 'prerelease': true, 'body': 'Beta'},
    {'tag_name': 'biscuit-2026.9.30', 'body': 'Older'},
    {'tag_name': 'biscuit-2026.10.6', 'body': '- **LineageOS 18.1.**\n'},
    {'tag_name': 'cronos-2026.12.1', 'body': 'Show 5'},
  ];

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
    fetched = [];
    manager.clientFactory = () => MockClient((request) async {
      fetched.add(request.url);
      return http.Response(jsonEncode(releases), 200);
    });
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
    updater = null;
    var checkingReads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'updater':
              return updater;
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('elsewhere the commands say the image is needed', () async {
    await manager.init();
    final status = await commands.execute('getSystemUpdateStatus', const {});
    expect(status.data, {'supported': false});
    final install = await commands.execute('installSystemUpdate', const {});
    expect(install.ok, isFalse);
    expect(install.error, contains('Echo Show image'));
    expect(calls, ['updater']);
    await manager.dispose();
  });

  group('on the Echo Show images', () {
    setUp(() => updater = 'echo');

    for (final headless in [false, true]) {
      test(
        'EchoService is found ${headless ? 'without' : 'with'} a screen',
        (() async {
          Headless.debugActive = headless;
          await manager.init();
          expect(manager.supported, isTrue);
          final status = await commands.execute(
            'getSystemUpdateStatus',
            const {},
          );
          final data = status.data! as Map;
          expect(data['supported'], isTrue);
          expect(data['currentVersion'], '2026.10.4');
          expect(data['title'], 'LineageOS for the Echo Show');
          expect(
            data['repository'],
            'https://github.com/jxlarrea/lineageos-echo-kiosk-satellite',
          );
          expect(data['manualVersion'], isNull);
          await manager.dispose();
        }),
      );
    }

    test('check and install go through the same bridge', () async {
      await manager.init();
      await commands.execute('checkSystemUpdateNow', const {});
      final install = await commands.execute('installSystemUpdate', const {});
      expect(install.ok, isTrue);
      expect(calls, containsAllInOrder(['updater', 'check', 'install']));
      // EchoService reads its own device's releases.
      expect(fetched, isEmpty);
      await manager.dispose();
    });
  });

  group('on the Echo Dot image', () {
    setUp(() {
      manager.detectSource = () async =>
          BiscuitSystemUpdateSource(sdkInt: 30, device: 'biscuit');
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
        'title': 'LineageOS for the Echo Dot',
        'repository':
            'https://github.com/jxlarrea/lineageos-echo-kiosk-satellite',
        'manualVersion': null,
        'manualNotes': null,
        'manualUrl': null,
      });
      // The updater reads the new image's releases itself.
      expect(fetched, isEmpty);
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

  group('on the CM14.1 image', () {
    setUp(() {
      manager.detectSource = () async =>
          BiscuitSystemUpdateSource(sdkInt: 25, device: 'biscuit');
    });

    test('the new image shows as an install by hand', () async {
      await manager.init();
      await commands.execute('checkSystemUpdateNow', const {});
      expect(
        fetched.first.toString(),
        'https://api.github.com/repos/jxlarrea/lineageos-echo-kiosk-satellite/releases?per_page=100',
      );
      final status = await commands.execute('getSystemUpdateStatus', const {});
      final data = status.data! as Map;
      expect(
        data['repository'],
        'https://github.com/jxlarrea/lineageos-biscuit-kiosk-satellite',
      );
      // The old repository's update, if any, still comes from BiscuitService.
      expect(data['availableVersion'], '2026.10.5');
      expect(data['manualVersion'], '2026.10.6');
      expect(data['manualNotes'], '- **LineageOS 18.1.**');
      expect(data['manualUrl'], BiscuitSystemUpdateSource.guide);
      await manager.dispose();
    });

    test('install refuses the new image and names the guide', () async {
      await manager.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final install = await commands.execute('installSystemUpdate', const {});
      expect(install.ok, isFalse);
      expect(install.error, contains('installs by hand'));
      expect(install.error, contains(BiscuitSystemUpdateSource.guide));
      expect(calls, isNot(contains('install')));
      await manager.dispose();
    });

    test('GitHub not answering keeps what was known', () async {
      await manager.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(manager.manual.value?.version, '2026.10.6');
      manager.clientFactory = () =>
          MockClient((_) async => http.Response('rate limited', 403));
      await commands.execute('checkSystemUpdateNow', const {});
      expect(manager.manual.value?.version, '2026.10.6');
      await manager.dispose();
    });
  });

  group('the newest release of the device', () {
    const successor = ImageSuccessor(
      repository: 'jxlarrea/lineageos-echo-kiosk-satellite',
      device: 'crown',
      guide: 'https://example.com/guide',
    );

    test('reads only its own tags, by version, not by order', () {
      final newest = SystemUpdateManager.newestManualUpdate([
        {'tag_name': 'crown-2026.9.30'},
        {'tag_name': 'crown-2026.10.2', 'body': ' Notes '},
        {'tag_name': 'crown-2026.10.10', 'prerelease': true},
        {'tag_name': 'crown-test'},
        {'tag_name': 'crownx-2026.12.1'},
        {'tag_name': 'biscuit-2026.12.1'},
      ], successor);
      expect(newest?.version, '2026.10.2');
      expect(newest?.notes, 'Notes');
      expect(newest?.url, 'https://example.com/guide');
    });

    test('none without a release of its own', () {
      expect(
        SystemUpdateManager.newestManualUpdate([
          {'tag_name': 'biscuit-2026.10.6'},
          {'tag_name': '2026.10.5'},
        ], successor),
        isNull,
      );
    });
  });
}
