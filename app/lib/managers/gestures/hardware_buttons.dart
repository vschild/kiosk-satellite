import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/event_bus.dart';
import '../../core/events.dart';
import '../../core/headless.dart';
import '../../core/logging.dart';
import '../alarms/alarm_manager.dart';
import '../intercom/intercom_manager.dart';
import '../sendspin/sendspin_manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import '../voice/voice_manager.dart';
import '../voice_timers/voice_timer_manager.dart';
import 'gesture_mappings.dart';

/// The hardware buttons of a device without a screen (HardwareKeys.kt).
///
/// Button gestures (`button` triggers) fire their mappings like any other
/// gesture. Two buttons also have a job of their own for any press no
/// gesture claims, so a speaker works the moment it is set up:
///  - Action: answers a ringing intercom call, stops a ringing alarm,
///    dismisses a ringing timer or the voice turn, ends an intercom call,
///    and otherwise starts a voice command.
///  - Microphone: mutes and unmutes Voice Satellite.
/// Volume buttons keep moving the media volume for any press no gesture
/// claims; HardwareKeys.kt does that on its own. On a ROM that lets the
/// kiosk claim them (Headless.volumeClaim), they steer the followed player
/// or the Music Assistant group instead while Volume buttons control the
/// player wants them (issue #1032).
///
/// Voice Satellite's mute and the system microphone mute are kept as one:
/// on the Echo Dot's LineageOS build the microphone button never reaches
/// an app, the framework mutes the microphone itself, and following that
/// mute is what makes the button work. The other way round, a mute from
/// Home Assistant or the remote admin mutes the microphone there too,
/// which that ROM shows on the light ring.
class HardwareButtons {
  HardwareButtons({
    required this.bus,
    required this.commands,
    required this.log,
    required this.settings,
    required this.alarms,
    required this.intercom,
    required this.voice,
    required this.voiceTimers,
    required this.sendspin,
  });

  final EventBus bus;
  final CommandRegistry commands;
  final Logger log;
  final SettingsManager settings;
  final AlarmManager alarms;
  final IntercomManager intercom;
  final VoiceManager voice;
  final VoiceTimerManager voiceTimers;
  final SendspinManager sendspin;

  static const _channel = MethodChannel('kiosk_satellite/hardware_keys');
  static const _name = 'buttons';

