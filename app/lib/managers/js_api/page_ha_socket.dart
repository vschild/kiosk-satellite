import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/logging.dart';
import '../home_assistant/ha_credential_commands.dart';

/// The managed Home Assistant connection for custom pages (see
/// docs/js-api.md, `kioskSatellite.ha`).
///
/// A page asks for a socket and gets one of its own: the app connects to
/// Home Assistant, signs in with the kiosk's token and from then on passes
/// frames through untouched in both directions. The page owns the message
/// ids, so `home-assistant-js-websocket` runs on it unchanged, and no token
/// ever reaches the page. A socket belongs to the document that opened it:
/// a navigation closes it, which makes Home Assistant drop every
/// subscription on it, so nothing is left to clean up.
///
/// Frames for the page are gathered and handed over once per [flushEvery],
/// since each delivery is a script run in the WebView and a busy
/// `subscribe_entities` sends many small frames.
class PageHaSockets {
  PageHaSockets({
    required this.baseUrl,
    required this.token,
    required this.allowed,
    required this.log,
    this.onOpen,
    WebSocketChannel Function(Uri uri)? channelFactory,
    this.flushEvery = const Duration(milliseconds: 16),
  }) : _channelFactory =
           channelFactory ??
           ((uri) => IOWebSocketChannel.connect(
             uri,
             pingInterval: const Duration(seconds: 20),
             connectTimeout: const Duration(seconds: 10),
           ));

  /// Home Assistant's origin and the kiosk's long-lived token, read on
  /// every connect so a changed address or token is picked up.
  final String Function() baseUrl;
  final String Function() token;

  /// Whether the page on screen may have a socket now: the setting is on
  /// and the page is a custom page.
  final Future<bool> Function() allowed;

  final Logger log;
  final Duration flushEvery;

  /// Told each time a page's socket signs in, for the usage counts.
  final void Function()? onOpen;
  final WebSocketChannel Function(Uri uri) _channelFactory;

  /// Runs script in the page: set by the bridge while a WebView is
  /// attached.
  void Function(String js)? run;

  /// The most sockets one document may hold open.
  static const maxPerPage = 4;

  /// The document whose sockets are open: an id the bridge script draws at
  /// document start.
  String? _doc;
  final _sockets = <String, _PageSocket>{};
  final _pending = <String, List<String>>{};
  Timer? _flush;

  @visibleForTesting
  int get openCount => _sockets.length;

  /// Open socket [sid] for document [doc]. Answers `{ok: true, haVersion}`
  /// once Home Assistant accepted the token, else `{ok: false, error}`
  /// with `not_allowed`, `not_configured`, `auth_invalid`, `unreachable`,
  /// `in_use` or `too_many`.
  Future<Map<String, Object?>> open(String doc, String sid) async {
    if (!await allowed()) return _error('not_allowed');
    // A new document took over: the old one's sockets go with it.
    if (doc != _doc) {
      closeAll('page_changed');
      _doc = doc;
    }
    if (_sockets.containsKey(sid)) return _error('in_use');
    if (_sockets.length >= maxPerPage) return _error('too_many');
    final base = baseUrl().trim().replaceFirst(RegExp(r'/+$'), '');
    final key = token().trim();
    if (base.isEmpty || key.isEmpty) return _error('not_configured');
    final ws = base
        .replaceFirst(RegExp('^https://'), 'wss://')
        .replaceFirst(RegExp('^http://'), 'ws://');
    final socket = _PageSocket(
      doc: doc,
      sid: sid,
      onFrame: _onFrame,
      onDone: _onDone,
    );
    _sockets[sid] = socket;
    try {
      final version = await socket.connect(
        _channelFactory(Uri.parse('$ws/api/websocket')),
        key,
      );
      // Closed while signing in: a navigation, or the page's own close.
      if (!identical(_sockets[sid], socket)) {
        socket.close();
        return _error('unreachable');
      }
      log.info('js_api', 'page socket $sid open (Home Assistant $version)');
      onOpen?.call();
      return {'ok': true, 'haVersion': version};
    } catch (e) {
      if (identical(_sockets[sid], socket)) _sockets.remove(sid);
      socket.close();
      final error = e is _AuthInvalid ? 'auth_invalid' : 'unreachable';
      log.warn('js_api', 'page socket $sid not opened: $error ($e)');
      return _error(error);
    }
  }

  /// Pass one frame from the page to Home Assistant. False when the socket
  /// is not open for [doc]. Credential commands never go through: the page
  /// hears Home Assistant's usual error for them instead.
  bool send(String doc, String sid, String frame) {
    if (doc != _doc) return false;
    final socket = _sockets[sid];
    if (socket == null || !socket.ready) return false;
    final allowed = _withoutCredentialCommands(socket, frame);
    if (allowed != null) socket.add(allowed);
    return true;
  }

