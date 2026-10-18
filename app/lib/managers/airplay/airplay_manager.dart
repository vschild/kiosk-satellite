import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// The AirPlay 1 receiver: an iPhone, iPad or Mac plays to the device as
/// it would to any AirPlay speaker.
///
/// It is one of this device's players on the Media Player page, beside
/// the Sendspin player and the Local Media Session, and serves only while
/// it is the pick and its switch is on: like the Sendspin player, which
/// goes offline while another player is picked, so the two never play
/// over each other.
///
/// The protocol lives in Kotlin (airplay/, through AirPlayBridge): the
/// RTSP server, the decryption, the Apple Lossless decoder, the playout
/// clock and the mDNS announcement. This manager owns the policy (when it
/// serves, its name and its options) and relays the receiver's session
/// snapshots onto the bus as [AirPlaySessionChanged], which the Now
/// Playing surfaces follow through `AirPlayPlayer`.
class AirPlayManager extends Manager {
  AirPlayManager(super.bus, super.commands, super.log, this._settings);

  final SettingsManager _settings;

  static const channel = MethodChannel('kiosk_satellite/airplay');

  @override
  String get name => 'airplay';

  bool _serving = false;
  String _servedName = '';
  Map<String, Object?>? _session;

  /// The covers senders sent this app run, by album: the sender lists its
  /// Up Next without art and offers no cover but the playing one, so the
  /// queue panel draws a song's album cover from here once that album has
  /// played. The oldest go past [_albumCoverLimit].
  static final _albumCovers = <String, Uint8List>{};
  static const _albumCoverLimit = 30;

  /// Moves each time a cover joins [_albumCovers], so an open queue panel
  /// can draw it: the cover lands a moment after the song change that
  /// refreshed the panel.
  static final albumCoverAdded = ValueNotifier<int>(0);
  int _coverId = 0;

  static String _albumKey(String artist, String album) =>
      '${artist.trim().toLowerCase()}|${album.trim().toLowerCase()}';

  /// The queue panel's URL for an album's cover, null until one has come
  /// in. Stable per album, so the panel's disk cache keeps it right
  /// across restarts.
  static String? albumArtworkUrl(String artist, String album) {
    if (album.trim().isEmpty) return null;
    final key = _albumKey(artist, album);
    if (!_albumCovers.containsKey(key)) return null;
    return 'airplay:album/${Uri.encodeComponent(key)}';
  }

  /// The live session, or null with no sender connected.
  Map<String, Object?>? get session => _session;

