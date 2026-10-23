import 'dart:async';

import '../sendspin/music_assistant_api.dart' show queueImageUrl;
import 'library_model.dart';

/// Music Assistant's library: recommendations, search across every
/// provider, the library lists, each provider's own tree and playback
/// into a player's queue.
class MaLibrarySource extends LibrarySource {
  MaLibrarySource({
    required this.call,
    required this.webBase,
    required this.ownQueueId,
  });

  /// One Music Assistant command, answered `{ok, result}` or `{ok: false,
  /// error: {code, message}}`.
  final Future<Map<String, Object?>> Function(
    String command,
    Map<String, Object?> args,
  )
  call;

  /// Music Assistant's web address, which serves the image proxy.
  final String? Function() webBase;

  /// The queue of this device's own player, for a play with no speaker
  /// picked. Empty when Music Assistant does not know it.
  final Future<String> Function() ownQueueId;

  static const pageSize = 60;

  static const _lists = {
    'artists': LibraryKind.artist,
    'albums': LibraryKind.album,
    'tracks': LibraryKind.track,
    'playlists': LibraryKind.playlist,
    'radios': LibraryKind.radio,
    'podcasts': LibraryKind.podcast,
    'audiobooks': LibraryKind.audiobook,
  };

  @override
  String get key => 'ma';

  @override
  bool get hasDiscover => true;

  @override
  bool get hasSearch => true;

  @override
  bool get hasBrowse => true;

  @override
  bool get hasRadioMode => true;

  @override
  bool get hasFavorites => true;

  @override
  List<LibraryCategory> get categories => [
    for (final e in _lists.entries) LibraryCategory(e.key, e.value),
  ];

  /// This device's own player is a Music Assistant player too.
  @override
  bool needsSpeaker(String pick) => !(pick.isEmpty || pick.startsWith('ma:'));

  Future<Object?> _call(String command, [Map<String, Object?>? args]) async {
    final res = await call(command, args ?? const {});
    if (res['ok'] == true) return res['result'];
    final error = res['error'];
    final message = error is Map ? '${error['message'] ?? error['code']}' : '';
    throw LibraryError(
      message.isEmpty ? 'Music Assistant did not answer' : message,
    );
  }

  Future<List<Map>> _list(String command, [Map<String, Object?>? args]) async {
    final result = await _call(command, args);
    return result is List ? result.whereType<Map>().toList() : const [];
  }

  @override
  Future<List<LibraryShelf>> discover() async {
    final shelves = <LibraryShelf>[];
    // The server's own recommendations first, the ones that have
    // anything in them.
    try {
      for (final folder in await _list('music/recommendations')) {
        final items = _items(folder['items']);
        if (items.isEmpty) continue;
        shelves.add(
          LibraryShelf(title: '${folder['name'] ?? ''}', items: items),
        );
      }
    } on LibraryError {
      // An older server without recommendations: the shelves below.
    }
    if (shelves.isNotEmpty) return shelves;
    // Built from the library when the server recommends nothing.
    Future<LibraryShelf> shelf(
      String key,
      String command,
      Map<String, Object?> args,
    ) async {
      try {
        return LibraryShelf(
          key: key,
          items: _items(await _call(command, args)),
        );
      } on LibraryError {
        return LibraryShelf(key: key, items: const []);
      }
    }

    final built = await Future.wait([
      shelf('recent', 'music/recently_played_items', {'limit': 20}),
      shelf('playlists', 'music/playlists/library_items', {
        'limit': 20,
        'order_by': 'last_played_desc',
      }),
      shelf('added', 'music/tracks/library_items', {
        'limit': 20,
        'order_by': 'timestamp_added_desc',
      }),
      shelf('radio', 'music/radios/library_items', {'limit': 20}),
    ]);
    return [
      for (final s in built)
        if (s.items.isNotEmpty) s,
    ];
  }

