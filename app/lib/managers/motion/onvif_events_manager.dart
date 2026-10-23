import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../home_assistant/home_assistant_manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'native_rtsp.dart';

/// Motion events for ONVIF clients (issue #1098), so an NVR such as UniFi
/// Protect can record on motion. The native ONVIF server publishes them as
/// a property over PullPoint subscriptions; this manager decides whether
/// they are on and whether there is motion, from one of three sources:
///
///  - `camera`: the Motion sensor, read the way its Home Assistant entity
///    reads it (on with each motion, clear after its Clear after delay).
///  - `person`: the device's person sensor.
///  - `entity`: a Home Assistant occupancy, motion or presence sensor,
///    watched over a subscription of this app's own.
///
/// A source whose sensor is off reads as no motion. Turning the sensor on
/// is left to the user: the settings pages say so under the picker.
class OnvifEventsManager extends Manager {
  OnvifEventsManager(
    super.bus,
    super.commands,
    super.log,
    this._settings,
    this._ha, {
    @visibleForTesting
    Future<void> Function({required bool enabled, required bool motion})? push,
  }) : _push = push ?? NativeRtsp.onvifEvents;

  final SettingsManager _settings;
  final HomeAssistantManager _ha;
  final Future<void> Function({required bool enabled, required bool motion})
  _push;

  @override
  String get name => 'onvif-events';

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// The camera source's state and the timer that clears it.
  bool _cameraMotion = false;
  Timer? _cameraOff;

  bool _personPresent = false;

  bool _entityMotion = false;
  GlanceSubscription? _live;
  String? _liveEntity;
  Timer? _retry;
  bool _opening = false;

  /// Bumped on every close, so a subscription that finishes connecting
  /// after its owner moved on closes itself instead of taking over.
  int _generation = 0;

  /// What the native side was last told, so only changes cross over.
  ({bool enabled, bool motion})? _sent;

  bool get enabled =>
      _settings.get(defs.cameraEnabled) &&
      _settings.get(defs.cameraRtspEnabled) &&
      _settings.get(defs.cameraStreamingProtocol) == 'onvif' &&
      _settings.get(defs.cameraOnvifEvents);

  String get source => _settings.get(defs.cameraOnvifEventsSource);

  bool get _cameraSensorOn =>
      _settings.get(defs.cameraEnabled) && _settings.get(defs.motionSensor);

  /// Whether ONVIF clients are told there is motion right now.
  bool get motion =>
      enabled &&
      switch (source) {
        'camera' => _cameraSensorOn && _cameraMotion,
        'person' => _settings.get(defs.personSensorEnabled) && _personPresent,
        'entity' => _entityMotion,
        _ => false,
      };

  /// The entity to watch, or empty while another source is picked.
  String get _entity => enabled && source == 'entity'
      ? _settings.get(defs.cameraOnvifEventsEntity).trim()
      : '';

  static const _keys = {
    'camera.enabled',
    'camera.rtsp.enabled',
    'camera.rtsp.protocol',
    'camera.onvif.events',
    'camera.onvif.events_source',
    'camera.onvif.events_entity',
    'motion.sensor',
    'person.sensor',
  };

  @override
  Future<void> init() async {
    _subscriptions
      ..add(
        bus.on<SettingChanged>().listen((e) {
          // Another server or token: the open socket is the old one's.
          if (e.key == defs.haUrl.key || e.key == defs.haToken.key) {
            _close();
            unawaited(_syncEntity());
          }
          if (!_keys.contains(e.key)) return;
          if (e.key == defs.motionSensor.key ||
              e.key == defs.cameraEnabled.key) {
            if (!_cameraSensorOn) _clearCamera();
          }
          unawaited(_syncEntity());
          _update();
        }),
      )
      ..add(
        bus.on<MotionDetected>().listen((_) {
          if (!_cameraSensorOn) return;
          _cameraMotion = true;
          _cameraOff?.cancel();
          final delay = _settings.get(defs.motionSensorOffDelay).toInt();
          _cameraOff = Timer(Duration(seconds: delay.clamp(1, 300)), () {
            _cameraMotion = false;
            _update();
          });
          _update();
        }),
      )
      ..add(
        bus.on<PersonSensorChanged>().listen((e) {
          _personPresent = e.present;
          _update();
        }),
      );

    commands.register(
      Command(
        name: 'getOnvifEvents',
        description:
            'Whether ONVIF clients get motion events, the source they come '
            'from and whether they report motion now',
        handler: (_) async => CommandResult.ok({
          'enabled': enabled,
          'source': source,
          'motion': motion,
        }),
      ),
    );

    final person = await commands.execute('getPersonSensor', const {});
    if (person.ok && person.data is Map) {
      _personPresent = (person.data as Map)['present'] == true;
    }
    _update();
    // Not awaited: Home Assistant may take a while to answer.
    unawaited(_syncEntity());
  }

  void _update() {
    final next = (enabled: enabled, motion: motion);
    if (next == _sent) return;
    if (next.enabled != _sent?.enabled) {
      log.info(
        name,
        next.enabled ? 'motion events on, from $source' : 'motion events off',
      );
    } else if (next.enabled) {
      log.debug(name, next.motion ? 'motion' : 'clear');
    }
    _sent = next;
    unawaited(
      _push(enabled: next.enabled, motion: next.motion).catchError((Object e) {
        log.warn(name, 'could not reach the ONVIF server: $e');
      }),
    );
  }

  void _clearCamera() {
    _cameraOff?.cancel();
    _cameraOff = null;
    _cameraMotion = false;
  }

  /// Open the entity's subscription when the source wants it, close it
  /// when not.
  Future<void> _syncEntity() async {
    final entity = _entity;
    if (entity.isEmpty) {
      _close();
      return;
    }
    if (_liveEntity == entity) {
      final current = _live;
      if (current == null ? _opening : !current.isClosed) return;
    }
    await _open(entity);
  }

  Future<void> _open(String entity) async {
    _close();
    final generation = _generation;
    _liveEntity = entity;
    _opening = true;
    final live = await _ha.subscribeEntities([entity], _onState);
    if (generation != _generation) {
      await live?.close();
      return;
    }
    _opening = false;
    if (live == null) {
      // Home Assistant not set up yet, unreachable or restarting.
      _retryIn(const Duration(seconds: 20));
      return;
    }
    live.onClosed = () {
      if (_live != live) return;
      _live = null;
      // Nothing keeps the state current now: report no motion rather than
      // motion that may have ended.
      _entityMotion = false;
      _update();
      _retryIn(const Duration(seconds: 5));
    };
    _live = live;
    log.debug(name, 'watching $entity');
  }

  void _retryIn(Duration delay) {
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      _liveEntity = null;
      unawaited(_syncEntity());
    });
  }

  void _close() {
    _generation++;
    _opening = false;
    _retry?.cancel();
    _retry = null;
    final live = _live;
    _live = null;
    _liveEntity = null;
    if (live != null) unawaited(live.close());
    _entityMotion = false;
  }

  void _onState(String entityId, Map<String, Object?> state) =>
      applyEntityState(entityId, state['state']);

  /// One state from the subscription: only `on` is motion.
  @visibleForTesting
  void applyEntityState(String entityId, Object? state) {
    if (entityId != _entity) return;
    _entityMotion = state == 'on';
    _update();
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _cameraOff?.cancel();
    _retry?.cancel();
    final live = _live;
    _live = null;
    await live?.close();
  }
}
