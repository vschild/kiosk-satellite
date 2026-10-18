import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../airplay/airplay_manager.dart';
import 'remote_player.dart';

/// The Now Playing surfaces following this device's AirPlay receiver, one
/// of its own players beside the Sendspin player and the Local Media
/// Session: an iPhone, iPad or Mac plays out of the device, and the
/// floating card and the full-screen view show its track while a sender
/// is connected.
///
/// The receiver's snapshots reach the manager over the bus
/// ([AirPlayManager] relays them) and come in here through [handle].
/// Transport goes back to the sender's remote control, which a sender
/// offers once the receiver has found it on the network. Until then, or
/// for a sender with none, the view shows no buttons rather than buttons
/// that do nothing. Volume is the device's own media volume, which the
/// manager handles as it does for the local player.
class AirPlayPlayer implements RemotePlayer {
  AirPlayPlayer({required this.onSnapshot});

  /// The `artworkUrl` scheme of the receiver's covers, which
  /// SendspinManager.loadArtwork reads from the receiver.
  static const artworkScheme = 'airplay:';

  final void Function(Map<String, Object?>? snapshot) onSnapshot;

  bool _stopped = false;
  Map<String, Object?>? _snapshot;

  /// The sender's name, for the Now Playing chip.
  String get clientName => '${_snapshot?['client'] ?? ''}';

  @override
  String get playerId => 'airplay';

  @override
  bool queueEmpty = false;

  /// The sender's Up Next, read through its remote control: only from a
  /// sender that answers the control's status (a Mac does, iOS refuses
  /// everything but play, pause, skip and volume).
  @override
  bool get hasQueue =>
      _snapshot?['remote'] == true && _snapshot?['remoteStatus'] == true;

  /// The playing song, then the sender's Up Next. A Mac lists the songs
  /// after the current one, which is all the panel shows of a queue.
  @override
  Future<RemoteQueue?> fetchQueue() async {
    final items = await AirPlayManager.queue();
    if (items == null) return null;
    final now = _snapshot;
    return RemoteQueue(
      items: [
        if (now != null && '${now['title'] ?? ''}'.isNotEmpty)
          {
            'index': 0,
            'id': 'current',
            'title': '${now['title']}',
            'artist': '${now['artist'] ?? ''}',
            'durationMs': ?(now['durationMs'] as num?)?.toInt(),
            'current': true,
            'played': false,
            'artworkUrl': ?AirPlayManager.albumArtworkUrl(
              '${now['artist'] ?? ''}',
              '${now['album'] ?? ''}',
            ),
          },
        for (final (i, item) in items.indexed)
          {
            'index': i + 1,
            'id': '${item['number'] ?? ''}',
            'title': '${item['title'] ?? ''}',
            'artist': '${item['artist'] ?? ''}',
            'durationMs': ?(item['durationMs'] as num?)?.toInt(),
            'current': false,
            'played': false,
            // The sender offers no cover but the playing one: an album
            // that has played this run lends its own.
            'artworkUrl': ?AirPlayManager.albumArtworkUrl(
              '${item['artist'] ?? ''}',
              '${item['album'] ?? ''}',
            ),
          },
      ],
      upNext: items.length,
    );
  }

  /// Jumps the sender to an Up Next song by the number it gave it.
  @override
  Future<bool> playQueueItem(String id) async {
    final number = int.tryParse(id);
    if (number == null) return false;
    return AirPlayManager.playQueue(number);
  }

  @override
  bool get hasGrouping => false;

  @override
  Future<RemoteGroup?> fetchGroup() async => null;

  @override
  Future<bool> setGrouped(String id, bool grouped) async => false;

  /// The sender reports where the track is, and the receiver plays it on
  /// the sender's clock.
  @override
  bool get lyricsSynced => true;

  @override
  bool get hasFavorites => false;

  @override
  Future<bool> setFavorite(bool on) async => false;

  /// Through the remote control, for a sender that offers them for what
  /// plays (the snapshot says so). The state comes back with the sender's
  /// own status, whichever side changed it.
  @override
  Future<bool> setShuffle(bool on) => AirPlayManager.setShuffle(on);

  @override
  Future<bool> setRepeat(String mode) => AirPlayManager.setRepeat(mode);

  /// Through the remote control's play position, iTunes' own property:
  /// the Mac's Music app takes it, other senders may ignore it.
  @override
  Future<bool> seek(int positionMs) => AirPlayManager.seek(positionMs);

  /// The device's media volume, set by the manager.
  @override
  Future<bool> setVolume(int percent) async => false;

  @override
  Future<bool> setMute(bool muted) async => false;

  /// The receiver starts with the pick, so a sender may already be there.
  @override
  void start() {
    unawaited(refresh());
  }

  @override
  Future<void> stop() async {
    _stopped = true;
  }

  @override
  void reveal() {
    unawaited(refresh());
  }

  @override
  Future<void> refresh() async {
    final raw = await AirPlayManager.snapshot();
    if (raw != null) handle(raw);
  }

  @override
  Future<bool> control(String command) => AirPlayManager.control(command);

  /// A receiver snapshot, null once the sender left.
  void handle(Object? raw) {
    if (_stopped) return;
    final snap = snapshotFrom(raw);
    _snapshot = raw is Map
        ? <String, Object?>{for (final e in raw.entries) '${e.key}': e.value}
        : null;
    queueEmpty = snap == null;
    onSnapshot(snap);
  }

  /// The receiver's snapshot in the shape every source publishes. A
  /// sender that names no track (an app playing sound without metadata)
  /// still shows, under the sender's name.
  @visibleForTesting
  static Map<String, Object?>? snapshotFrom(Object? raw) {
    if (raw is! Map) return null;
    String text(String key) => '${raw[key] ?? ''}'.trim();
    final client = text('client');
    var title = text('title');
    var artist = text('artist');
    if (title.isEmpty) {
      title = client.isEmpty ? 'AirPlay' : client;
      if (artist.isEmpty && client.isNotEmpty) artist = 'AirPlay';
    }
    final artworkId = (raw['artworkId'] as num?)?.toInt() ?? 0;
    final remote = raw['remote'] == true;
    // The controls beyond play, pause and skip, for a sender that answers
    // its remote control's status: iOS refuses them all.
    final rich = remote && raw['remoteStatus'] == true;
    final duration = (raw['durationMs'] as num?)?.toInt();
    return {
      'title': title,
      'artist': artist,
      'album': text('album'),
      'durationMs': ?duration,
      'positionMs': (raw['positionMs'] as num?)?.toInt() ?? 0,
      'receivedAt':
          (raw['receivedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      'artworkUrl': artworkId > 0 ? '${artworkScheme}art/$artworkId' : '',
      'playing': raw['playing'] == true,
      'shuffle': raw['shuffle'] == true,
      'repeat': switch (raw['repeat']) {
        'one' => 'one',
        'all' => 'all',
        _ => 'off',
      },
      // A list that never reads as empty, which the controls take as
      // "anything goes": with no remote control there is nothing to send
      // play or skip to.
      'supportedCommands': remote
          ? [
              'play',
              'pause',
              'next',
              'previous',
              'volume',
              // A bar to drag needs a track with a length.
              if (rich && duration != null) 'seek',
              // Only what the sender allows for what plays.
              if (rich && raw['shuffleOffered'] == true) 'shuffle',
              if (rich && raw['repeatOffered'] == true) 'repeat',
            ]
          : const ['volume'],
      if (duration == null) 'stream': true,
    };
  }
}
