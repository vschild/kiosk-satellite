import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'led_scene.dart';

/// The device's status lights, such as an Echo Dot's light ring (LedBridge
/// on the native side, which finds the lights and paints frames).
///
/// The lights show one thing at a time. Everything the app is doing is
/// gathered from the bus, the most urgent of it becomes a [LedScene], and
/// [renderLedFrame] turns that into frames for however many lights the
/// device has: an alarm or timer ringing first, then an incoming call, a
/// voice turn, a live call, the microphone muted, a notification waiting,
/// a timer counting down, music playing and, last, the idle look. Each feature has its own group
/// on the LED Control page, with a switch, a brightness and colors that
/// default to the ones an Echo device uses.
///
/// A device without lights gets none of this: the page is hidden and
/// nothing runs.
class LedManager extends Manager {
  LedManager(
    super.bus,
    super.commands,
    super.log,
    this._settings,
    this._localPlaying,
    this._dlnaState,
  );

  final SettingsManager _settings;
  final ValueListenable<bool> _localPlaying;
  final ValueListenable<String> _dlnaState;

  static const _channel = MethodChannel('kiosk_satellite/leds');
  static const _frameInterval = Duration(milliseconds: 50);

  /// How long a changed group setting shows on the lights.
  static const _previewFor = Duration(seconds: 4);

  /// What the device's own volume display takes over the lights for, after
  /// which the scene is painted again.
  static const _volumeOverlay = Duration(milliseconds: 1500);

  @override
  String get name => 'leds';

  /// The lights, as LedBridge describes them, or null without any.
  Map<String, Object?>? _device;
  int _pixels = 0;

  /// Off, every effect holds its still pose ([ledStillPose]) and the lights
  /// change only with the scene: for lights that flicker on every frame,
  /// such as an Echo Dot's on its current LineageOS build.
  bool get _animates => _settings.get(defs.ledAnimations);

  bool get available => _device != null;

  String _voiceState = 'idle';
  String _intercomState = 'idle';
  String _alarmPhase = 'idle';
  int _notifications = 0;
  bool _timerRinging = false;

  /// When the next running timer ends and how long it was set for.
  DateTime? _timerEndsAt;
  int _timerTotal = 0;

  LedScene? _scene;
  DateTime _sceneStarted = DateTime.now();
  LedScene? _preview;
  Timer? _previewTimer;
  Timer? _ticker;
  Timer? _repaint;
  DateTime? _overlayUntil;
  List<int>? _lastFrame;
  final _subs = <StreamSubscription<Object?>>[];

  @override
  Future<void> init() async {
    try {
      _device = await _channel.invokeMapMethod<String, Object?>('describe');
    } catch (_) {
      _device = null;
    }
    if (_device == null) {
      // No lights: the LED Control page is left out of both UIs.
      for (final def in defs.ledSettings) {
        defs.deviceHiddenKeys.add(def.key);
      }
      return;
    }
    _pixels = (_device!['pixels'] as num?)?.toInt() ?? 0;
    log.info(name, 'driving ${_device!['name']} ($_pixels lights)');

    _subs
      ..add(
        bus.on<VoiceSatelliteStateChanged>().listen((e) {
          _voiceState = e.state;
          _update();
        }),
      )
      ..add(bus.on<VoiceTimersChanged>().listen((e) => _onTimers(e.timers)))
      ..add(
        bus.on<AlarmStateChanged>().listen((e) {
          _alarmPhase = '${e.status['phase'] ?? 'idle'}';
          _update();
        }),
      )
      ..add(
        bus.on<IntercomStateChanged>().listen((e) {
          _intercomState = '${e.status['state'] ?? 'idle'}';
          _update();
        }),
      )
      ..add(
        bus.on<NotificationsChanged>().listen((e) {
          _notifications = e.count;
          _update();
        }),
      )
      ..add(bus.on<SettingChanged>().listen(_onSetting))
      ..add(bus.on<VolumeChanged>().listen((_) => _afterVolumeOverlay()));
    _localPlaying.addListener(_update);
    _dlnaState.addListener(_update);

    commands.register(
      Command(
        name: 'ledStatus',
        description:
            'The device status lights: what they are and the scene they show',
        quiet: true,
        handler: (_) async =>
            CommandResult.ok({'device': _device, 'scene': _scene?.name}),
      ),
    );
    _update();
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _localPlaying.removeListener(_update);
    _dlnaState.removeListener(_update);
    _ticker?.cancel();
    _previewTimer?.cancel();
    _repaint?.cancel();
  }

  void _onTimers(List<Map<String, Object?>> timers) {
    _timerRinging = timers.any((t) => t['finished'] == true);
    DateTime? soonest;
    var total = 0;
    for (final t in timers) {
      if (t['is_active'] != true) continue;
      final ends = DateTime.tryParse('${t['ends_at'] ?? ''}');
      if (ends == null) continue;
      if (soonest == null || ends.isBefore(soonest)) {
        soonest = ends;
        total = (t['total_seconds'] as num?)?.toInt() ?? 0;
      }
    }
    _timerEndsAt = soonest;
    _timerTotal = total;
    _update();
  }

