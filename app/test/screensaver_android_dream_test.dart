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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late SettingsManager settings;
  late ScreensaverManager saver;
  late List<String> dreams;
  late List<double> brightness;
  late List<String?> dreamErrors;
  var dreamStart = const CommandResult.ok({
    'ok': true,
    'method': 'somnambulator',
  });

  Future<void> build(
    Map<String, Object> prefs, {
    CommandResult? startResult,
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
    bus.on<SystemDreamChanged>().listen((event) {
      if (event.error != null) dreamErrors.add(event.error);
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
    for (final name in [
      'keepScreenAwake',
      'isScreenOn',
      'screenOn',
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
    saver = ScreensaverManager(bus, commands, log, settings);
    await saver.init();
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
}
