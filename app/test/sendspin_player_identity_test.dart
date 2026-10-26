import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/sendspin/ma_remote_player.dart';
import 'package:kiosk_satellite/managers/sendspin/music_assistant_api.dart';
import 'package:kiosk_satellite/managers/sendspin/sendspin_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Music Assistant that lists this device under a universal player
/// wrapping its Sendspin client id.
class _FakeApi extends MusicAssistantApi {
  _FakeApi() : super(baseUrl: 'ma.local', token: 't');

  static final calls = <String>[];
  static var listed = true;

  @override
  Future<MusicAssistantResult> call(
    String command, {
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add(command);
    return MusicAssistantResult.success(
      switch (command) {
        'players/all' => [
          {'player_id': 'other', 'name': 'Office'},
          if (listed) {'player_id': 'up_abc123', 'name': 'Kitchen Tablet'},
        ],
        _ => null,
      },
      const {'server_id': 'srv1', 'server_version': '2.10.2', 'name': 'Home'},
    );
  }
}

class _FakeRemote extends MaRemotePlayer {
  _FakeRemote({
    required super.baseUrl,
    required super.token,
    required super.playerId,
    required super.onSnapshot,
    required super.log,
    super.label,
  });

  @override
  void start() {}

  @override
  Future<void> stop() async {}
}

/// What plugins read and hear of the local player (issue #1053): its
/// Sendspin identity and the Music Assistant player that stands for it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kiosk_satellite/sendspin');
  late EventBus bus;
  late SettingsManager settings;
  late SendspinManager sendspin;
  late CommandRegistry commands;
  late List<Map<String, Object?>> events;
  _FakeRemote? remote;

  Future<void> fromNative(String method, Map<String, Object?> args) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, args),
            ),
            (_) {},
          );

  Future<void> build(Map<String, Object> prefs) async {
    _FakeApi.calls.clear();
    _FakeApi.listed = true;
    remote = null;
    SharedPreferences.setMockInitialValues({
      'ks.sendspin.enabled': true,
      'ks.sendspin.client_id': 'abc123',
      'ks.device.name': 'Kitchen Tablet',
      ...prefs,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    sendspin = SendspinManager(bus, commands, log, settings);
    sendspin.apiFactory = ({required baseUrl, required token}) => _FakeApi();
    sendspin.remoteFactory =
        ({
          required baseUrl,
          required token,
          required playerId,
          required onSnapshot,
          required log,
          String label = 'remote player',
          bool showInputs = false,
        }) => remote = _FakeRemote(
          baseUrl: baseUrl,
          token: token,
          playerId: playerId,
          onSnapshot: onSnapshot,
          log: log,
          label: label,
        );
    events = [];
    bus.on<SendspinPlayerChanged>().listen((e) => events.add(e.player));
    await sendspin.init();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    addTearDown(sendspin.dispose);
  }

  test('a connected player names its Music Assistant player', () async {
    await build({
      'ks.sendspin.ma_url': 'ma.local',
      'ks.sendspin.ma_token': 'token',
    });
    expect(events.last, containsPair('running', true));
    expect(events.last, containsPair('connected', false));
    expect(_FakeApi.calls, isNot(contains('players/all')));
    await fromNative('stateChanged', {
      'connected': true,
      'serverName': 'Music Assistant',
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.last, {
      'enabled': true,
      'running': true,
      'connected': true,
      'playing': false,
      'clientId': 'abc123',
      'playerName': 'Kitchen Tablet',
      'serverName': 'Music Assistant',
      'maConfigured': true,
      'maPlayerId': 'up_abc123',
      'maServerId': 'srv1',
      'maServerName': 'Home',
      'maServerVersion': '2.10.2',
    });
    final read = await commands.execute('sendspinPlayer', const {});
    expect(read.data, events.last);
    // A repeated state report asks Music Assistant nothing new.
    final asked = _FakeApi.calls.where((c) => c == 'players/all').length;
    await fromNative('stateChanged', {'connected': true});
    expect(_FakeApi.calls.where((c) => c == 'players/all').length, asked);
    // Disconnected: the server name goes, Music Assistant still knows the
    // player.
    final before = events.length;
    await fromNative('stateChanged', {'connected': false});
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(before + 1));
    expect(events.last, containsPair('connected', false));
    expect(events.last, containsPair('serverName', ''));
    expect(events.last, containsPair('maPlayerId', 'up_abc123'));
  });

  test('without Music Assistant the identity is Sendspin only', () async {
    await build(const {});
    await fromNative('stateChanged', {
      'connected': true,
      'serverName': 'Music Assistant',
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.last, containsPair('connected', true));
    expect(events.last, containsPair('maConfigured', false));
    expect(events.last, containsPair('maPlayerId', ''));
    expect(_FakeApi.calls, isEmpty);
  });

  test('playing follows the local player', () async {
    await build(const {});
    await fromNative('stateChanged', {'connected': true});
    await fromNative('metadataChanged', {'title': 'Song'});
    await fromNative('playingChanged', {'playing': true});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.last, containsPair('playing', true));
    final read = await commands.execute('sendspinPlayer', const {});
    expect((read.data as Map)['playing'], isTrue);
    // A pause is heard once the track-change grace has ruled out a song
    // boundary.
    await fromNative('playingChanged', {'playing': false});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.last, containsPair('playing', true));
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    expect(events.last, containsPair('playing', false));
  });

  test('playing follows the followed player', () async {
    await build({
      'ks.sendspin.ma_url': 'ma.local',
      'ks.sendspin.ma_token': 'token',
      'ks.sendspin.player': 'ma:p1',
      'ks.sendspin.player_source': 'ma',
      'ks.sendspin.player_name': 'Kitchen',
    });
    expect(remote, isNotNull);
    expect(remote!.playerId, 'p1');
    remote!.onSnapshot({'title': 'Song', 'playing': true});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.last, containsPair('playing', true));
    remote!.onSnapshot({'title': 'Song', 'playing': false});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.last, containsPair('playing', false));
  });

  test('turning the player off is heard', () async {
    await build(const {});
    await settings.set(defs.sendspinEnabled, false);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(events.last, containsPair('enabled', false));
    expect(events.last, containsPair('running', false));
  });
}