  void _onSetting(SettingChanged e) {
    if (e.key == defs.voiceMute.key || e.key == defs.voiceEnabled.key) {
      _update();
      return;
    }
    if (e.key == defs.ledAnimations.key) {
      _scene = null;
      _update();
      return;
    }
    if (!e.key.startsWith('led.')) return;
    // A color, brightness or effect just picked shows for a moment, so it
    // can be judged on the lights themselves.
    final group = e.key.split('.')[1];
    final preview = _settings.get(defs.ledEnabled)
        ? _groupPreview(group)
        : null;
    _previewTimer?.cancel();
    _preview = preview;
    if (preview != null) {
      _previewTimer = Timer(_previewFor, () {
        _preview = null;
        _update();
      });
    }
    _update();
  }

  /// The device draws its own volume level over the lights, and leaves
  /// them dark after. Stand back while it shows, so an animation does not
  /// paint over it, then paint the scene again, even a frame the lights
  /// last showed before it. Each further press starts the wait over.
  void _afterVolumeOverlay() {
    _overlayUntil = DateTime.now().add(_volumeOverlay);
    _repaint?.cancel();
    _repaint = Timer(_volumeOverlay, () {
      _overlayUntil = null;
      _lastFrame = null;
      _paint(force: true);
    });
  }

  double _brightness(defs.SettingDef<num> def) =>
      (_settings.get(def).toDouble() / 100).clamp(0.0, 1.0);

  Rgb _color(defs.SettingDef<String> def) =>
      parseRgb(_settings.get(def), fallback: parseRgb(def.defaultValue));

  /// What the lights should show now, most urgent first.
  LedScene? _compute() {
    final s = _settings;
    if (!s.get(defs.ledEnabled)) return null;
    final voiceOn = s.get(defs.ledVoiceEnabled);
    LedScene voice(LedEffect effect, String name) => LedScene(
      name: name,
      effect: effect,
      color: _color(defs.ledVoiceLightColor),
      accent: _color(defs.ledVoiceAccentColor),
      brightness: _brightness(defs.ledVoiceBrightness),
    );

    if (s.get(defs.ledAlarmsEnabled) && _alarmPhase == 'ringing') {
      return LedScene(
        name: 'alarm',
        effect: LedEffect.pulse,
        color: _color(defs.ledAlarmsLightColor),
        brightness: _brightness(defs.ledAlarmsBrightness),
      );
    }
    if (s.get(defs.ledTimersEnabled) && _timerRinging) {
      return LedScene(
        name: 'timer_ringing',
        effect: LedEffect.pulse,
        color: _color(defs.ledTimersLightColor),
        brightness: _brightness(defs.ledTimersBrightness),
      );
    }
    final intercomOn = s.get(defs.ledIntercomEnabled);
    LedScene intercom(LedEffect effect, String name) => LedScene(
      name: name,
      effect: effect,
      color: _color(defs.ledIntercomLightColor),
      accent: _color(defs.ledIntercomLightColor),
      brightness: _brightness(defs.ledIntercomBrightness),
    );
    if (intercomOn && _intercomState == 'ringing') {
      return intercom(LedEffect.pulse, 'intercom_ringing');
    }
    if (voiceOn) {
      switch (_voiceState) {
        case 'listening':
          return voice(LedEffect.orbit, 'voice_listening');
        case 'processing':
          return voice(LedEffect.chase, 'voice_thinking');
        case 'responding':
          return voice(LedEffect.blend, 'voice_answering');
      }
    }
    if (intercomOn &&
        const {
          'calling',
          'in_call',
          'broadcasting',
          'listening',
        }.contains(_intercomState)) {
      return intercom(LedEffect.spin, 'intercom_call');
    }
    if (voiceOn &&
        s.get(defs.ledVoiceMuted) &&
        s.get(defs.voiceEnabled) &&
        s.get(defs.voiceMute)) {
      return LedScene(
        name: 'voice_muted',
        effect: LedEffect.solid,
        color: _color(defs.ledVoiceMutedColor),
        brightness: _brightness(defs.ledVoiceBrightness),
      );
    }
    if (s.get(defs.ledNotificationsEnabled) && _notifications > 0) {
      return LedScene(
        name: 'notification',
        effect: LedEffect.breathe,
        color: _color(defs.ledNotificationsLightColor),
        brightness: _brightness(defs.ledNotificationsBrightness),
      );
    }
    final ends = _timerEndsAt;
    if (s.get(defs.ledTimersEnabled) &&
        s.get(defs.ledTimersCountdown) &&
        ends != null &&
        _timerTotal > 0) {
      final left = ends.difference(DateTime.now()).inMilliseconds / 1000;
      if (left > 0) {
        return LedScene(
          name: 'timer_countdown',
          effect: LedEffect.countdown,
          color: _color(defs.ledTimersLightColor),
          brightness: _brightness(defs.ledTimersBrightness),
          // Whole steps per light, so the frame changes only when a light
          // goes out rather than every second.
          fraction: (left / _timerTotal * _pixels).ceil() / _pixels,
        );
      }
    }
    if (s.get(defs.ledMediaEnabled) &&
        (_localPlaying.value || _dlnaState.value == 'PLAYING')) {
      return LedScene(
        name: 'media',
        effect: s.get(defs.ledMediaStyle) == 'solid'
            ? LedEffect.solid
            : LedEffect.breathe,
        color: _color(defs.ledMediaLightColor),
        brightness: _brightness(defs.ledMediaBrightness),
      );
    }
    if (s.get(defs.ledIdleEnabled)) {
      return LedScene(
        name: 'idle',
        effect: s.get(defs.ledIdleStyle) == 'breathe'
            ? LedEffect.breathe
            : LedEffect.solid,
        color: _color(defs.ledIdleLightColor),
        brightness: _brightness(defs.ledIdleBrightness),
      );
    }
    return null;
  }