  /// [frame] minus its credential commands, or null when nothing is left.
  /// Home Assistant also takes a list of commands in one frame, so each
  /// one is checked.
  String? _withoutCredentialCommands(_PageSocket socket, String frame) {
    // Every credential command has "auth" in its type, so most frames
    // never need decoding. A \u escape could spell it out of sight.
    if (!frame.contains('auth') && !frame.contains(r'\u')) return frame;
    Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return frame;
    }
    final commands = decoded is List ? decoded : [decoded];
    final kept = <Object?>[];
    for (final command in commands) {
      if (command is Map && isHaCredentialCommand(command['type'])) {
        log.warn(
          'js_api',
          'page socket ${socket.sid}: refused ${command['type']}',
        );
        _onFrame(socket, jsonEncode(haCredentialRefusal(command['id'])));
      } else {
        kept.add(command);
      }
    }
    if (kept.length == commands.length) return frame;
    if (kept.isEmpty) return null;
    return jsonEncode(decoded is List ? kept : kept.single);
  }

  /// The page closed socket [sid] itself. Nothing is reported back.
  void close(String doc, String sid) {
    if (doc != _doc) return;
    _pending.remove(sid);
    _sockets.remove(sid)?.close();
  }

  /// Close every socket. With [notify] the page hears it, so a document
  /// that opened one before the navigation that closed it opens it again.
  void closeAll(String reason, {bool notify = false}) {
    if (_sockets.isEmpty) return;
    log.info('js_api', 'closing ${_sockets.length} page socket(s): $reason');
    final closing = _sockets.values.toList();
    _sockets.clear();
    _pending.clear();
    for (final socket in closing) {
      socket.close();
      if (notify) _deliverClosed(socket.doc, socket.sid, reason);
    }
  }

  void dispose() {
    _flush?.cancel();
    _flush = null;
    closeAll('disposed');
    run = null;
  }

  void _onFrame(_PageSocket socket, String frame) {
    if (!identical(_sockets[socket.sid], socket)) return;
    (_pending[socket.sid] ??= []).add(frame);
    _flush ??= Timer(flushEvery, _deliver);
  }

  void _onDone(_PageSocket socket, String reason) {
    if (!identical(_sockets[socket.sid], socket)) return;
    _sockets.remove(socket.sid);
    log.info('js_api', 'page socket ${socket.sid} closed: $reason');
    // Frames that arrived before the close still go first.
    _deliver();
    _deliverClosed(socket.doc, socket.sid, reason);
  }

  void _deliver() {
    _flush?.cancel();
    _flush = null;
    final doc = _doc;
    if (_pending.isEmpty || doc == null) return;
    final batch = Map.of(_pending);
    _pending.clear();
    run?.call(
      'window.__ksHaSocket && window.__ksHaSocket.receive('
      '${jsonEncode(doc)}, ${jsonEncode(batch)});',
    );
  }

  void _deliverClosed(String doc, String sid, String reason) {
    run?.call(
      'window.__ksHaSocket && window.__ksHaSocket.closed('
      '${jsonEncode(doc)}, ${jsonEncode(sid)}, ${jsonEncode(reason)});',
    );
  }

  static Map<String, Object?> _error(String code) => {
    'ok': false,
    'error': code,
  };
}

class _AuthInvalid implements Exception {
  const _AuthInvalid(this.message);

  final String message;

  @override
  String toString() => 'auth_invalid: $message';
}

/// One page socket: Home Assistant's auth handshake, then raw frames.
class _PageSocket {
  _PageSocket({
    required this.doc,
    required this.sid,
    required this.onFrame,
    required this.onDone,
  });

  final String doc;
  final String sid;
  final void Function(_PageSocket socket, String frame) onFrame;
  final void Function(_PageSocket socket, String reason) onDone;

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _sub;
  bool ready = false;
  bool _closed = false;

  /// Connect and sign in with [token]. Completes with Home Assistant's
  /// version once it says auth_ok.
  Future<String> connect(WebSocketChannel channel, String token) async {
    _channel = channel;
    final authed = Completer<String>();
    // A failed connect throws from channel.ready below; the stream's error
    // lands here too and must not count as unhandled.
    authed.future.ignore();
    _sub = channel.stream.listen(
      (raw) {
        if (raw is! String) return;
        if (ready) {
          onFrame(this, raw);
          return;
        }
        Map<String, Object?> msg;
        try {
          msg = (jsonDecode(raw) as Map).cast<String, Object?>();
        } catch (_) {
          return;
        }
        switch (msg['type']) {
          case 'auth_required':
            channel.sink.add(
              jsonEncode({'type': 'auth', 'access_token': token}),
            );
          case 'auth_ok':
            ready = true;
            if (!authed.isCompleted) authed.complete('${msg['ha_version']}');
          case 'auth_invalid':
            if (!authed.isCompleted) {
              authed.completeError(_AuthInvalid('${msg['message'] ?? ''}'));
            }
        }
      },
      onError: (Object e) {
        if (!authed.isCompleted) authed.completeError(e);
      },
      onDone: () {
        if (!authed.isCompleted) {
          authed.completeError(StateError('closed before auth'));
        }
        if (ready && !_closed) onDone(this, 'connection_lost');
        _closed = true;
        ready = false;
      },
      cancelOnError: true,
    );
    // A connect that fails otherwise surfaces as an uncaught error.
    await channel.ready;
    return authed.future.timeout(const Duration(seconds: 15));
  }

  void add(String frame) => _channel?.sink.add(frame);

  void close() {
    if (_closed) return;
    _closed = true;
    ready = false;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _channel = null;
  }
}
