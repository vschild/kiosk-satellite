import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late SettingsManager settings;
  late ScreensaverManager saver;
  late List<String> dreams;
  late List<double> brightness;
  late List<String?> dreamErrors;
  late List<String> screenCalls;
  late List<bool> saverActive;
  var dreamStart = const CommandResult.ok({
    'ok': true,
    'method': 'somnambulator',
  });

  Future<void> build(
    Map<String, Object> prefs, {
    CommandResult? startResult,
    Duration? screenOffUnit,
  }) async {
    dreamStart =
        startResult ??
        const CommandResult.ok({'ok': true, 'method': 'somnambulator'});
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.enabled': true,
      'ks.screensaver.timeout_seconds': 30,
      ...prefs,
    });
    bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    dreams = [];
    brightness = [];
    dreamErrors = [];
    screenCalls = [];
    saverActive = [];
    bus.on<SystemDreamChanged>().listen((event) {
      if (event.error != null) dreamErrors.add(event.error);
    });
    bus.on<ScreensaverStateChanged>().listen((event) {
      saverActive.add(event.active);
    });
    commands.register(
      Command(
        name: 'startSystemDream',
        description: 'Record a dream launch',
        handler: (_) async {
          dreams.add('start');
          return dreamStart;
        },
      ),
    );
    commands.register(
      Command(
        name: 'stopSystemDream',
        description: 'Record a dream wake',
        handler: (params) async {
          dreams.add('stop');
          bus.publish(
            SystemDreamChanged(
              active: false,
              error: params['error'] as String?,
            ),
          );
          return const CommandResult.ok();
        },
      ),
    );
    commands.register(
      Command(
        name: 'screenOff',
        description: 'Record a panel power-off and the dream ending with it',
        handler: (_) async {
          screenCalls.add('screenOff');
          bus.publish(const ScreenStateChanged(on: false, source: 'app'));
          bus.publish(const SystemDreamChanged(active: false));
          return const CommandResult.ok();
        },
      ),
    );
    commands.register(
      Command(
        name: 'screenOn',
        description: 'Record a panel wake',
        handler: (_) async {
          screenCalls.add('screenOn');
          bus.publish(const ScreenStateChanged(on: true, source: 'app'));
          return const CommandResult.ok();
        },
      ),
    );
    for (final name in [
      'keepScreenAwake',
      'isScreenOn',
      'unfreezeRendering',
      'leaveScreensaver',
    ]) {
      commands.register(
        Command(
          name: name,
          description: 'Session plumbing',
          handler: (_) async => const CommandResult.ok(),
        ),
      );
    }
    commands.register(
      Command(
        name: 'getBrightness',
        description: 'Read brightness',
        handler: (_) async => const CommandResult.ok(0.8),
      ),
    );
    commands.register(
      Command(
        name: 'setBrightness',
        description: 'Record brightness',
        handler: (params) async {
          brightness.add((params['level'] as num).toDouble());
          return const CommandResult.ok();
        },
      ),
    );
    saver = ScreensaverManager(
      bus,
      commands,
      log,
      settings,
      screenOffUnit: screenOffUnit ?? const Duration(minutes: 1),
    );
    await saver.init();
  }

  /// The dream has proved itself, so the screen-off countdown and the
  /// dismiss switches apply.
  void confirmDream(FakeAsync async) {
    bus.publish(const SystemDreamChanged(active: true));
    async.flushMicrotasks();
  }

  test('android mode launches the system dream and leaves the dashboard', () {
    fakeAsync((async) {
      build({'ks.screensaver.mode': 'android'});
      async.flushMicrotasks();
      dreams.clear();
      saver.start();
      async.flushMicrotasks();
      expect(dreams, ['start']);
      expect(saver.isActive, isFalse);
      expect(saver.activeView.value, isNull);
      expect(brightness, isEmpty);
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(dreams, ['start', 'stop']);
      expect(dreamErrors, ['did_not_start']);
      saver.dispose();
    });
  });

  test('a refused dream is reported and the idle clock runs again', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.mode': 'android',
        'ks.screensaver.timeout_seconds': 5,
      }, startResult: const CommandResult.fail('disabled'));
      async.flushMicrotasks();
      dreams.clear();
      dreamErrors.clear();
      saver.start();
      async.flushMicrotasks();
      expect(dreams, ['start']);
      expect(saver.isActive, isFalse);
      expect(saver.activeView.value, isNull);
      expect(dreamErrors, ['disabled']);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(dreams, ['start', 'start']);
      saver.dispose();
    });
  });

  test('clock mode never asks Android to dream', () {
    fakeAsync((async) {
      build({'ks.screensaver.mode': 'clock'});
      async.flushMicrotasks();
      dreams.clear();
      saver.start();
      async.flushMicrotasks();
      expect(dreams, isEmpty);
      expect(saver.isActive, isTrue);
      expect(saver.activeView.value, 'clock');
      expect(brightness, isEmpty);
      saver.dispose();
    });
  });

  test('Now Playing still uses this app when Android mode is selected', () {
    fakeAsync((async) {
      build({'ks.screensaver.mode': 'android', 'ks.sendspin.fullscreen': true});
      async.flushMicrotasks();
      dreams.clear();
      bus.publish(const SendspinNowPlayingChanged(active: true, playing: true));
      async.flushMicrotasks();
      expect(dreams, isEmpty);
      expect(saver.isActive, isTrue);
      expect(saver.activeView.value, isNotNull);
      saver.dispose();
    });
  });

  test('an alarm force-start keeps this app\'s screensaver', () {
    fakeAsync((async) {
      build({'ks.screensaver.mode': 'android'});
      async.flushMicrotasks();
      dreams.clear();
      saver.start(force: true);
      async.flushMicrotasks();
      expect(dreams, isEmpty);
      expect(saver.isActive, isTrue);
      saver.dispose();
    });
  });

  test('switching a running screensaver to Android hands it off', () {
    fakeAsync((async) {
      build({'ks.screensaver.mode': 'clock'});
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      expect(saver.activeView.value, 'clock');
      dreams.clear();
      settings.set(defs.screensaverMode, 'android');
      async.flushMicrotasks();
      expect(saver.isActive, isFalse);
      expect(saver.activeView.value, isNull);
      expect(dreams, ['start']);
      saver.dispose();
    });
  });

  test('confirmed dream powers the panel off, then motion starts it again', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.mode': 'android',
        'ks.screensaver.screen_off_minutes': 5,
        'ks.screensaver.dismiss_on_motion': true,
        'ks.screensaver.screen_off_wake_to_screensaver': '["motion"]',
      }, screenOffUnit: const Duration(milliseconds: 10));
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      confirmDream(async);
      expect(saverActive, [true]);
      expect(saver.isActive, isFalse);
      dreams.clear();
      async.elapse(const Duration(milliseconds: 50));
      async.flushMicrotasks();
      expect(screenCalls, ['screenOff']);
      expect(dreams, isEmpty);
      expect(saverActive, [true]);
      bus.publish(const MotionDetected());
      async.flushMicrotasks();
      expect(screenCalls, ['screenOff', 'screenOn']);
      expect(dreams, ['start']);
      expect(saverActive, [true]);
      saver.dispose();
    });
  });

  test('motion while the dream is up opens the dashboard', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.mode': 'android',
        'ks.screensaver.dismiss_on_motion': true,
      });
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      confirmDream(async);
      dreams.clear();
      bus.publish(const MotionDetected());
      async.flushMicrotasks();
      expect(dreams, ['stop']);
      expect(saverActive, [true, false]);
      saver.dispose();
    });
  });

  test(
    'only when screen is off leaves the dream up until the panel is dark',
    () {
      fakeAsync((async) {
        build({
          'ks.screensaver.mode': 'android',
          'ks.screensaver.screen_off_minutes': 5,
          'ks.screensaver.dismiss_on_motion': true,
          'ks.screensaver.dismiss_on_motion_screen_off_only': true,
          'ks.screensaver.screen_off_wake_to_screensaver': '["motion"]',
        }, screenOffUnit: const Duration(milliseconds: 10));
        async.flushMicrotasks();
        saver.start();
        async.flushMicrotasks();
        confirmDream(async);
        dreams.clear();
        bus.publish(const MotionDetected());
        async.flushMicrotasks();
        expect(dreams, isEmpty);
        expect(screenCalls, isEmpty);
        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        expect(screenCalls, ['screenOff']);
        bus.publish(const MotionDetected());
        async.flushMicrotasks();
        expect(screenCalls, ['screenOff', 'screenOn']);
        expect(dreams, ['start']);
        expect(saver.isActive, isFalse);
        saver.dispose();
      });
    },
  );

  test('a dark-panel wake that is not picked opens the dashboard', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.mode': 'android',
        'ks.screensaver.screen_off_minutes': 5,
        'ks.screensaver.dismiss_on_motion': true,
      }, screenOffUnit: const Duration(milliseconds: 10));
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      confirmDream(async);
      async.elapse(const Duration(milliseconds: 50));
      async.flushMicrotasks();
      expect(screenCalls, ['screenOff']);
      bus.publish(const MotionDetected());
      async.flushMicrotasks();
      expect(screenCalls, ['screenOff', 'screenOn']);
      expect(saverActive.last, isFalse);
      saver.dispose();
    });
  });

  test('black screen ends the dream and a picked wake starts it again', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.mode': 'android',
        'ks.screensaver.screen_off_minutes': 2,
        'ks.screensaver.screen_off_black': true,
        'ks.screensaver.dismiss_on_motion': true,
        'ks.screensaver.screen_off_wake_to_screensaver': '["motion"]',
      }, screenOffUnit: const Duration(milliseconds: 10));
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      confirmDream(async);
      dreams.clear();
      brightness.clear();
      async.elapse(const Duration(milliseconds: 20));
      async.flushMicrotasks();
      expect(screenCalls, isEmpty);
      expect(dreams, ['stop']);
      expect(saver.activeView.value, 'blank');
      expect(brightness, [0]);
      expect(saverActive, [true]);
      bus.publish(const MotionDetected());
      async.flushMicrotasks();
      expect(saver.activeView.value, isNull);
      expect(brightness, [0, 0.8]);
      expect(dreams, ['stop', 'start']);
      saver.dispose();
    });
  });

  test('a face after the panel is dark starts the dream again', () {
    fakeAsync((async) {
      build({
        'ks.screensaver.mode': 'android',
        'ks.screensaver.screen_off_minutes': 5,
        'ks.screensaver.dismiss_on_face': true,
        'ks.screensaver.screen_off_wake_to_screensaver': '["face"]',
      }, screenOffUnit: const Duration(milliseconds: 10));
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      confirmDream(async);
      async.elapse(const Duration(milliseconds: 50));
      async.flushMicrotasks();
      dreams.clear();
      bus.publish(const FaceDetected());
      async.flushMicrotasks();
      expect(dreams, ['start']);
      expect(screenCalls, ['screenOff', 'screenOn']);
      saver.dispose();
    });
  });

  test('coming back while the dream was up returns to the dashboard', () {
    fakeAsync((async) {
      build({'ks.screensaver.mode': 'android'});
      async.flushMicrotasks();
      saver.start();
      async.flushMicrotasks();
      confirmDream(async);
      dreams.clear();
      saver.didChangeAppLifecycleState(AppLifecycleState.paused);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      saver.didChangeAppLifecycleState(AppLifecycleState.resumed);
      async.elapse(const Duration(milliseconds: 800));
      async.flushMicrotasks();
      expect(dreams, ['stop']);
      expect(saverActive, [true, false]);
      saver.dispose();
    });
  });
}
