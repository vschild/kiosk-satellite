import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_widgets.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/ui/screensaver_view.dart';
import 'package:kiosk_satellite/ui/weather_mood_information.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Show AM/PM (issue #1038): a 12-hour clock can drop the period. The
/// Clock screensaver, the Weather Mood clock and the Clock widget each
/// carry their own switch, on by default.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppContainer> container(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues({
      'ks.ha.url': 'http://ha.local:8123',
      'ks.ha.token': 'token',
      ...prefs,
    });
    final c = AppContainer();
    await c.settings.init();
    return c;
  }

  Finder period() => find.byWidgetPredicate(
    (w) =>
        w is Text &&
        (w.data?.endsWith(' AM') == true || w.data?.endsWith(' PM') == true),
  );

  test('the switches only show for a 12-hour clock', () {
    expect(defs.screensaverClockAmPm.defaultValue, isTrue);
    expect(defs.screensaverClockAmPm.dependsOn, defs.screensaverClock24h.key);
    expect(defs.screensaverClockAmPm.dependsOnValue, isFalse);
    // Only the digital face draws a period.
    expect(
      defs.screensaverClockAmPm.alsoDependsOn,
      defs.screensaverClockStyle.key,
    );
    expect(defs.screensaverClockAmPm.subpage, defs.screensaverClock24h.subpage);
    expect(defs.screensaverWeatherClockAmPm.defaultValue, isTrue);
    expect(
      defs.screensaverWeatherClockAmPm.dependsOn,
      defs.screensaverWeatherClock24h.key,
    );
    expect(defs.screensaverWeatherClockAmPm.dependsOnValue, isFalse);
    expect(screensaverWidgetDefaults('clock')['ampm'], isTrue);
  });

  testWidgets('the Clock screensaver drops the period live', (tester) async {
    final c = await container({
      'ks.screensaver.mode': 'clock',
      'ks.screensaver.clock_show_date': false,
    });
    await tester.pumpWidget(MaterialApp(home: ClockScreensaver(container: c)));
    expect(period(), findsOneWidget);
    await c.settings.set(defs.screensaverClockAmPm, false);
    await tester.pump();
    await tester.pump();
    expect(period(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Weather Mood clock follows its own switch', (tester) async {
    final c = await container({
      'ks.screensaver.mode': 'weather_mood',
      'ks.screensaver.weather_clock_show_date': false,
      'ks.screensaver.weather_bar': false,
    });
    final readings = WeatherMoodReadings()..update({'state': 'sunny'});
    Future<void> show() async {
      await tester.pumpWidget(
        MaterialApp(
          home: WeatherMoodInformation(container: c, readings: readings),
        ),
      );
      await tester.pump();
    }

    await show();
    expect(period(), findsOneWidget);
    // The Clock screensaver's switch is not this one.
    await c.settings.set(defs.screensaverClockAmPm, false);
    await show();
    expect(period(), findsOneWidget);
    await c.settings.set(defs.screensaverWeatherClockAmPm, false);
    await show();
    expect(period(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Clock widget keeps the period unless switched off', (
    tester,
  ) async {
    final c = await container({'ks.screensaver.mode': 'local'});
    Future<void> show(Map<String, Object?> config) => tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            ClockWidgetOverlay(
              container: c,
              spec: ScreensaverWidget(
                position: 'top_left',
                type: 'clock',
                config: config,
              ),
            ),
          ],
        ),
      ),
    );

    // An entry saved before the switch existed has no key.
    await show({'h24': false});
    expect(period(), findsOneWidget);
    await show({'h24': false, 'ampm': false});
    expect(period(), findsNothing);
    await show({'h24': true, 'ampm': true});
    expect(period(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
