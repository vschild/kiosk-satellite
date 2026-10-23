import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart';

import '../../core/certificate_log.dart';
import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../analytics/usage_counters.dart';
import '../sendspin/artwork_cache.dart';
import '../sendspin/music_assistant_api.dart' show musicAssistantWebUrl;
import '../sendspin/plugin_ma_socket.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import '../voice/ha_socket.dart';
import 'ha_library_source.dart';
import 'library_model.dart';
import 'ma_library_source.dart';
import 'music_requests.dart';
import 'sonos_library_source.dart';

/// A speaker the library can play on: a row of the Speakers sheet.
class LibrarySpeaker {
  const LibrarySpeaker({
    required this.pick,
    required this.name,
    this.available = true,
    this.self = false,
  });

  /// The player pick it writes: '' for this device, else `ma:`, `ha:` or
  /// `sonos:` and the player's id.
  final String pick;
  final String name;
  final bool available;

  /// This device's own player.
  final bool self;
}

/// The Music Library: a full screen overlay that browses Music Assistant,
/// a Home Assistant speaker's media or a Sonos household and plays on the
/// player Now Playing follows. Picking a speaker here picks the followed
/// player, so the floating player and Now Playing move with it.
class MusicLibraryManager extends Manager {
  MusicLibraryManager(
    super.bus,
    super.commands,
    super.log,
    this._settings, {
    MaPluginSocket? ma,
    HaSocket? ha,
  }) : _ma =
           ma ??
           MaPluginSocket(
             baseUrl: () => _settings.get(defs.sendspinMaUrl),
             token: () => _settings.get(defs.sendspinMaToken),
             log: log,
             maxResult: 0,
           ),
       _ha =
           ha ??
           HaSocket(
             baseUrl: () => _settings.get(defs.haUrl),
             token: () => _settings.get(defs.haToken),
           );

  final SettingsManager _settings;
  final MaPluginSocket _ma;
  final HaSocket _ha;

  @override
  String get name => 'library';

  /// The overlay is up.
  final visible = ValueNotifier<bool>(false);

  /// Bumped when an open arrives while it is already up.
  final reopened = ValueNotifier<int>(0);

  /// The source on screen; its sources come and go with their settings.
  final source = ValueNotifier<LibrarySource?>(null);

  /// Requests from the Kiosk Satellite music script.
  late final requests = MusicRequests(_settings, this, commands);

  /// Set by the open library: steps back out of an opened album or
  /// folder and answers true, or answers false at the top, where back
  /// closes the library.
  bool Function()? backHandler;

  /// The player pick, mirrored from the followed player setting.
  final pick = ValueNotifier<String>('');
  final pickName = ValueNotifier<String>('');

  final _sources = <String, LibrarySource>{};
  final _subs = <StreamSubscription<Object?>>[];
  final _art = ArtworkCache(maxBytes: 24 << 20, maxEntries: 400);

  @override
  Future<void> init() async {
    _readPick();
    _registerCommands();
    _subs
      ..add(
        bus.on<SettingChanged>().listen((e) {
          final key = e.key;
          if (key == defs.sendspinPlayer.key ||
              key == defs.sendspinPlayerName.key) {
            _readPick();
          } else if (key == defs.sendspinMaUrl.key ||
              key == defs.sendspinMaToken.key) {
            _ma.restart();
            _drop('ma');
          } else if (key == defs.haUrl.key || key == defs.haToken.key) {
            unawaited(_ha.close());
            _drop('ha');
          } else if (key == defs.sendspinSonosHosts.key) {
            _drop('sonos');
          } else if (key == defs.librarySource.key) {
            _pickSource();
          } else if (key == defs.kioskAllowMusicLibrary.key &&
              e.value != true) {
            visible.value = false;
          }
        }),
      )
      ..add(
        // The library holds the screensaver, so one starting now was asked
        // for. Now Playing comes up over the library and goes back to it;
        // anything else replaces it.
        bus.on<ScreensaverStateChanged>().listen((e) {
          if (e.active && !e.nowPlaying) visible.value = false;
        }),
      );
    visible.addListener(_onVisible);
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    visible.removeListener(_onVisible);
    for (final s in _sources.values) {
      s.dispose();
    }
    _sources.clear();
    _ma.dispose();
    _http.close(force: true);
    await _ha.close();
    visible.dispose();
    reopened.dispose();
    source.dispose();
    pick.dispose();
    pickName.dispose();
  }