  @override
  Future<List<LibraryShelf>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final result = await _call('music/search', {
      'search_query': q,
      'media_types': const [
        'artist',
        'album',
        'track',
        'playlist',
        'radio',
        'podcast',
        'audiobook',
      ],
      'limit': 20,
    });
    if (result is! Map) return const [];
    return [
      for (final key in const [
        'tracks',
        'artists',
        'albums',
        'playlists',
        'radio',
        'podcasts',
        'audiobooks',
      ])
        if (_items(result[key]) case final items when items.isNotEmpty)
          LibraryShelf(key: key, items: items),
    ];
  }

  @override
  Future<LibraryPage> list(
    LibraryCategory category, {
    int offset = 0,
    bool favorites = false,
  }) async {
    final rows = await _list('music/${category.key}/library_items', {
      'limit': pageSize,
      'offset': offset,
      'order_by': 'sort_name',
      if (favorites) 'favorite': true,
    });
    return LibraryPage(items: _items(rows), more: rows.length >= pageSize);
  }

  @override
  Future<LibraryPage> browse(LibraryItem? folder) async {
    final path = folder == null ? null : (folder.raw as Map?)?['path'];
    final rows = await _list('music/browse', {'path': ?path});
    return LibraryPage(
      items: _items(
        rows.where((r) => r['name'] != '..' && r['path'] != 'root'),
      ),
    );
  }

  Map<String, Object?> _ref(LibraryItem item) {
    final raw = item.raw as Map? ?? const {};
    return {
      'item_id': '${raw['item_id'] ?? ''}',
      'provider_instance_id_or_domain': '${raw['provider'] ?? ''}',
    };
  }

  @override
  Future<LibraryDetail> open(LibraryItem item) async {
    final raw = item.raw as Map? ?? const {};
    switch (item.kind) {
      case LibraryKind.album:
        final tracks = _items(
          await _call('music/albums/album_tracks', _ref(item)),
        );
        return LibraryDetail(
          item: item,
          year: raw['year'] is int ? raw['year'] as int : null,
          tracks: tracks,
        );
      case LibraryKind.playlist:
        return LibraryDetail(
          item: item,
          tracks: _items(
            await _call('music/playlists/playlist_tracks', _ref(item)),
          ),
        );
      case LibraryKind.podcast:
        return LibraryDetail(
          item: item,
          tracks: _items(
            await _call('music/podcasts/podcast_episodes', _ref(item)),
          ),
        );
      case LibraryKind.artist:
        final results = await Future.wait([
          _call('music/artists/artist_tracks', _ref(item)),
          _call('music/artists/artist_albums', _ref(item)),
        ]);
        final albums = _items(results[1]);
        return LibraryDetail(
          item: item,
          tracks: _items(results[0]).take(10).toList(),
          shelves: [
            if (albums.isNotEmpty) LibraryShelf(key: 'albums', items: albums),
          ],
        );
      case LibraryKind.folder:
        return LibraryDetail(item: item, tracks: (await browse(item)).items);
      default:
        return LibraryDetail(item: item);
    }
  }

  @override
  Future<String?> play(
    LibraryItem item,
    PlayMode mode, {
    required String pick,
    LibraryItem? within,
  }) async {
    final queue = pick.startsWith('ma:')
        ? pick.substring(3)
        : pick.isEmpty
        ? await ownQueueId()
        : '';
    if (queue.isEmpty) return 'no_speaker';
    // A track tapped inside an album or playlist plays the rest of it
    // from there.
    final inside = within != null && item.kind == LibraryKind.track;
    try {
      await _call('player_queues/play_media', {
        'queue_id': queue,
        'media': inside ? within.id : item.id,
        'option': switch (mode) {
          PlayMode.replace || PlayMode.radio => 'replace',
          PlayMode.now => 'play',
          PlayMode.next => 'next',
          PlayMode.add => 'add',
        },
        'radio_mode': mode == PlayMode.radio,
        if (inside) 'start_item': (item.raw as Map?)?['item_id'],
      });
      return null;
    } on LibraryError catch (e) {
      return e.message;
    }
  }

  @override
  Future<bool> setFavorite(LibraryItem item, bool favorite) async {
    try {
      if (favorite) {
        await _call('music/favorites/add_item', {'item': item.id});
        return true;
      }
      // Taking it out needs the library's own copy.
      final copy = await _call('music/item_by_uri', {'uri': item.id});
      if (copy is! Map) return false;
      await _call('music/favorites/remove_item', {
        'media_type': copy['media_type'],
        'library_item_id': copy['item_id'],
      });
      return true;
    } on LibraryError {
      return false;
    }
  }

  List<LibraryItem> _items(Object? rows) => [
    if (rows is Iterable)
      for (final row in rows.whereType<Map>()) ?_item(row),
  ];

  LibraryItem? _item(Map m) {
    final kind = switch ('${m['media_type'] ?? ''}') {
      'artist' => LibraryKind.artist,
      'album' => LibraryKind.album,
      'track' => LibraryKind.track,
      'playlist' => LibraryKind.playlist,
      'radio' => LibraryKind.radio,
      'podcast' => LibraryKind.podcast,
      'podcast_episode' => LibraryKind.episode,
      'audiobook' => LibraryKind.audiobook,
      'folder' => LibraryKind.folder,
      _ => null,
    };
    if (kind == null) return null;
    final names = [
      for (final a in (m['artists'] as List? ?? const []).whereType<Map>())
        '${a['name'] ?? ''}',
    ].where((n) => n.isNotEmpty);
    final owner = '${m['owner'] ?? ''}';
    final duration = m['duration'];
    return LibraryItem(
      id: '${m['uri'] ?? ''}',
      kind: kind,
      title: '${m['name'] ?? ''}',
      subtitle: switch (kind) {
        LibraryKind.track || LibraryKind.album => names.join(', '),
        LibraryKind.playlist => owner,
        LibraryKind.audiobook => [
          for (final a in (m['authors'] as List? ?? const [])) '$a',
        ].join(', '),
        LibraryKind.podcast => '${m['publisher'] ?? ''}',
        _ => '',
      },
      art: _art(m),
      playable: kind == LibraryKind.folder ? m['is_playable'] == true : true,
      expandable: switch (kind) {
        LibraryKind.artist ||
        LibraryKind.album ||
        LibraryKind.playlist ||
        LibraryKind.podcast ||
        LibraryKind.folder => true,
        _ => false,
      },
      durationMs: duration is num && duration > 0
          ? (duration * 1000).round()
          : null,
      favorite: m['favorite'] == true,
      inLibrary: '${m['provider'] ?? ''}' == 'library',
      raw: m,
    );
  }

  String? _art(Map m) {
    final base = webBase();
    final metadata = m['metadata'];
    return queueImageUrl(m['image'], base, size: 256) ??
        (metadata is Map
            ? queueImageUrl(metadata['images'], base, size: 256)
            : null) ??
        (m['album'] is Map
            ? queueImageUrl((m['album'] as Map)['image'], base, size: 256)
            : null);
  }
}
