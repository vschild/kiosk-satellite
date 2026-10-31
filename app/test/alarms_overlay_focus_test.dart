import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/app_locales.dart';
import 'package:kiosk_satellite/ui/alarms_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// openAlarms with alarm next (ks://alarms/next) opens the alarm screen on
/// that alarm's details, and moves to it when the screen is already up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The list ticks with the clock, so it never settles for good.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Map<String, Object?> alarm(String id, String time, String label) => {
    'id': id,
    'time': time,
    'days': [0, 1, 2, 3, 4, 5, 6],
    'label': label,
    'speak': true,
    'on': true,
  };

  testWidgets('a focused alarm opens on its details', (tester) async {
    SharedPreferences.setMockInitialValues({
      'ks.alarms.list': jsonEncode([
        alarm('a', '07:00', 'Gym'),
        alarm('b', '09:00', 'Swim'),
      ]),
    });
    final container = AppContainer();
    // Real storage and timers: outside the test's fake clock.
    await tester.runAsync(() async {
      await container.settings.init();
      await container.alarms.init();
    });
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        home: Scaffold(
          body: Stack(children: [AlarmsOverlay(container: container)]),
        ),
      ),
    );

    container.alarms.focus.value = 'b';
    container.alarms.visible.value = true;
    await settle(tester);
    expect(container.alarms.focus.value, isNull);
    expect(find.text('Phrase'), findsOneWidget);
    expect(find.textContaining('Swim'), findsWidgets);
    expect(find.textContaining('Gym'), findsNothing);

    container.alarms.focus.value = 'a';
    await settle(tester);
    expect(container.alarms.focus.value, isNull);
    expect(find.text('Phrase'), findsOneWidget);
    expect(find.textContaining('Gym'), findsWidgets);
    expect(find.textContaining('Swim'), findsNothing);

    // An alarm that is gone leaves the screen where it is.
    container.alarms.focus.value = 'missing';
    await settle(tester);
    expect(find.textContaining('Gym'), findsWidgets);

    container.alarms.visible.value = false;
    await settle(tester);
    container.alarms.visible.value = true;
    await settle(tester);
    expect(find.text('Phrase'), findsNothing);
    expect(find.textContaining('Gym'), findsWidgets);
    expect(find.textContaining('Swim'), findsWidgets);
    await tester.runAsync(container.alarms.dispose);
  });
}
