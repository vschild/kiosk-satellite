import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Turn screen off at night after (issue #1060): the Clock screensaver's
/// Night mode takes the screen dark once the room has been dark for the
/// slider's minutes, and only the darkness it caused comes back when the
/// room brightens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late ScreensaverManager saver;
  late List<String> power;
  late bool panelOn;
  late bool adminGranted;
  double? lux;
  Completer<void>? slowPowerOff;

  const delay = Duration(minutes: 1);

  Future<void> build([Map<String, Object> extra = const {}]) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.enabled': true,
      'ks.screensaver.mode': 'clock',
      'ks.screensaver.clock_night': true,
      'ks.screensaver.clock_night_lux': 5,
      'ks.screensaver.clock_night_turn_off_minutes': 1,
      ...extra,
    });
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    power = [];
    panelOn = true;
    adminGranted = true;
    slowPowerOff = null;
    commands
      ..register(
        Command(
          name: 'getBrightness',
          description: 'Read brightness',
          handler: (_) async => const CommandResult.ok(0.8),
        ),
      )
      ..register(
        Command(
          name: 'setBrightness',
          description: 'Set brightness',
          handler: (_) async => const CommandResult.ok(),
        ),
      )
      ..register(
        Command(
          name: 'isScreenOn',
          description: 'Read the panel',
          handler: (_) async => CommandResult.ok(panelOn),
        ),
      )
      ..register(
        Command(
          name: 'screenOff',
          description: 'Power the panel off',
          handler: (p) async {
            power.add(p['prompt'] == false ? 'off quietly' : 'off');
            if (!adminGranted) return const CommandResult.fail('no admin');
            await slowPowerOff?.future;
            panelOn = false;
            bus.publish(const ScreenStateChanged(on: false, source: 'app'));
            return const CommandResult.ok();
          },
        ),
      )
      ..register(
        Command(
          name: 'screenOn',
          description: 'Wake the panel',
          handler: (_) async {
            power.add('on');
            if (!panelOn) {
              panelOn = true;
              bus.publish(const ScreenStateChanged(on: true, source: 'app'));
            }
            return const CommandResult.ok();
          },
        ),
      );
    saver = ScreensaverManager(
      bus,
      commands,
      log,
      settings,
      lightReading: () => lux,
    );
    await saver.init();
  }

  void room(FakeAsync async, double reading) {
    lux = reading;
    bus.publish(LightLevelChanged(lux: reading));
    async.flushMicrotasks();
  }

  void session(FakeAsync async) {
    saver.start();
    async.flushMicrotasks();
  }

  void finish(FakeAsync async) {
    saver.dispose();
    async.flushMicrotasks();
  }

  setUp(() => lux = 2);

  test('a dark room powers the panel off after the set time, quietly', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      session(async);
      async.elapse(delay - const Duration(seconds: 1));
      expect(power, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(power, ['off quietly']);
      expect(panelOn, isFalse);
      expect(saver.isActive, isTrue, reason: 'the session stays up');
      expect(saver.activeView.value, 'clock');
      finish(async);
    });
  });

  test('the brightening room lights the clock again, past the band', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      session(async);
      async.elapse(delay);
      room(async, 6);
      expect(panelOn, isFalse, reason: '6 lx is inside the band above 5');
      room(async, 7);
      expect(panelOn, isTrue);
      expect(saver.isActive, isTrue);
      expect(saver.activeView.value, 'clock');
      room(async, 2);
      async.elapse(delay);
      expect(panelOn, isFalse, reason: 'the next dark spell turns it off');
      finish(async);
    });
  });

  test('a panel turned off by other hands stays off in daylight', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      room(async, 50);
      session(async);
      panelOn = false;
      bus.publish(const ScreenStateChanged(on: false));
      async.flushMicrotasks();
      room(async, 2);
      room(async, 50);
      expect(power, isEmpty);
      finish(async);
    });
  });

  test('the black screen blanks instead and needs no admin grant', () {
    fakeAsync((async) {
      build({'ks.screensaver.clock_night_turn_off_black': true});
      async.flushMicrotasks();
      adminGranted = false;
      session(async);
      async.elapse(delay);
      expect(power, isEmpty);
      expect(saver.activeView.value, 'blank');
      room(async, 20);
      expect(saver.activeView.value, 'clock');
      expect(saver.isActive, isTrue);
      finish(async);
    });
  });

  test('a refused power-off is not retried until a setting changes', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      adminGranted = false;
      session(async);
      async.elapse(delay * 4);
      room(async, 1);
      async.elapse(delay * 2);
      expect(power, ['off quietly'], reason: 'one refusal, no loop');
      adminGranted = true;
      settings.set(defs.screensaverClockNightLux, 6);
      async.flushMicrotasks();
      async.elapse(delay);
      expect(power, ['off quietly', 'off quietly']);
      expect(panelOn, isFalse);
      finish(async);
    });
  });

  test('a wake that keeps the clock starts the countdown over', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      session(async);
      async.elapse(delay);
      commands.execute('screenOn', const {});
      async.flushMicrotasks();
      expect(panelOn, isTrue);
      async.elapse(delay - const Duration(seconds: 1));
      expect(panelOn, isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(panelOn, isFalse);
      finish(async);
    });
  });

  test('a moved slider counts its new time from the move', () {
    fakeAsync((async) {
      build({'ks.screensaver.clock_night_turn_off_minutes': 5});
      async.flushMicrotasks();
      session(async);
      async.elapse(const Duration(minutes: 4));
      expect(power, isEmpty);
      settings.set(defs.screensaverClockNightTurnOffMinutes, 2);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1, seconds: 59));
      expect(power, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(power, ['off quietly']);
      finish(async);
    });
  });

  test('a ringing alarm keeps the screen on until it lets go', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      session(async);
      commands.execute('alarmTakeover', const {'phase': 'ringing'});
      async.flushMicrotasks();
      async.elapse(delay * 3);
      expect(power, isEmpty);
      commands.execute('alarmTakeover', const {'phase': null});
      async.flushMicrotasks();
      async.elapse(delay);
      expect(power, ['off quietly']);
      finish(async);
    });
  });

  test('the slider at 0 lights the panel it turned off', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      session(async);
      async.elapse(delay);
      settings.set(defs.screensaverClockNightTurnOffMinutes, 0);
      async.flushMicrotasks();
      expect(panelOn, isTrue);
      async.elapse(delay * 2);
      expect(panelOn, isTrue);
      finish(async);
    });
  });

  test('a dismissal during the power-off leaves the dashboard lit', () {
    fakeAsync((async) {
      build();
      async.flushMicrotasks();
      slowPowerOff = Completer<void>();
      session(async);
      async.elapse(delay);
      expect(power, ['off quietly']);
      saver.stop();
      async.flushMicrotasks();
      slowPowerOff!.complete();
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
      expect(panelOn, isTrue);
      finish(async);
    });
  });

  for (final (why, extra, reading) in [
    (
      'the slider at 0',
      {'ks.screensaver.clock_night_turn_off_minutes': 0},
      2.0,
    ),
    ('Night mode off', {'ks.screensaver.clock_night': false}, 2.0),
    ('another screensaver', {'ks.screensaver.mode': 'black'}, 2.0),
    ('a lit room', <String, Object>{}, 40.0),
  ]) {
    test('nothing turns off with $why', () {
      fakeAsync((async) {
        lux = reading;
        build(extra);
        async.flushMicrotasks();
        session(async);
        async.elapse(delay * 3);
        expect(power, isEmpty);
        finish(async);
      });
    });
  }

  test('without a light sensor nothing turns off', () {
    fakeAsync((async) {
      lux = null;
      build();
      async.flushMicrotasks();
      session(async);
      async.elapse(delay * 3);
      expect(power, isEmpty);
      finish(async);
    });
  });
}