  /// Browsing is not idle time: the screensaver waits while the library
  /// is up, and the library's own idle timer closes it.
  void _onVisible() {
    if (visible.value) _pickSource();
    unawaited(
      commands.execute('holdScreensaver', {
        'holder': 'library',
        'held': visible.value,
      }),
    );
  }

  void _readPick() {
    final p = _settings.get(defs.sendspinPlayer).trim();
    // A session or AirPlay pick plays on this device but is no speaker
    // the library can send music to.
    pick.value = p.startsWith('session:') || p == 'airplay' ? '' : p;
    pickName.value = _settings.get(defs.sendspinPlayerName);
    final ha = _sources['ha'];
    if (ha is HaLibrarySource) unawaited(ha.follow(pick.value));
  }

  /// Whether the followed player is one of [key]'s speakers. This
  /// device's own player counts for Music Assistant while Sendspin is on.
  bool pickIn(String key) {
    final p = pick.value;
    if (p.isEmpty) {
      return key == 'ma' &&
          _settings.get(defs.sendspinEnabled) &&
          _settings.get(defs.sendspinClientId).trim().isNotEmpty;
    }
    return p.startsWith('$key:');
  }

  bool get maConfigured =>
      _settings.get(defs.sendspinMaUrl).trim().isNotEmpty &&
      _settings.get(defs.sendspinMaToken).trim().isNotEmpty;

  bool get haConfigured =>
      _settings.get(defs.haUrl).trim().isNotEmpty &&
      _settings.get(defs.haToken).trim().isNotEmpty;

