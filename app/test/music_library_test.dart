import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/managers/music_library/ha_library_source.dart';
import 'package:kiosk_satellite/managers/music_library/library_model.dart';
import 'package:kiosk_satellite/managers/music_library/ma_library_source.dart';
import 'package:kiosk_satellite/managers/music_library/music_requests.dart';
import 'package:kiosk_satellite/managers/music_library/sonos_library_source.dart';
import 'package:kiosk_satellite/managers/sendspin/music_assistant_api.dart';
import 'package:kiosk_satellite/ui/music_library_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Music Assistant answering from canned results, recording each call.
class _FakeMa {
  final calls = <(String, Map<String, Object?>)>[];
  final answers = <String, Object?>{};

  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> args,
  ) async {
    calls.add((command, args));
    if (!answers.containsKey(command)) {
      return {
        'ok': false,
        'error': {'code': 'unknown', 'message': 'no $command'},
      };
    }
    return {'ok': true, 'result': answers[command]};
  }
}

Map<String, Object?> _track(String id, String name, {int duration = 200}) => {
  'media_type': 'track',
  'item_id': id,
  'provider': 'library',
  'uri': 'library://track/$id',
  'name': name,
  'duration': duration,
  'artists': [
    {'name': 'Juniper Lane', 'uri': 'library://artist/1', 'item_id': '1'},
  ],
  'image': {'path': 'x', 'proxy_id': 'p$id'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Music Assistant source', () {
    MaLibrarySource source(_FakeMa ma, {String own = 'up-own'}) =>
        MaLibrarySource(
          call: ma.call,
          webBase: () => 'https://ma.local',
          ownQueueId: () async => own,
        );

    test('lists entries with their covers through the image proxy', () async {
      final ma = _FakeMa()
        ..answers['music/tracks/library_items'] = [
          _track('1', 'Tidelines'),
          {'media_type': 'genre', 'name': 'skipped'},
        ];
      final page = await source(
        ma,
      ).list(const LibraryCategory('tracks', LibraryKind.track));
      expect(page.items, hasLength(1));
      final item = page.items.single;
      expect(item.title, 'Tidelines');
      expect(item.subtitle, 'Juniper Lane');
      expect(item.durationMs, 200000);
      expect(item.art, 'https://ma.local/imageproxy/p1?size=256&fmt=jpg');
      expect(page.more, isFalse);
    });

    test(
      'builds Discover from the library when nothing is recommended',
      () async {
        final ma = _FakeMa()
          ..answers['music/recommendations'] = [
            {'name': 'In progress', 'items': <Object>[]},
          ]
          ..answers['music/recently_played_items'] = [_track('1', 'One')]
          ..answers['music/playlists/library_items'] = <Object>[]
          ..answers['music/tracks/library_items'] = [_track('2', 'Two')];
        final shelves = await source(ma).discover();
        expect(shelves.map((s) => s.key), ['recent', 'added']);
      },
    );

    test('a track tapped in a playlist plays the playlist from it', () async {
      final ma = _FakeMa()..answers['player_queues/play_media'] = null;
      final playlist = LibraryItem(
        id: 'library://playlist/5',
        kind: LibraryKind.playlist,
        title: 'Night Shift',
      );
      final track = LibraryItem(
        id: 'library://track/7',
        kind: LibraryKind.track,
        title: 'Tidelines',
        raw: _track('7', 'Tidelines'),
      );
      final error = await source(
        ma,
      ).play(track, PlayMode.replace, pick: 'ma:living', within: playlist);
      expect(error, isNull);
      final (command, args) = ma.calls.single;
      expect(command, 'player_queues/play_media');
      expect(args['queue_id'], 'living');
      expect(args['media'], 'library://playlist/5');
      expect(args['start_item'], '7');
      expect(args['option'], 'replace');
    });

    test('plays on this device through its own queue', () async {
      final ma = _FakeMa()..answers['player_queues/play_media'] = null;
      final item = LibraryItem(
        id: 'library://album/3',
        kind: LibraryKind.album,
        title: 'Glass Harbor',
      );
      expect(await source(ma).play(item, PlayMode.add, pick: ''), isNull);
      expect(ma.calls.single.$2['queue_id'], 'up-own');
      expect(ma.calls.single.$2['option'], 'add');
      expect(
        await source(ma, own: '').play(item, PlayMode.add, pick: ''),
        'no_speaker',
      );
    });

    test('needs a Music Assistant speaker, or this device', () {
      final s = source(_FakeMa());
      expect(s.needsSpeaker(''), isFalse);
      expect(s.needsSpeaker('ma:x'), isFalse);
      expect(s.needsSpeaker('ha:media_player.x'), isTrue);
    });
  });

  group('Home Assistant source', () {
    test('hides the picture and speech sources at the root', () async {
      final sent = <Map<String, Object?>>[];
      final source = HaLibrarySource(
        baseUrl: () => 'https://ha.local',
        request: (command) async {
          sent.add(command);
          if (command['type'] == 'get_states') {
            return [
              {
                'entity_id': 'media_player.kitchen',
                'attributes': {'supported_features': 4194304 | 2097152},
              },
            ];
          }
          return {
            'title': 'Root',
            'children': [
              {
                'title': 'Radio Browser',
                'media_class': 'app',
                'media_content_id': 'media-source://radio_browser',
                'media_content_type': 'app',
                'can_expand': true,
                'thumbnail': '/api/brands/integration/radio_browser/logo.png',
              },
              {
                'title': 'Camera',
                'media_class': 'app',
                'media_content_id': 'media-source://camera',
                'can_expand': true,
              },
            ],
          };
        },
      );
      await expectLater(source.browse(null), throwsA(isA<LibraryError>()));
      await source.follow('ha:media_player.kitchen');
      expect(source.hasSearch, isTrue);
      final page = await source.browse(null);
      expect(page.items.map((i) => i.title), ['Radio Browser']);
      expect(
        page.items.single.art,
        'https://ha.local/api/brands/integration/radio_browser/logo.png',
      );
      expect(page.items.single.kind, LibraryKind.folder);
    });

    test('plays with the queue mode the speaker supports', () async {
      final sent = <Map<String, Object?>>[];
      final source = HaLibrarySource(
        baseUrl: () => '',
        request: (command) async {
          sent.add(command);
          if (command['type'] == 'get_states') {
            return [
              {
                'entity_id': 'media_player.kitchen',
                'attributes': {'supported_features': 2097152},
              },
            ];
          }
          return null;
        },
      );
      await source.follow('ha:media_player.kitchen');
      final item = LibraryItem(
        id: 'media-source://radio_browser/x',
        kind: LibraryKind.radio,
        title: 'Coastline FM',
        raw: const {
          'media_content_id': 'media-source://radio_browser/x',
          'media_content_type': 'audio/mpeg',
        },
      );
      expect(
        await source.play(item, PlayMode.next, pick: 'ha:media_player.kitchen'),
        isNull,
      );
      final call = sent.last;
      expect(call['service'], 'play_media');
      expect((call['service_data'] as Map)['enqueue'], 'next');
      expect(await source.play(item, PlayMode.next, pick: ''), 'no_speaker');
    });
  });

  group('Sonos source', () {
    test('reads favorites, their kind from the metadata they carry', () {
      const didl =
          '<DIDL-Lite><item id="FV:2/7" parentID="FV:2" restricted="false">'
          '<dc:title>Hit List</dc:title>'
          '<upnp:class>object.itemobject.item.sonos-favorite</upnp:class>'
          '<res protocolInfo="x-sonosapi-radio:*:*:*">'
          'x-sonosapi-radio:sonos%3a2997?sid=303&amp;flags=0</res>'
          '<upnp:albumArtURI>/getaa?s=1</upnp:albumArtURI>'
          '<r:type>instantPlay</r:type><r:description>Sonos Radio</r:description>'
          '<r:resMD>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;upnp:class&gt;'
          'object.item.audioItem.audioBroadcast&lt;/upnp:class&gt;'
          '&lt;/item&gt;&lt;/DIDL-Lite&gt;</r:resMD></item>'
          '<item id="FV:2/1" parentID="FV:2" restricted="false">'
          '<dc:title>Discover</dc:title><res></res><r:type>shortcut</r:type>'
          '</item></DIDL-Lite>';
      final items = SonosLibrarySource.parseEntries(
        didl,
        baseUrl: 'http://10.0.0.2:1400',
      );
      expect(items, hasLength(2));
      final hit = items.first;
      expect(hit.kind, LibraryKind.radio);
      expect(hit.subtitle, 'Sonos Radio');
      expect(hit.art, 'http://10.0.0.2:1400/getaa?s=1');
      expect(hit.playable, isTrue);
      expect(hit.expandable, isFalse);
      expect(
        (hit.raw! as Map)['uri'],
        'x-sonosapi-radio:sonos%3a2997?sid=303&flags=0',
      );
      expect(
        SonosLibrarySource.isStream((hit.raw! as Map)['uri'] as String),
        isTrue,
      );
      // A shortcut has nothing to play.
      expect(items.last.playable, isFalse);
    });
  });

  group('music by voice', () {
    LibraryItem item(String title, LibraryKind kind, [String by = '']) =>
        LibraryItem(id: title, kind: kind, title: title, subtitle: by);

    test('an exact title wins, an artist over a track of that name', () {
      final best = MusicRequests.bestMatch([
        LibraryShelf(
          key: 'tracks',
          items: [
            item('Punisher', LibraryKind.track, 'Phoebe Bridgers'),
            item('Punisher (Live)', LibraryKind.track, 'Phoebe Bridgers'),
          ],
        ),
        LibraryShelf(
          key: 'albums',
          items: [item('Punisher', LibraryKind.album, 'Phoebe Bridgers')],
        ),
      ], query: 'punisher')!;
      expect(best.item.kind, LibraryKind.album);
      expect(best.others.single.kind, LibraryKind.track);
    });

    test('with an artist named, other bands of that name stay out', () {
      final best = MusicRequests.bestMatch(
        [
          LibraryShelf(
            key: 'artists',
            items: [
              item('Punisher', LibraryKind.artist),
              item('Punisher', LibraryKind.artist),
            ],
          ),
          LibraryShelf(
            key: 'albums',
            items: [item('Punisher', LibraryKind.album, 'Phoebe Bridgers')],
          ),
          LibraryShelf(
            key: 'tracks',
            items: [item('Punisher', LibraryKind.track, 'Phoebe Bridgers')],
          ),
        ],
        query: 'Punisher',
        artist: 'Phoebe Bridgers',
      )!;
      expect(best.item.kind, LibraryKind.album);
      expect(best.others.map((o) => o.kind), [LibraryKind.track]);
    });

    test('a track in the library wins over a stranger of that name', () {
      final best = MusicRequests.bestMatch([
        LibraryShelf(key: 'artists', items: [item('Sola', LibraryKind.artist)]),
        LibraryShelf(
          key: 'tracks',
          items: [
            LibraryItem(
              id: 'library://track/9',
              kind: LibraryKind.track,
              title: 'Sola',
              subtitle: 'Hillkidd',
              inLibrary: true,
            ),
          ],
        ),
      ], query: 'Sola')!;
      expect(best.item.kind, LibraryKind.track);
      expect(best.item.inLibrary, isTrue);
    });

    test('a name heard as one word finds it written as two', () {
      final best = MusicRequests.bestMatch([
        LibraryShelf(
          key: 'artists',
          items: [item('Nightshift', LibraryKind.artist)],
        ),
        LibraryShelf(
          key: 'tracks',
          items: [
            LibraryItem(
              id: 'library://track/3',
              kind: LibraryKind.track,
              title: 'Night Shift',
              subtitle: 'Lucy Dacus',
              inLibrary: true,
            ),
          ],
        ),
      ], query: 'Nightshift')!;
      expect(best.item.title, 'Night Shift');
    });

    test('the kind and the artist narrow it down', () {
      final shelves = [
        LibraryShelf(
          key: 'tracks',
          items: [
            item('Blouse', LibraryKind.track, 'Someone Else'),
            item('Blouse', LibraryKind.track, 'Clairo'),
          ],
        ),
        LibraryShelf(
          key: 'albums',
          items: [item('Blouse', LibraryKind.album, 'Clairo')],
        ),
      ];
      final track = MusicRequests.bestMatch(
        shelves,
        query: 'Blouse',
        kind: 'track',
        artist: 'clairo',
      )!;
      expect(track.item.kind, LibraryKind.track);
      expect(track.item.subtitle, 'Clairo');
      expect(
        MusicRequests.bestMatch(shelves, query: 'x', kind: 'radio'),
        isNull,
      );
    });

    test('a genre with no title match takes the first track', () {
      final best = MusicRequests.bestMatch([
        LibraryShelf(
          key: 'playlists',
          items: [item('Chill Mix', LibraryKind.playlist)],
        ),
        LibraryShelf(
          key: 'tracks',
          items: [item('Lanterns', LibraryKind.track)],
        ),
      ], query: 'jazz')!;
      expect(best.item.title, 'Lanterns');
    });

    test('play lands on the speaker this kiosk follows', () async {
      SharedPreferences.setMockInitialValues({
        'ks.ha.url': '',
        'ks.ha.token': '',
        'ks.sendspin.ma_url': 'ma.local:8095',
        'ks.sendspin.ma_token': 'token',
        'ks.sendspin.client_id': 'tablet',
        'ks.sendspin.player_source': 'ma',
        'ks.sendspin.player': 'ma:kitchen',
        'ks.sendspin.player_name': 'Kitchen',
      });
      final c = AppContainer();
      await c.settings.init();
      final source = _VoiceSource();
      c.musicLibrary.sourceFactory = (_) => source;
      await c.musicLibrary.init();
      final r = await c.musicLibrary.requests.handle({
        'action': 'play',
        'query': 'Punisher',
        'artist': 'Phoebe Bridgers',
        'mode': 'next',
      });
      expect(r['ok'], isTrue, reason: '$r');
      expect(r['result'], 'playing_next');
      expect(r['title'], 'Punisher');
      expect(r['speaker'], 'Kitchen');
      expect(source.played.single, ('Punisher', PlayMode.next, 'ma:kitchen'));
      final none = await c.musicLibrary.requests.handle({
        'action': 'play',
        'query': 'Nothing like it',
        'kind': 'radio',
      });
      expect(none['ok'], isFalse);
      expect(none['error'], 'nothing_found');
    });
  });

  group('the overlay', () {
    final album = LibraryItem(
      id: 'library://album/1',
      kind: LibraryKind.album,
      title: 'Glass Harbor',
      subtitle: 'Juniper Lane',
      expandable: true,
      raw: const {'year': 2024},
    );

    Future<AppContainer> container() async {
      SharedPreferences.setMockInitialValues({
        'ks.ha.url': '',
        'ks.ha.token': '',
        'ks.sendspin.ma_url': 'ma.local:8095',
        'ks.sendspin.ma_token': 'token',
        'ks.sendspin.client_id': 'tablet',
        // Now Playing on, so the player bar draws its every button.
        'ks.sendspin.fullscreen': true,
      });
      final c = AppContainer();
      await c.settings.init();
      c.musicLibrary.sourceFactory = (_) => _FakeSource(album);
      // No test reaches a real Music Assistant.
      c.sendspin.apiFactory = ({required baseUrl, required token}) =>
          _QueueApi();
      await c.musicLibrary.init();
      return c;
    }

    for (final (name, size) in [
      ('a tablet', const Size(1280, 800)),
      ('a tablet in portrait', const Size(753, 1205)),
      ('an Echo Show 5', const Size(960, 480)),
      ('an Echo Show 5 at 1.22x', const Size(788, 394)),
      ('a phone', const Size(390, 844)),
    ]) {
      testWidgets('Discover and an album draw on $name', (tester) async {
        final c = await container();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        c.musicLibrary.visible.value = true;
        // A track playing, so the player bar draws every control.
        c.sendspin.nowPlaying.value = {
          'title': 'A long track title that goes on for a while',
          'artist': 'Juniper Lane',
          'playing': true,
          'durationMs': 200000,
          'positionMs': 60000,
          'receivedAt': DateTime.now().millisecondsSinceEpoch,
          'shuffle': false,
          'repeat': 'off',
          'supportedCommands': const <String>[],
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(children: [MusicLibraryOverlay(container: c)]),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(find.text('Glass Harbor'), findsWidgets);
        await tester.tap(find.text('Glass Harbor').first);
        await tester.pump(const Duration(milliseconds: 100));
        // The album loads after the frame that asked for it.
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: 'album on $name');
        expect(find.text('Track 1'), findsOneWidget);
        // Back steps out of the album before it closes the library.
        expect(c.musicLibrary.backHandler?.call(), isTrue);
        await tester.pump(const Duration(milliseconds: 100));
        expect(c.musicLibrary.backHandler?.call(), isFalse);
        c.musicLibrary.visible.value = false;
        c.sendspin.nowPlaying.value = null;
        await tester.pump();
      });
    }

    for (final (name, close) in [
      (
        'a screensaver starts',
        (AppContainer c) {
          c.screensaver.activeView.value = 'clock';
        },
      ),
      (
        'the library closes',
        (AppContainer c) {
          c.musicLibrary.visible.value = false;
        },
      ),
    ]) {
      testWidgets('the Speakers sheet goes when $name', (tester) async {
        final c = await container();
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        c.musicLibrary.visible.value = true;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(children: [MusicLibraryOverlay(container: c)]),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.bySemanticsLabel(RegExp(r'^Speakers: ')));
        await tester.pumpAndSettle();
        expect(find.text('Speakers'), findsOneWidget);
        close(c);
        await tester.pumpAndSettle();
        expect(find.text('Speakers'), findsNothing);
        c.screensaver.activeView.value = null;
        c.musicLibrary.visible.value = false;
        await tester.pump();
      });
    }

    for (final (name, size) in [
      ('a tablet', const Size(1280, 800)),
      ('a phone', const Size(390, 844)),
    ]) {
      testWidgets('the queue opens, reorders and removes on $name', (
        tester,
      ) async {
        final c = await container();
        final api = _QueueApi();
        c.sendspin.apiFactory = ({required baseUrl, required token}) => api;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        c.musicLibrary.visible.value = true;
        c.sendspin.nowPlaying.value = {
          'title': 'Track A',
          'artist': 'Juniper Lane',
          'playing': false,
          'durationMs': 200000,
          'positionMs': 0,
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(children: [MusicLibraryOverlay(container: c)]),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byTooltip('Show queue'));
        await tester.pumpAndSettle();
        expect(find.text('Queue'), findsOneWidget);
        expect(find.text('Track B'), findsOneWidget);
        expect(find.text('Track D'), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Swipe a row away: Music Assistant deletes it.
        await tester.drag(find.text('Track C'), const Offset(-600, 0));
        await tester.pumpAndSettle();
        expect(api.calls, contains('player_queues/delete_item'));
        expect(
          api.args['player_queues/delete_item'],
          containsPair('item_id_or_index', 'c'),
        );
        // Clear asks first.
        await tester.tap(find.text('Clear').first);
        await tester.pumpAndSettle();
        expect(find.text('Clear the queue?'), findsOneWidget);
        await tester.tap(find.text('Clear').last);
        await tester.pumpAndSettle();
        expect(api.calls, contains('player_queues/clear'));
        c.musicLibrary.visible.value = false;
        c.sendspin.nowPlaying.value = null;
        await tester.pump(const Duration(seconds: 1));
      });
    }

    testWidgets('with nothing playing the bar shows the queue to resume', (
      tester,
    ) async {
      final c = await container();
      final api = _QueueApi();
      c.sendspin.apiFactory = ({required baseUrl, required token}) => api;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      c.musicLibrary.visible.value = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(children: [MusicLibraryOverlay(container: c)]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nothing playing'), findsNothing);
      expect(find.text('Track A'), findsOneWidget);
      // Play resumes the queue on its current track.
      await tester.tap(find.byTooltip('Play').last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('player_queues/play_index'));
      expect(api.args['player_queues/play_index'], containsPair('index', 'a'));
      c.musicLibrary.visible.value = false;
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

class _QueueApi extends MusicAssistantApi {
  _QueueApi() : super(baseUrl: 'ma.local', token: 't');

  final calls = <String>[];
  final args = <String, Map<String, Object?>>{};

  @override
  Future<MusicAssistantResult> call(
    String command, {
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add(command);
    this.args[command] = args;
    Map<String, Object?> item(String id) => {
      'queue_item_id': id,
      'duration': 200,
      'media_item': {
        'name': 'Track ${id.toUpperCase()}',
        'artists': [
          {'name': 'Juniper Lane'},
        ],
      },
    };
    final Object? result = switch (command) {
      'player_queues/get_active_queue' => {
        'queue_id': 'q1',
        'current_index': 0,
        'items': 4,
        'current_item': {'queue_item_id': 'a'},
      },
      'player_queues/items' => [
        for (final id in ['a', 'b', 'c', 'd']) item(id),
      ],
      _ => null,
    };
    return MusicAssistantResult.success(result, const {});
  }
}

class _FakeSource extends LibrarySource {
  _FakeSource(this.album);

  final LibraryItem album;

  @override
  String get key => 'ma';

  @override
  bool get hasDiscover => true;

  @override
  bool get hasSearch => true;

  @override
  bool needsSpeaker(String pick) => false;

  @override
  List<LibraryCategory> get categories => const [
    LibraryCategory('albums', LibraryKind.album),
    LibraryCategory('tracks', LibraryKind.track),
  ];

  @override
  Future<List<LibraryShelf>> discover() async => [
    LibraryShelf(key: 'recent', items: [album]),
    LibraryShelf(title: 'From the server', items: [album]),
  ];

  @override
  Future<LibraryDetail> open(LibraryItem item) async => LibraryDetail(
    item: item,
    year: 2024,
    tracks: [
      for (var i = 1; i <= 12; i++)
        LibraryItem(
          id: 't$i',
          kind: LibraryKind.track,
          title: 'Track $i',
          subtitle: 'Juniper Lane',
          durationMs: 200000,
        ),
    ],
  );

  @override
  Future<String?> play(
    LibraryItem item,
    PlayMode mode, {
    required String pick,
    LibraryItem? within,
  }) async => null;
}

class _VoiceSource extends LibrarySource {
  final played = <(String, PlayMode, String)>[];

  @override
  String get key => 'ma';

  @override
  bool get hasSearch => true;

  @override
  Future<List<LibraryShelf>> search(String query) async => [
    LibraryShelf(
      key: 'tracks',
      items: [
        LibraryItem(
          id: 'library://track/1',
          kind: LibraryKind.track,
          title: 'Punisher',
          subtitle: 'Phoebe Bridgers',
        ),
      ],
    ),
  ];

  @override
  Future<LibraryDetail> open(LibraryItem item) async =>
      LibraryDetail(item: item);

  @override
  Future<String?> play(
    LibraryItem item,
    PlayMode mode, {
    required String pick,
    LibraryItem? within,
  }) async {
    played.add((item.title, mode, pick));
    return null;
  }
}
