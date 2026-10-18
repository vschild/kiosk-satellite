import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/airplay/airplay_manager.dart';
import 'package:kiosk_satellite/managers/sendspin/airplay_player.dart';
import 'package:kiosk_satellite/managers/sendspin/remote_player.dart';
import 'package:kiosk_satellite/managers/sendspin/sendspin_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The AirPlay receiver: one of this device's players on the Media Player
/// page, serving only while it is the pick and switched on, with the
/// Sendspin player offline meanwhile.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const sendspin = MethodChannel('kiosk_satellite/sendspin');
  const sessions = MethodChannel('kiosk_satellite/media_sessions');
  const airplay = AirPlayManager.channel;
  const codec = StandardMethodCodec();

  group('AirPlayPlayer.snapshotFrom', () {
    test('maps the receiver snapshot to the surfaces shape', () {
      final snap = AirPlayPlayer.snapshotFrom({
        'client': "Jane's iPhone",
        'playing': true,
        'title': 'Song',
        'artist': 'Band',
        'album': 'Record',
        'durationMs': 200000,
        'positionMs': 1500,
        'receivedAt': 1000,
        'artworkId': 3,
        'remote': true,
        'remoteStatus': true,
      })!;
      expect(snap['title'], 'Song');
      expect(snap['artist'], 'Band');
      expect(snap['album'], 'Record');
      expect(snap['durationMs'], 200000);
      expect(snap['positionMs'], 1500);
      expect(snap['receivedAt'], 1000);
      expect(snap['playing'], true);
      expect(snap['artworkUrl'], 'airplay:art/3');
      expect(snap['supportedCommands'], [
        'play',
        'pause',
        'next',
        'previous',
        'volume',
        'seek',
      ]);
      expect(snap.containsKey('stream'), false);
    });

    test('offers shuffle and repeat as the sender allows them', () {
      final snap = AirPlayPlayer.snapshotFrom({
        'client': 'Mac',
        'title': 'Song',
        'durationMs': 1000,
        'remote': true,
        'remoteStatus': true,
        'shuffle': true,
        'repeat': 'all',
        'shuffleOffered': true,
        'repeatOffered': false,
      })!;
      expect(snap['shuffle'], true);
      expect(snap['repeat'], 'all');
      expect(snap['supportedCommands'], contains('shuffle'));
      expect(snap['supportedCommands'], isNot(contains('repeat')));
      // Nothing offered without a remote control.
      final bare = AirPlayPlayer.snapshotFrom({
        'title': 'Song',
        'shuffleOffered': true,
        'repeatOffered': true,
      })!;
      expect(bare['supportedCommands'], ['volume']);
    });

    test('offers only play, pause and skip when the sender refuses the '
        'rest (iOS)', () {
      final snap = AirPlayPlayer.snapshotFrom({
        'client': 'iPad',
        'title': 'Song',
        'durationMs': 1000,
        'remote': true,
        'remoteStatus': false,
        'shuffleOffered': true,
        'repeatOffered': true,
      })!;
      expect(snap['supportedCommands'], [
        'play',
        'pause',
        'next',
        'previous',
        'volume',
      ]);
    });

    test('offers no seek for a stream with no length', () {
      final snap = AirPlayPlayer.snapshotFrom({
        'client': 'Phone',
        'title': 'Radio',
        'remote': true,
      })!;
      expect(snap['supportedCommands'], isNot(contains('seek')));
      expect(snap['stream'], true);
    });

    test('offers no transport without a remote control', () {
      final snap = AirPlayPlayer.snapshotFrom({
        'client': 'Mac',
        'title': 'Song',
        'remote': false,
      })!;
      // Never empty: the controls read an empty list as anything goes.
      expect(snap['supportedCommands'], ['volume']);
      expect(snap['artworkUrl'], '');
      expect(snap['stream'], true);
    });

    test('a sender without metadata shows under its own name', () {
      final bare = AirPlayPlayer.snapshotFrom({'client': "Jane's iPhone"})!;
      expect(bare['title'], "Jane's iPhone");
      expect(bare['artist'], 'AirPlay');
      expect(AirPlayPlayer.snapshotFrom({'client': ''})!['title'], 'AirPlay');
      expect(AirPlayPlayer.snapshotFrom(null), isNull);
    });
  });

  group('AirPlayManager', () {
    late EventBus bus;
    late SettingsManager settings;
    late AirPlayManager manager;
    final calls = <MethodCall>[];

    Future<void> boot({bool enabled = false, String pick = 'airplay'}) async {
      SharedPreferences.setMockInitialValues({
        'ks.device.name': 'Kitchen',
        'ks.airplay.enabled': enabled,
        'ks.sendspin.player_source': '',
        'ks.sendspin.player': pick,
      });
      calls.clear();
      messenger.setMockMethodCallHandler(airplay, (call) async {
        calls.add(call);
        return null;
      });
      bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      settings = SettingsManager(bus, commands, log);
      await settings.init();
      manager = AirPlayManager(bus, commands, log, settings);
      await manager.init();
      await pumpEventQueue();
    }

    tearDown(() async {
      await manager.dispose();
      await bus.dispose();
      messenger.setMockMethodCallHandler(airplay, null);
    });

    test('serves while it is the pick and switched on', () async {
      await boot();
      expect(calls, isEmpty);
      await settings.set(defs.airplayEnabled, true);
      await pumpEventQueue();
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {
        'name': 'Kitchen',
        'senderVolume': true,
        'offsetMs': 0,
        'takeover': true,
      });
      // Another pick takes it off the network, like the Sendspin player.
      await settings.set(defs.sendspinPlayer, '');
      await pumpEventQueue();
      expect(calls.last.method, 'stop');
      await settings.set(defs.sendspinPlayer, 'airplay');
      await pumpEventQueue();
      expect(calls.last.method, 'start');
      await settings.set(defs.sendspinPlayerSource, 'ma');
      await pumpEventQueue();
      expect(calls.last.method, 'stop');
    });

    test('stays off while another player is picked', () async {
      await boot(enabled: true, pick: '');
      expect(calls, isEmpty);
    });

    test('announces its own name, else the device name', () async {
      await boot(enabled: true);
      expect((calls.last.arguments as Map)['name'], 'Kitchen');
      await settings.set(defs.airplayName, 'Kitchen Speaker');
      await pumpEventQueue();
      expect((calls.last.arguments as Map)['name'], 'Kitchen Speaker');
      await settings.set(defs.airplayName, '');
      await settings.set(defs.deviceName, 'Kitchen Tablet');
      await pumpEventQueue();
      expect((calls.last.arguments as Map)['name'], 'Kitchen Tablet');
    });

    test('applies its options live', () async {
      await boot(enabled: true);
      await settings.set(defs.airplaySyncOffset, -120);
      await settings.set(defs.airplaySenderVolume, false);
      await pumpEventQueue();
      final configure = calls.where((c) => c.method == 'configure').last;
      expect(configure.arguments, {
        'senderVolume': false,
        'offsetMs': -120,
        'takeover': true,
      });
    });

    test('keeps a cover for its album when stamped as the track\'s', () async {
      await boot(enabled: true);
      messenger.setMockMethodCallHandler(airplay, (call) async {
        calls.add(call);
        return call.method == 'artwork' ? Uint8List.fromList([7, 7, 7]) : null;
      });
      Future<void> push(Object? args) => messenger.handlePlatformMessage(
        airplay.name,
        codec.encodeMethodCall(MethodCall('snapshot', args)),
        (_) {},
      );
      // A cover the sender stamped for another track stays out.
      await push({
        'client': 'Mac',
        'title': 'Song',
        'artist': 'Band',
        'album': 'Unmatched Record',
        'artworkId': 1,
        'artworkMatchesTrack': false,
      });
      await pumpEventQueue();
      expect(
        AirPlayManager.albumArtworkUrl('Band', 'Unmatched Record'),
        isNull,
      );
      await push({
        'client': 'Mac',
        'title': 'Song',
        'artist': 'Band',
        'album': 'Matched Record',
        'artworkId': 2,
        'artworkMatchesTrack': true,
      });
      await pumpEventQueue();
      final url = AirPlayManager.albumArtworkUrl('band', 'matched record');
      expect(url, isNotNull);
      expect(await AirPlayManager.artworkFor(url!), [7, 7, 7]);
    });

    test('relays the receiver snapshots onto the bus', () async {
      await boot(enabled: true);
      final seen = <Map<String, Object?>?>[];
      bus.on<AirPlaySessionChanged>().listen((e) => seen.add(e.session));
      Future<void> push(Object? args) => messenger.handlePlatformMessage(
        airplay.name,
        codec.encodeMethodCall(MethodCall('snapshot', args)),
        (_) {},
      );
      await push({'client': 'Phone', 'playing': true, 'title': 'Song'});
      await push(null);
      await pumpEventQueue();
      expect(seen, [
        {'client': 'Phone', 'playing': true, 'title': 'Song'},
        null,
      ]);
      expect(manager.session, isNull);
    });
  });

  group('AirPlay as the Media Player pick', () {
    late EventBus bus;
    late SettingsManager settings;
    late SendspinManager manager;
    final native = <MethodCall>[];
    final airplayCalls = <MethodCall>[];

    Future<void> boot({String pick = 'airplay'}) async {
      SharedPreferences.setMockInitialValues({
        'ks.device.name': 'Tablet',
        'ks.sendspin.enabled': true,
        'ks.sendspin.client_id': 'tablet',
        'ks.sendspin.player_source': '',
        'ks.sendspin.player': pick,
        'ks.sendspin.player_name': pick == 'airplay' ? 'AirPlay' : '',
        'ks.sendspin.lyrics': false,
        'ks.airplay.enabled': true,
      });
      native.clear();
      airplayCalls.clear();
      messenger.setMockMethodCallHandler(sendspin, (call) async {
        native.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(sessions, (call) async => null);
      messenger.setMockMethodCallHandler(airplay, (call) async {
        airplayCalls.add(call);
        return switch (call.method) {
          'control' || 'playQueue' => true,
          'queue' => [
            {
              'title': 'Next song',
              'artist': 'Band',
              'durationMs': 1000,
              'number': 2,
            },
          ],
          _ => null,
        };
      });
      bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      settings = SettingsManager(bus, commands, log);
      await settings.init();
      manager = SendspinManager(bus, commands, log, settings);
      await manager.init();
      await pumpEventQueue();
    }

    tearDown(() async {
      await manager.dispose();
      await bus.dispose();
      messenger.setMockMethodCallHandler(sendspin, null);
      messenger.setMockMethodCallHandler(sessions, null);
      messenger.setMockMethodCallHandler(airplay, null);
    });

    test('follows the sender and keeps the Sendspin player offline', () async {
      await boot();
      // The Sendspin player never starts while AirPlay is the pick, and
      // its switch leaves the page with the rest of its rows.
      expect(native.where((c) => c.method == 'start'), isEmpty);
      expect(settings.visible(defs.sendspinEnabled), false);
      expect(settings.visible(defs.airplayEnabled), true);
      expect(settings.get(defs.sendspinPlayerActive), true);
      expect(manager.nowPlaying.value, isNull);
      expect(manager.playerChipName, 'AirPlay');
      bus.publish(
        const AirPlaySessionChanged({
          'client': "Jane's iPhone",
          'playing': true,
          'title': 'Song',
          'artist': 'Band',
          'remote': true,
          'remoteStatus': true,
        }),
      );
      await pumpEventQueue();
      final now = manager.nowPlaying.value!;
      expect(now['title'], 'Song');
      expect(now['playing'], true);
      expect(manager.playerChipName, "Jane's iPhone");
      // It plays out of this device: the slider is the media volume and
      // the volume keys keep their Android meaning.
      expect(manager.volumeAvailable, true);
      expect(manager.volumeKeysWanted(viewShown: true), false);
      // The sender's Up Next, through its remote control.
      expect(manager.queueAvailable, true);
      expect(manager.groupAvailable, false);
      // Transport goes to the sender's remote control.
      expect(await manager.control('pause'), true);
      expect(
        airplayCalls.where((c) => c.method == 'control').single.arguments,
        {'command': 'pause'},
      );
      // The sender's Up Next, the playing song first.
      await manager.refreshQueue();
      expect(manager.queueItems.value.map((r) => r['title']), [
        'Song',
        'Next song',
      ]);
      expect(manager.queueItems.value.first['current'], true);
      expect(manager.queueUpNext.value, 1);
      expect(await manager.playQueueItem('2'), true);
      expect(
        airplayCalls.where((c) => c.method == 'playQueue').single.arguments,
        {'number': 2},
      );
      // Seeking asks the sender through the same remote control.
      expect(await manager.seek(61000), isFalse);
      expect(airplayCalls.where((c) => c.method == 'seek').single.arguments, {
        'positionMs': 61000,
      });
      // The sender leaves: nothing to show until the next one.
      bus.publish(const AirPlaySessionChanged(null));
      await pumpEventQueue();
      expect(manager.nowPlaying.value, isNull);
      expect(manager.playerChipName, 'AirPlay');
    });

    test('a session for another pick shows nothing', () async {
      await boot(pick: '');
      bus.publish(
        const AirPlaySessionChanged({'client': 'Phone', 'title': 'Song'}),
      );
      await pumpEventQueue();
      expect(manager.nowPlaying.value, isNull);
    });

    test('an action picks it by name', () async {
      await boot(pick: '');
      final result = await manager.commands.execute('mediaPlayerSet', {
        'source': 'device',
        'player': 'AirPlay',
      });
      expect(result.ok, true);
      expect(settings.get(defs.sendspinPlayer), 'airplay');
      expect(settings.get(defs.sendspinPlayerName), 'AirPlay');
    });

    test('ducks the receiver with voice interactions', () async {
      await boot();
      bus.publish(const VoiceInteractionChanged(active: true, reason: 'voice'));
      await pumpEventQueue();
      final ducks = airplayCalls.where((c) => c.method == 'duck').toList();
      expect((ducks.last.arguments as Map)['factor'], closeTo(0.1, 1e-9));
      bus.publish(
        const VoiceInteractionChanged(active: false, reason: 'voice'),
      );
      await pumpEventQueue();
      expect(
        (airplayCalls.where((c) => c.method == 'duck').last.arguments
            as Map)['factor'],
        1.0,
      );
    });
  });

  test('parses and stores the pick', () {
    final pick = PlayerSource.parse('airplay');
    expect(pick.kind, PlayerSourceKind.airplay);
    expect(pick.isLocal, false);
    expect(pick.value, 'airplay');
  });

  test('a dependency can rule out a list of values', () {
    expect(defs.sendspinEnabled.alsoDependsSatisfiedBy('session:*'), false);
    expect(defs.sendspinEnabled.alsoDependsSatisfiedBy('airplay'), false);
    expect(defs.sendspinEnabled.alsoDependsSatisfiedBy(''), true);
  });
}