  @override
  Future<void> init() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'snapshot') _onSnapshot(call.arguments);
    });
    bus.on<SettingChanged>().listen((e) {
      if (const {
        'airplay.enabled',
        'airplay.name',
        'device.name',
        'sendspin.player',
        'sendspin.player_source',
      }.contains(e.key)) {
        unawaited(_sync());
      }
      if (const {
            'airplay.sender_volume',
            'airplay.sync_offset_ms',
            'airplay.takeover',
          }.contains(e.key) &&
          _serving) {
        unawaited(_invoke('configure', _options()));
      }
    });
    // A network that came back may carry a new address to announce.
    bus.on<NetworkStateChanged>().listen((e) {
      if (e.up && _serving) unawaited(_invoke('nudge'));
    });
    commands.register(
      Command(
        name: 'airplayStatus',
        description:
            'The AirPlay receiver: whether it is on, the name it announces, '
            'the session playing to it and how its playout keeps time.',
        quiet: true,
        handler: (_) async {
          Object? stats;
          if (_session != null) {
            try {
              stats = await channel.invokeMethod('stats');
            } catch (_) {}
          }
          return CommandResult.ok({
            'enabled': _settings.get(defs.airplayEnabled),
            'picked': _picked,
            'serving': _serving,
            'name': _servedName,
            'session': _session,
            // How the playout keeps time: the sync error, the buffer,
            // and the silence, drops and stuffing it took.
            'stats': ?stats,
          });
        },
      ),
    );
    // For working out what a sender's remote control takes: one raw
    // request to the connected sender, answered with its status and body.
    commands.register(
      Command(
        name: 'airplayRemote',
        description:
            'Diagnostics: send one request to the connected AirPlay '
            "sender's remote control (DACP), such as "
            'ctrl-int/1/nextitem, and answer with its HTTP status and body '
            'as hex.',
        params: const {
          'path': 'the request path after the port',
          'headers': 'extra request headers, an object of names to values',
        },
        handler: (p) async {
          final path = '${p['path'] ?? ''}'.trim();
          if (path.isEmpty) return const CommandResult.fail('no path');
          final headers = p['headers'];
          final answer = await channel.invokeMethod('remote', {
            'path': path,
            if (headers is Map)
              'headers': {
                for (final e in headers.entries) '${e.key}': '${e.value}',
              },
          });
          return answer == null
              ? const CommandResult.fail('no sender remote control')
              : CommandResult.ok(answer);
        },
      ),
    );
    await _sync();
  }

  /// Whether the receiver is the Media Player page's pick.
  bool get _picked =>
      _settings.get(defs.sendspinPlayerSource).isEmpty &&
      _settings.get(defs.sendspinPlayer) == 'airplay';

  Map<String, Object?> _options() => {
    'senderVolume': _settings.get(defs.airplaySenderVolume),
    'offsetMs': _settings.get(defs.airplaySyncOffset).toInt(),
    'takeover': _settings.get(defs.airplayTakeover),
  };

  Future<void> _sync() async {
    final want = _picked && _settings.get(defs.airplayEnabled);
    final own = _settings.get(defs.airplayName).trim();
    final name = own.isNotEmpty ? own : _settings.get(defs.deviceName).trim();
    if (want) {
      if (_serving && name == _servedName) return;
      _serving = true;
      _servedName = name;
      log.info(this.name, 'receiver on as "$name"');
      await _invoke('start', {'name': name, ..._options()});
    } else if (_serving) {
      _serving = false;
      log.info(this.name, 'receiver off');
      await _invoke('stop');
      _onSnapshot(null);
    }
  }

  void _onSnapshot(Object? raw) {
    final session = raw is Map
        ? <String, Object?>{for (final e in raw.entries) '${e.key}': e.value}
        : null;
    _keepAlbumCover(session);
    final started = _session == null && session != null;
    final ended = _session != null && session == null;
    _session = session;
    if (started) log.info(name, 'session from ${session['client']}');
    if (ended) log.info(name, 'session ended');
    bus.publish(AirPlaySessionChanged(session));
  }

  /// A new cover the sender stamped as the shown track's goes in the album
  /// cache.
  void _keepAlbumCover(Map<String, Object?>? session) {
    final id = (session?['artworkId'] as num?)?.toInt() ?? 0;
    if (session == null || id == 0 || id == _coverId) return;
    if (session['artworkMatchesTrack'] != true) return;
    final album = '${session['album'] ?? ''}';
    if (album.trim().isEmpty) return;
    _coverId = id;
    final key = _albumKey('${session['artist'] ?? ''}', album);
    unawaited(
      artwork().then((bytes) {
        if (bytes == null || bytes.isEmpty) return;
        _albumCovers.remove(key);
        _albumCovers[key] = bytes;
        while (_albumCovers.length > _albumCoverLimit) {
          _albumCovers.remove(_albumCovers.keys.first);
        }
        albumCoverAdded.value++;
      }),
    );
  }

  /// The cover an `airplay:` URL names: an album's from the cache, else
  /// the playing one.
  static Future<Uint8List?> artworkFor(String url) async {
    const album = 'airplay:album/';
    if (url.startsWith(album)) {
      return _albumCovers[Uri.decodeComponent(url.substring(album.length))];
    }
    return artwork();
  }

  /// A transport command to the sender's remote control: play, pause,
  /// toggle, next, previous or stop. False when the sender has none.
  static Future<bool> control(String command) async {
    try {
      return await channel.invokeMethod<bool>('control', {
            'command': command,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Jump to [positionMs] in the track through the sender's remote control,
  /// which not every sender honors. False when the sender has none.
  static Future<bool> seek(int positionMs) async {
    try {
      return await channel.invokeMethod<bool>('seek', {
            'positionMs': positionMs,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The sender's Up Next, the songs after the current one: title,
  /// artist, album, durationMs and the sender's number for each. Null
  /// when it cannot say.
  static Future<List<Map<String, Object?>>?> queue() async {
    try {
      final items = await channel.invokeMethod<List<Object?>>('queue');
      return items
          ?.whereType<Map>()
          .map((m) => {for (final e in m.entries) '${e.key}': e.value})
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Play the Up Next song the sender numbered [number].
  static Future<bool> playQueue(int number) =>
      _send('playQueue', {'number': number});

  /// Shuffle on or off through the sender's remote control.
  static Future<bool> setShuffle(bool on) => _send('shuffle', {'on': on});

  /// Repeat off, one or all through the sender's remote control.
  static Future<bool> setRepeat(String mode) => _send('repeat', {'mode': mode});

  static Future<bool> _send(String method, Map<String, Object?> args) async {
    try {
      return await channel.invokeMethod<bool>(method, args) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The music under a voice interaction, 1.0 for none.
  static Future<void> duck(double factor) async {
    try {
      await channel.invokeMethod('duck', {'factor': factor});
    } catch (_) {}
  }

  /// The current cover, or null for none.
  static Future<Uint8List?> artwork() async {
    try {
      return await channel.invokeMethod<Uint8List>('artwork');
    } catch (_) {
      return null;
    }
  }

  /// The session as the receiver holds it now.
  static Future<Map<Object?, Object?>?> snapshot() async {
    try {
      return await channel.invokeMethod<Map<Object?, Object?>>('snapshot');
    } catch (_) {
      return null;
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await channel.invokeMethod(method, args);
    } on MissingPluginException {
      // Tests and platforms without the receiver.
    } catch (e) {
      log.warn(name, '$method failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    if (_serving) await _invoke('stop');
    _serving = false;
  }
}