  StreamSubscription<SettingChanged>? _sub;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is! Map) return null;
      if (call.method == 'volumeKey') {
        final direction = '${args['direction']}';
        if (direction == 'up' || direction == 'down') {
          bus.publish(VolumeKeyPressed(direction: direction));
        }
      } else if (call.method == 'micMute') {
        await _onMicMute(args['muted'] == true);
      } else if (call.method == 'press') {
        final code = (args['keyCode'] as num?)?.toInt();
        final press = '${args['press']}';
        if (code != null) await _onPress(code, press);
      }
      return null;
    });
    commands.register(
      Command(
        name: 'getHardwareButtons',
        description:
            'Whether the hardware button service of a device without a '
            'screen is switched on (adb enables it)',
        quiet: true,
        handler: (_) async => CommandResult.ok(await status()),
      ),
    );
    _sub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.gestureMappings.key) unawaited(_configure());
      if (e.key == defs.voiceMute.key) unawaited(_pushMicMute());
      _syncVolumeButtons();
    });
    sendspin.nowPlaying.addListener(_syncVolumeButtons);
    _syncVolumeButtons();
    await _configure();
    // The setting is the state across a reboot, which clears the system
    // mute.
    await _pushMicMute();
  }

  Future<void> _pushMicMute() async {
    try {
      await _channel.invokeMethod('setMicMuted', {
        'muted': settings.get(defs.voiceMute),
      });
    } catch (e) {
      log.warn(_name, 'could not set the microphone mute: $e');
    }
  }

  /// The system microphone mute moved: the button on a ROM that takes it,
  /// or another app.
  Future<void> _onMicMute(bool muted) async {
    if (settings.get(defs.voiceMute) == muted) return;
    log.info(_name, 'microphone ${muted ? 'muted' : 'unmuted'} by the device');
    await commands.execute('setWakeWordMuted', {'muted': muted});
  }

  Future<void> dispose() async {
    sendspin.nowPlaying.removeListener(_syncVolumeButtons);
    await _sub?.cancel();
  }

  /// Claim the volume buttons from the ROM while they should steer the
  /// player, the way the kiosk screen routes them on a device with one.
  /// Nothing is ever on screen here, so only the playing mode counts.
  /// Diffed: the player reports often.
  bool? _lastVolumeButtons;
  void _syncVolumeButtons() {
    if (!Headless.volumeClaim) return;
    final wanted = sendspin.volumeKeysWanted(viewShown: false);
    if (wanted == _lastVolumeButtons) return;
    _lastVolumeButtons = wanted;
    log.info(
      _name,
      wanted
          ? 'volume buttons steer the player'
          : 'volume buttons change the device volume',
    );
    unawaited(
      _channel.invokeMethod('claimVolumeButtons', wanted).catchError((
        Object e,
      ) {
        log.warn(_name, 'could not claim the volume buttons: $e');
      }),
    );
  }

  /// Whether the button service is switched on (adb, see HeadlessKeyService).
  /// Whether the button service runs, and whether it is switched on in
  /// Android's settings: on but not running needs a reboot on Android 7.
  static Future<Map<String, bool>> status() async {
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      return {
        'listening': status?['listening'] == true,
        'switchedOn': status?['switchedOn'] == true,
      };
    } catch (_) {
      return {'listening': false, 'switchedOn': false};
    }
  }

  /// Tell the native side which keys to take and which presses to report:
  /// the mapped ones, plus a single press of the two buttons with a job of
  /// their own.
  Future<void> _configure() async {
    final keys = <int, Set<String>>{
      for (final code in buttonDefaults) code: {'single'},
    };
    for (final m in _mappings()) {
      final code = buttonKeyCode(m.trigger);
      if (code == null) continue;
      keys.putIfAbsent(code, () => {}).add(buttonPress(m.trigger));
    }
    try {
      await _channel.invokeMethod('configure', {
        'keys': {for (final e in keys.entries) '${e.key}': e.value.toList()},
      });
    } catch (e) {
      log.warn(_name, 'could not configure the buttons: $e');
    }
  }

  List<GestureMapping> _mappings() => decodeGestureMappings(
    settings.get(defs.gestureMappings),
  ).where((m) => m.triggerType == 'button').toList();

  Future<void> _onPress(int code, String press) async {
    var mapped = false;
    for (final m in _mappings()) {
      if (buttonKeyCode(m.trigger) == code && buttonPress(m.trigger) == press) {
        mapped = true;
        bus.publish(GestureDetected(id: m.id));
      }
    }
    if (mapped || press != 'single') return;
    switch (code) {
      case buttonAction:
        await _action();
      case buttonMicrophone:
        final muted = !settings.get(defs.voiceMute);
        log.info(_name, 'microphone button: ${muted ? 'muted' : 'unmuted'}');
        await commands.execute('setWakeWordMuted', {'muted': muted});
    }
  }

  /// What the Action button means right now, most urgent first.
  Future<void> _action() async {
    final state = intercom.state;
    if (state == 'ringing') {
      log.info(_name, 'action button: answering the intercom call');
      await commands.execute('intercomAnswer', const {});
      return;
    }
    final phase = alarms.status.value.phase;
    if (phase == AlarmPhase.ringing || phase == AlarmPhase.sunrise) {
      log.info(_name, 'action button: stopping the alarm');
      await alarms.stop(source: 'button');
      return;
    }
    if (voiceTimers.alerts.value.isNotEmpty || voice.busy) {
      log.info(_name, 'action button: dismissing the voice turn or timer');
      voice.dismiss();
      return;
    }
    if (const {
      'calling',
      'in_call',
      'broadcasting',
      'listening',
    }.contains(state)) {
      log.info(_name, 'action button: ending the intercom call');
      bus.publish(const IntercomHangupRequested());
      return;
    }
    if (!voice.enabled) return;
    log.info(_name, 'action button: starting a voice command');
    await commands.execute('voiceWake', const {});
  }
}
