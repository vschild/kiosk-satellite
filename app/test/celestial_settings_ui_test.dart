import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart';
import 'package:kiosk_satellite/ui/celestial_settings.dart';
import 'package:kiosk_satellite/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Each Celestial location source reveals its own row on the device, as on
/// the remote (settings.js, updateCelestialLocationRow): a status line for
/// the GPS and the home zone, the entity picker with a status line for an
/// entity, and the coordinates field for Manual.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppContainer> open(WidgetTester tester, String source) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.enabled': true,
      'ks.screensaver.mode': 'celestial',
      'ks.screensaver.celestial_location': source,
    });
    final container = AppContainer();
    await container.settings.init();
    tester.view.physicalSize = const Size(500, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(container: container)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    for (final title in ['Screensaver', 'Celestial screensaver']) {
      await tester.tap(find.text(title).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
    }
    return container;
  }

  testWidgets('the home zone shows its status under the select', (
    tester,
  ) async {
    await open(tester, 'ha_home');
    expect(find.text('Location'), findsOneWidget);
    expect(find.byType(CelestialLocationStatusRow), findsOneWidget);
    expect(find.text('Current location'), findsOneWidget);
    expect(find.text('Home Assistant is not connected.'), findsOneWidget);
    expect(find.byType(CelestialEntityRow), findsNothing);
    expect(find.text('Coordinates'), findsNothing);
  });

  testWidgets('the GPS lists the Location grant under the Location group', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('kiosk_satellite/location'),
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('kiosk_satellite/location'),
        null,
      ),
    );
    final c = await open(tester, 'gps');
    final heading = find.text('Required system permissions');
    expect(heading, findsOneWidget);
    // Right after the group holding the Location select, before Sky.
    expect(
      tester.getTopLeft(heading).dy,
      greaterThan(tester.getTopLeft(find.text('Point at the sky')).dy),
    );
    expect(
      tester.getTopLeft(heading).dy,
      lessThan(tester.getTopLeft(find.text('Sky')).dy),
    );
    // Another source has nothing to grant.
    await c.settings.set(screensaverCelestialLocation, 'ha_home');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(heading, findsNothing);
  });

  testWidgets('approximate location reads missing and says why', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    const location = MethodChannel('kiosk_satellite/location');
    const background = MethodChannel('kiosk_satellite/background');
    messenger.setMockMethodCallHandler(background, (call) async => false);
    // Android 12 and later: approximate allowed, precise refused.
    messenger.setMockMethodCallHandler(
      permissions,
      (call) async => switch (call.method) {
        'checkPermissionStatus' => 0,
        'checkServiceStatus' => 1,
        _ => null,
      },
    );
    messenger.setMockMethodCallHandler(
      location,
      (call) async => call.method == 'grants'
          ? {'precise': false, 'approximate': true}
          : null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(permissions, null);
      messenger.setMockMethodCallHandler(location, null);
      messenger.setMockMethodCallHandler(background, null);
    });
    await open(tester, 'gps');
    // The permission read goes through platform plugins that settle on
    // real time.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(
      find.text(
        'Only approximate location is allowed, and the GPS receiver needs '
        'precise location.',
      ),
      findsOneWidget,
    );
    expect(find.text('Grant'), findsOneWidget);
  });

  testWidgets('an entity source shows the picker and its status', (
    tester,
  ) async {
    await open(tester, 'ha_entity');
    expect(find.byType(CelestialEntityRow), findsOneWidget);
    expect(find.text('Pick an entity with a location.'), findsOneWidget);
  });

  testWidgets('Manual shows the coordinates field and no status', (
    tester,
  ) async {
    // A receiver with no fix to give.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('kiosk_satellite/location'),
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('kiosk_satellite/location'),
        null,
      ),
    );
    final c = await open(tester, 'manual');
    expect(find.text('Coordinates'), findsOneWidget);
    expect(find.byType(CelestialLocationStatusRow), findsNothing);
    // Point at the sky needs a compass, not a GPS.
    expect(find.text('Point at the sky'), findsOneWidget);
    // Switching the source swaps the rows in place.
    await c.settings.set(screensaverCelestialLocation, 'gps');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('Coordinates'), findsNothing);
    expect(find.text('No GPS fix yet.'), findsOneWidget);
    expect(find.text('Point at the sky'), findsOneWidget);
    // Opt in: a wall kiosk with a compass keeps its touch view.
    expect(c.settings.get(screensaverCelestialFollowDevice), isFalse);
  });
}