  /// The group's main look, for the preview after one of its settings
  /// changes; null when the group is switched off.
  LedScene? _groupPreview(String group) {
    final s = _settings;
    LedScene scene(
      String name,
      LedEffect effect,
      defs.SettingDef<String> color,
      defs.SettingDef<num> brightness, {
      defs.SettingDef<String>? accent,
    }) => LedScene(
      name: 'preview_$name',
      effect: effect,
      color: _color(color),
      accent: accent == null ? null : _color(accent),
      brightness: _brightness(brightness),
    );
    switch (group) {
      case 'idle':
        // The idle look is what the lights fall back to anyway.
        return null;
      case 'voice':
        if (!s.get(defs.ledVoiceEnabled)) return null;
        return scene(
          'voice',
          LedEffect.chase,
          defs.ledVoiceLightColor,
          defs.ledVoiceBrightness,
          accent: defs.ledVoiceAccentColor,
        );
      case 'timers':
        if (!s.get(defs.ledTimersEnabled)) return null;
        return scene(
          'timers',
          LedEffect.pulse,
          defs.ledTimersLightColor,
          defs.ledTimersBrightness,
        );
      case 'alarms':
        if (!s.get(defs.ledAlarmsEnabled)) return null;
        return scene(
          'alarms',
          LedEffect.pulse,
          defs.ledAlarmsLightColor,
          defs.ledAlarmsBrightness,
        );
      case 'intercom':
        if (!s.get(defs.ledIntercomEnabled)) return null;
        return scene(
          'intercom',
          LedEffect.spin,
          defs.ledIntercomLightColor,
          defs.ledIntercomBrightness,
          accent: defs.ledIntercomLightColor,
        );
      case 'notifications':
        if (!s.get(defs.ledNotificationsEnabled)) return null;
        return scene(
          'notifications',
          LedEffect.breathe,
          defs.ledNotificationsLightColor,
          defs.ledNotificationsBrightness,
        );
      case 'media':
        if (!s.get(defs.ledMediaEnabled)) return null;
        return scene(
          'media',
          s.get(defs.ledMediaStyle) == 'solid'
              ? LedEffect.solid
              : LedEffect.breathe,
          defs.ledMediaLightColor,
          defs.ledMediaBrightness,
        );
    }
    return null;
  }

  void _update() {
    if (!available) return;
    final next = _preview ?? _compute();
    if (next == _scene) return;
    // The same look staying on (a countdown losing a light) keeps its
    // clock, so an animation does not restart.
    if (next?.name != _scene?.name) {
      _sceneStarted = DateTime.now();
      log.debug(name, 'showing ${next?.name ?? 'nothing'}');
    }
    _scene = next;
    _ticker?.cancel();
    _ticker = null;
    _paint();
    if (next == null) return;
    if (next.animated && _animates) {
      _ticker = Timer.periodic(_frameInterval, (_) => _paint());
    } else if (next.effect == LedEffect.countdown) {
      // The countdown moves on its own: look again every second.
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _update());
    }
  }

  void _paint({bool force = false}) {
    final until = _overlayUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    final scene = _scene;
    if (scene == null) {
      if (_lastFrame != null && _lastFrame!.isEmpty) return;
      _lastFrame = const [];
      unawaited(_send('clear', {'force': force}));
      return;
    }
    final frame = renderLedFrame(
      scene,
      pixels: _pixels,
      t: _animates
          ? DateTime.now().difference(_sceneStarted)
          : ledStillPose(scene.effect),
    );
    if (listEquals(frame, _lastFrame)) return;
    _lastFrame = frame;
    unawaited(_send('frame', {'colors': frame, 'force': force}));
  }

  Future<void> _send(String method, Map<String, Object?>? args) async {
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      log.warn(name, 'could not paint the lights: $e');
    }
  }
}
