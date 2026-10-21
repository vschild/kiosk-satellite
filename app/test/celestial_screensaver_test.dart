import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/app_locales.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/ui/celestial_controls.dart';
import 'package:kiosk_satellite/ui/celestial_renderer.dart';
import 'package:kiosk_satellite/ui/celestial_screensaver.dart';
import 'package:kiosk_satellite/ui/screensaver_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dismissal', () {
    // The sky owns its touches: a drag looks around, so the kiosk's raw
    // report of a finger must never close it. Only the view's own double
    // tap does.
    late ScreensaverManager saver;
    var now = DateTime(2026, 10, 20, 22);

    Future<void> build() async {
      SharedPreferences.setMockInitialValues({
        'ks.screensaver.mode': 'celestial',
      });
      final bus = EventBus();
      final log = Logger();
      final commands = CommandRegistry(log);
      final settings = SettingsManager(bus, commands, log);
      await settings.init();
      saver = ScreensaverManager(bus, commands, log, settings);
      now = DateTime(2026, 10, 20, 22);
      saver.clock = () => now;
      await saver.start();
      await pumpEventQueue();
      expect(saver.activeView.value, 'celestial');
    }

    test('a finger on the sky leaves it up', () async {
      await build();
      for (var i = 0; i < 2; i++) {
        saver.markControlTouch();
        now = now.add(const Duration(milliseconds: 10));
        saver.notifyActivity('touch');
        now = now.add(const Duration(milliseconds: 200));
      }
      await pumpEventQueue();
      expect(saver.activeView.value, 'celestial');
    });

    test('moving the device around does not close it', () async {
      await build();
      saver.holdSensorDismiss = true;
      for (final source in ['motion', 'face', 'person', 'proximity']) {
        saver.notifyActivity(source);
      }
      await pumpEventQueue();
      expect(saver.activeView.value, 'celestial');
      // The double tap still does, and stopping drops the hold.
      saver.notifyActivity('screensaver_touch');
      await pumpEventQueue();
      expect(saver.activeView.value, isNull);
      expect(saver.holdSensorDismiss, isFalse);
    });

    test('the double tap closes it', () async {
      await build();
      saver.notifyActivity('screensaver_touch');
      await pumpEventQueue();
      expect(saver.activeView.value, isNull);
    });
  });

  test('coordinates parse and validate', () {
    expect(defs.parseCoordinates('40.71, -74.01'), (
      latitude: 40.71,
      longitude: -74.01,
    ));
    expect(defs.parseCoordinates('-33.87 151.21'), (
      latitude: -33.87,
      longitude: 151.21,
    ));
    expect(defs.parseCoordinates('91, 0'), isNull);
    expect(defs.parseCoordinates('north'), isNull);
    expect(defs.validateCoordinates(''), isNull);
    expect(defs.validateCoordinates('1, 2, 3'), isNotNull);
  });

  test('the view round trips through its setting', () {
    const view = CelestialView(azimuth: 182.5, altitude: 21.25, fov: 64);
    expect(CelestialView.decode(view.encode()), view.copyWith(altitude: 21.3));
    expect(CelestialView.decode('nonsense'), isNull);
    final clamped = CelestialView.decode('400,120,5')!;
    expect(clamped.azimuth, 40);
    expect(clamped.altitude, CelestialView.maxAltitude);
    expect(clamped.fov, CelestialView.minFov);
  });

  Future<AppContainer> pumpSky(
    WidgetTester tester, {
    String source = 'manual',
    String coordinates = '40.71, -74.01',
  }) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.mode': 'celestial',
      'ks.screensaver.celestial_location': source,
      'ks.screensaver.celestial_coordinates': coordinates,
    });
    final c = AppContainer();
    await c.settings.init();
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: CelestialScreensaver(container: c),
      ),
    );
    await tester.pump();
    return c;
  }

  testWidgets('a drag turns the view and the kiosk remembers it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await pumpSky(tester);
    expect(find.byType(CelestialRenderer), findsOneWidget);
    final before = tester
        .widget<CelestialRenderer>(find.byType(CelestialRenderer))
        .view
        .value;
    await tester.drag(
      find.byType(CelestialRenderer),
      const Offset(-200, 0),
      touchSlopX: 0,
    );
    await tester.pump(const Duration(seconds: 1));
    final after = CelestialView.decode(
      c.settings.get(defs.screensaverCelestialView),
    );
    expect(after, isNotNull);
    // Dragging left looks further right, toward the west from the south.
    expect(after!.azimuth, greaterThan(before.azimuth + 5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a single tap shows how to close it', (tester) async {
    await pumpSky(tester);
    expect(find.text('Double tap to close'), findsOneWidget);
    final hint = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('Double tap to close'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(hint.opacity, 0);
    await tester.tap(find.byType(CelestialRenderer));
    // Past the double tap window, the lone tap counts.
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.text('Double tap to close'),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a touch brings up the controls for five seconds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await pumpSky(tester);
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byType(CelestialControls),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacity(), 0);
    expect(c.screensaver.modeControlsShown.value, isFalse);
    await tester.tap(find.byType(CelestialRenderer));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(), 1);
    // The widgets and At a Glance step aside meanwhile.
    expect(c.screensaver.modeControlsShown.value, isTrue);
    expect(find.text('40.71° N  74.01° W'), findsOneWidget);
    expect(find.text('Now'), findsNothing);
    // The timelapse button steps through its speeds, and Now brings the
    // sky back to the present.
    await tester.tap(find.byIcon(Icons.fast_forward_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('60×'), findsOneWidget);
    expect(
      tester.widget<CelestialRenderer>(find.byType(CelestialRenderer)).timeRate,
      60,
    );
    await tester.tap(find.text('Now'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('60×'), findsNothing);
    expect(find.text('Now'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(opacity(), 0);
    expect(c.screensaver.modeControlsShown.value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the controls size scales the bar', (tester) async {
    final c = await pumpSky(tester);
    await tester.tap(find.byType(CelestialRenderer));
    await tester.pump(const Duration(milliseconds: 400));
    double size() =>
        tester.widget<Text>(find.text('40.71° N  74.01° W')).style!.fontSize!;
    final normal = size();
    await c.settings.set(defs.screensaverCelestialControlScale, 200);
    await tester.pump(const Duration(milliseconds: 300));
    expect(size(), closeTo(normal * 2, 0.01));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('with every control off a touch brings nothing up', (
    tester,
  ) async {
    final c = await pumpSky(tester);
    for (final def in [
      defs.screensaverCelestialControlCoordinates,
      defs.screensaverCelestialControlAzimuth,
      defs.screensaverCelestialControlAltitude,
      defs.screensaverCelestialControlFov,
      defs.screensaverCelestialControlTime,
      defs.screensaverCelestialControlTimelapse,
      defs.screensaverCelestialControlPointAtSky,
      defs.screensaverCelestialControlMoonPhase,
    ]) {
      await c.settings.set(def, false);
    }
    await tester.tap(find.byType(CelestialRenderer));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.screensaver.modeControlsShown.value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('widgets step aside while the controls are up', (tester) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.mode': 'celestial',
      'ks.screensaver.celestial_location': 'manual',
      'ks.screensaver.celestial_coordinates': '40.71, -74.01',
      'ks.screensaver.widgets':
          '[{"type":"clock","position":"top_left","config":{}}]',
    });
    final c = AppContainer();
    await c.settings.init();
    c.screensaver.activeView.value = 'celestial';
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Stack(children: [ScreensaverOverlay(container: c)]),
        ),
      ),
    );
    await tester.pump();
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byType(ClockWidgetOverlay),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;
    expect(find.byType(ClockWidgetOverlay), findsOneWidget);
    expect(opacity(), 1);
    c.screensaver.modeControlsShown.value = true;
    await tester.pump();
    expect(opacity(), 0);
    c.screensaver.modeControlsShown.value = false;
    await tester.pump();
    expect(opacity(), 1);
    c.screensaver.activeView.value = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  test('the sky clock runs fast, keeps its place and returns to now', () {
    var real = DateTime(2026, 10, 20, 22);
    final clock = CelestialClock(() => real);
    expect(clock.shifted, isFalse);
    clock.nextRate();
    expect(clock.rate, 60);
    real = real.add(const Duration(seconds: 10));
    expect(clock.now(), DateTime(2026, 10, 20, 22, 10));
    clock
      ..nextRate()
      ..nextRate()
      ..nextRate();
    // Back at real speed, the sky stays ten minutes ahead.
    expect(clock.rate, 1);
    real = real.add(const Duration(seconds: 10));
    expect(clock.now(), DateTime(2026, 10, 20, 22, 10, 10));
    expect(clock.shifted, isTrue);
    clock.reset();
    expect(clock.now(), real);
    expect(clock.shifted, isFalse);
  });

  test('the Moon phase follows its age', () {
    // A full Moon on 2026-10-26 and a new one on 2026-11-09.
    expect(celestialMoonPhase(DateTime.utc(2026, 10, 26, 4)), 4);
    expect(celestialMoonPhase(DateTime.utc(2026, 11, 9, 8)), 0);
  });

  testWidgets('a source without a position says why on black', (tester) async {
    // Home Assistant is not set up, so the home zone has no position.
    await pumpSky(tester, source: 'ha_home', coordinates: '');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(
      find.text(
        'Choose a location in Settings > Screensaver > Celestial.\n'
        'Home Assistant is not connected.',
      ),
      findsOneWidget,
    );
    expect(find.byType(CelestialRenderer), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  group('a GPS without a fix yet', () {
    Future<AppContainer> pumpGps(WidgetTester tester, String last) async {
      SharedPreferences.setMockInitialValues({
        'ks.screensaver.mode': 'celestial',
        'ks.screensaver.celestial_location': 'gps',
        'ks.screensaver.celestial_last_gps': last,
      });
      final c = AppContainer();
      await c.settings.init();
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: CelestialScreensaver(container: c),
        ),
      );
      await tester.pump();
      return c;
    }

    testWidgets('starts the sky at the last fix right away', (tester) async {
      await pumpGps(tester, '-2.12, -79.87');
      final sky = tester.widget<CelestialRenderer>(
        find.byType(CelestialRenderer),
      );
      expect(sky.latitude, -2.12);
      expect(sky.longitude, -79.87);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('says it is waiting before the first fix ever', (tester) async {
      await pumpGps(tester, '');
      expect(find.text('Waiting for a GPS fix...'), findsOneWidget);
      expect(find.byType(CelestialRenderer), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('location sources', () {
    Future<AppContainer> container(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues({
        'ks.screensaver.mode': 'celestial',
        ...prefs,
      });
      final c = AppContainer();
      await c.settings.init();
      return c;
    }

    test('manual coordinates place the sky, or ask for them', () async {
      final c = await container({
        'ks.screensaver.celestial_location': 'manual',
        'ks.screensaver.celestial_coordinates': '-33.87, 151.21',
      });
      final status = await c.celestial.resolve();
      expect(status.available, isTrue);
      expect(status.latitude, -33.87);
      expect(status.longitude, 151.21);
      await c.settings.set(defs.screensaverCelestialCoordinates, '');
      expect(
        (await c.celestial.resolve()).message,
        'Enter a latitude and longitude, like 40.71, -74.01',
      );
    });

    test('an entity source without an entity asks for one', () async {
      final c = await container({
        'ks.screensaver.celestial_location': 'ha_entity',
      });
      expect(
        (await c.celestial.resolve()).message,
        'Pick an entity with a location.',
      );
    });

    test('the Home Assistant sources need Home Assistant', () async {
      final c = await container({
        'ks.screensaver.celestial_entity': 'person.someone',
      });
      for (final source in ['ha_home', 'ha_entity']) {
        expect(
          (await c.celestial.resolve(source)).message,
          'Home Assistant is not connected.',
        );
      }
    });

    test('the GPS falls back to its last fix and keeps new ones', () async {
      final c = await container({
        'ks.screensaver.celestial_last_gps': '10.5, 20.25',
      });
      final status = await c.celestial.resolve('gps');
      expect(status.available, isTrue);
      expect(status.latitude, 10.5);
      expect(status.longitude, 20.25);
      // A fix barely away is not written, one that moved is.
      c.celestial.remember(10.5001, 20.2501);
      expect(c.settings.get(defs.screensaverCelestialLastGps), '10.5, 20.25');
      c.celestial.remember(11, 21);
      await pumpEventQueue();
      expect(
        c.settings.get(defs.screensaverCelestialLastGps),
        '11.00000, 21.00000',
      );
    });

    test('the GPS without a receiver bridge has no fix yet', () async {
      final c = await container({});
      final status = await c.celestial.resolve('gps');
      expect(status.available, isFalse);
      expect(status.message, 'No GPS fix yet.');
    });

    test('the command answers for any source', () async {
      final c = await container({
        'ks.screensaver.celestial_coordinates': '10, 20',
      });
      await c.celestial.init();
      final result = await c.commands.execute('getCelestialLocation', {
        'source': 'manual',
      });
      expect(result.data, {
        'source': 'manual',
        'available': true,
        'latitude': 10.0,
        'longitude': 20.0,
      });
    });
  });
}