  Map<String, String> get _sonosHosts {
    try {
      final raw = jsonDecode(_settings.get(defs.sendspinSonosHosts));
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if (e.value is Map) '${e.key}': '${(e.value as Map)['host'] ?? ''}',
      };
    } catch (_) {
      return const {};
    }
  }

  /// The sources set up on this device, in the order the picker lists
  /// them.
  List<String> get available => [
    if (maConfigured) 'ma',
    if (haConfigured) 'ha',
    if (_sonosHosts.isNotEmpty) 'sonos',
  ];

  void _drop(String key) {
    _sources.remove(key)?.dispose();
    if (source.value?.key == key) _pickSource();
  }

  /// The source on screen: the one the library was left on, else the
  /// kind of player Now Playing follows, else the first one set up.
  void _pickSource() {
    final have = available;
    if (have.isEmpty) {
      source.value = null;
      return;
    }
    final saved = _settings.get(defs.librarySource);
    final followed = pick.value.contains(':')
        ? pick.value.substring(0, pick.value.indexOf(':'))
        : '';
    final key = have.contains(saved)
        ? saved
        : have.contains(followed)
        ? followed
        : have.first;
    final next = _sources.putIfAbsent(key, () => _build(key));
    if (!identical(source.value, next)) source.value = next;
  }

  /// Builds a source by key. Swapped in tests so no source opens a socket.
  @visibleForTesting
  LibrarySource Function(String key)? sourceFactory;

  LibrarySource _build(String key) =>
      sourceFactory?.call(key) ??
      switch (key) {
        'ha' => HaLibrarySource(
          request: (command) =>
              _ha.request(command, timeout: const Duration(seconds: 20)),
          baseUrl: () => defs.normalizeBaseUrl(_settings.get(defs.haUrl)),
        )..follow(pick.value),
        'sonos' => SonosLibrarySource(hosts: () => _sonosHosts),
        _ => MaLibrarySource(
          call: (command, args) => _ma.call('library', command, args),
          webBase: () =>
              musicAssistantWebUrl(_settings.get(defs.sendspinMaUrl)),
          ownQueueId: _ownQueueId,
        ),
      };

  Future<void> setSource(String key) => _settings.set(defs.librarySource, key);

  /// The source [key] names, built if need be, without changing the one
  /// on screen. Null when it is not set up.
  LibrarySource? sourceFor(String key) => available.contains(key)
      ? _sources.putIfAbsent(key, () => _build(key))
      : null;

  /// Where the next open lands: a search, or one of the source's lists.
  /// The screen takes it as it opens.
  ({String? query, String? category})? opening;

  Future<void> openAt({String? query, String? category}) async {
    opening = (query: query, category: category);
    await open();
  }

  /// The queue of this device's own Sendspin player in Music Assistant.
  Future<String> _ownQueueId() async {
    final self = _settings.get(defs.sendspinClientId).trim();
    if (self.isEmpty || !_settings.get(defs.sendspinEnabled)) return '';
    final res = await _ma.call('library', 'player_queues/get_active_queue', {
      'player_id': self,
    });
    final queue = res['result'];
    return res['ok'] == true && queue is Map
        ? '${queue['queue_id'] ?? ''}'
        : '';
  }

  /// The speakers of [key]'s source, this device's own player first
  /// where it is one of them.
  Future<(List<LibrarySpeaker>, String?)> speakers(String key) async {
    final listed = await commands.execute('mediaPlayers', {
      'source': key,
      if (key == 'sonos') 'rooms': false,
    });
    final data = listed.data;
    final rows = (data is Map ? data['players'] as List? : null) ?? const [];
    final notes = data is Map ? data['notes'] : null;
    final self =
        key == 'ma' &&
        _settings.get(defs.sendspinEnabled) &&
        _settings.get(defs.sendspinClientId).trim().isNotEmpty;
    final speakers = [
      for (final r in rows.whereType<Map>())
        LibrarySpeaker(
          pick: '${r['id']}',
          name: '${r['name']}',
          available: r['available'] != false,
        ),
    ];
    return (
      [
        if (self)
          LibrarySpeaker(
            pick: '',
            name: _settings.get(defs.sendspinLocalPlayerName).trim().isEmpty
                ? _settings.get(defs.deviceName)
                : _settings.get(defs.sendspinLocalPlayerName),
            self: true,
          ),
        // The ones that can play first, each group in the listed order.
        ...speakers.where((s) => s.available),
        ...speakers.where((s) => !s.available),
      ],
      notes is Map ? notes[key] as String? : null,
    );
  }

  /// Follow [speaker]: the player Now Playing, the floating player and
  /// every play from here land on.
  Future<bool> follow(LibrarySpeaker speaker) async {
    final key = speaker.pick.contains(':')
        ? speaker.pick.substring(0, speaker.pick.indexOf(':'))
        : 'device';
    final result = await commands.execute('mediaPlayerSet', {
      'source': key,
      'player': speaker.pick,
    });
    if (!result.ok) log.warn(name, 'follow ${speaker.pick}: ${result.error}');
    return result.ok;
  }

  /// Play [item] on the followed speaker. Answers null, 'no_speaker' when
  /// one of this source must be picked first, or the error.
  Future<String?> play(
    LibraryItem item,
    PlayMode mode, {
    LibraryItem? within,
  }) async {
    final src = source.value;
    if (src == null) return 'no_source';
    if (!pickIn(src.key)) return 'no_speaker';
    final error = await src.play(item, mode, pick: pick.value, within: within);
    if (error == null) {
      unawaited(UsageCounters.bump(_settings, 'library_plays'));
      log.info(name, 'play ${item.kind.name} ${mode.name} on ${pick.value}');
    } else {
      log.warn(name, 'play ${item.id} on ${pick.value}: $error');
    }
    return error;
  }

  Future<void> open() async {
    unawaited(UsageCounters.bump(_settings, 'library_opens'));
    await commands.execute('screenOn', const {});
    await commands.execute('bringToFront', const {});
    await commands.execute('stopScreensaver', const {});
    if (visible.value) reopened.value++;
    visible.value = true;
  }

  /// Now Playing over the library, from its player bar: closing it comes
  /// back here.
  Future<void> showNowPlaying() async {
    await commands.execute('showNowPlaying', const {});
  }

  /// A cover's bytes. Music Assistant's image proxy is often self-signed,
  /// Home Assistant's thumbnails need the token, a Sonos serves plain
  /// HTTP.
  Future<Uint8List?> loadArt(String url) => _art.load(url, _fetchArt);

  /// A cover already loaded, for drawing it in the first frame.
  Uint8List? cachedArt(String url) => _art.peek(url);

  /// One client for every cover, so a page of them reuses a few kept-alive
  /// connections instead of a TLS handshake each.
  late final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 20)
    ..maxConnectionsPerHost = 6
    ..badCertificateCallback = (cert, host, port) {
      final maHost =
          Uri.tryParse(
            musicAssistantWebUrl(_settings.get(defs.sendspinMaUrl)) ?? '',
          )?.host ??
          '';
      return CertificateLog.dart(
        'library artwork',
        host,
        cert,
        host.isNotEmpty && host == maHost
            ? 'it is the Music Assistant host'
            : null,
      );
    };

  Future<Uint8List?> _fetchArt(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return null;
    final haBase = Uri.tryParse(
      defs.normalizeBaseUrl(_settings.get(defs.haUrl)),
    );
    final toHa =
        haBase != null &&
        haBase.host.isNotEmpty &&
        uri.host == haBase.host &&
        uri.port == haBase.port &&
        uri.path.startsWith('/api/');
    try {
      return await () async {
        final request = await _http.getUrl(uri);
        if (toHa) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${_settings.get(defs.haToken).trim()}',
          );
        }
        final response = await request.close();
        if (response.statusCode != 200) {
          await response.drain<void>();
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final part in response) {
          bytes.add(part);
        }
        return bytes.takeBytes();
      }().timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    }
  }

  void _registerCommands() {
    commands
      ..register(
        Command(
          name: 'openMusicLibrary',
          description:
              'Open the Music Library on the kiosk: browse Music Assistant, '
              'a Home Assistant speaker or a Sonos household and play on a '
              'speaker.',
          handler: (_) async {
            if (available.isEmpty) {
              return const CommandResult.fail(
                'no music source is set up: Music Assistant, Home Assistant '
                'or a Sonos speaker',
              );
            }
            await open();
            return const CommandResult.ok();
          },
        ),
      )
      ..register(
        Command(
          name: 'musicLibraryVoiceRequest',
          description:
              'What the Kiosk Satellite music script asks for, answered in '
              'the shape the script hands back to the LLM.',
          params: const {
            'action':
                'play, show, now_playing, pause, resume, next, previous, '
                'volume, volume_up, volume_down, queue, clear_queue or '
                'speakers',
            'query': 'What to play or search for',
            'kind':
                'track, album, artist, playlist, radio, podcast or '
                'audiobook',
            'artist': 'Whose, when the user says',
            'mode': 'replace, next, add or radio',
            'speaker': 'A speaker the user names',
            'level': 'Volume, 0 to 100',
          },
          // The voice requests manager logs each one with its outcome.
          quiet: true,
          handler: (p) async => CommandResult.ok(await requests.handle(p)),
        ),
      )
      ..register(
        Command(
          name: 'hideMusicLibrary',
          description: 'Close the Music Library.',
          handler: (_) async {
            visible.value = false;
            return const CommandResult.ok();
          },
        ),
      );
  }
}
