import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/ui/clock_faces.dart';
import 'package:kiosk_satellite/ui/screensaver_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Hand Clock: a dial with hands, ticks and numbers at 12, 3, 6 and 9
/// or at every hour, a seconds hand that is on by default and a color pair
/// of its own. Night mode recolors it like the other faces.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppContainer> container(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues({
      'ks.ha.url': 'http://ha.local:8123',
      'ks.ha.token': 'token',
      'ks.screensaver.mode': 'clock',
      'ks.screensaver.clock_style': 'hand',
      ...prefs,
    });
    final c = AppContainer();
    await c.settings.init();
    return c;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Color faceBackground(WidgetTester tester) => tester
      .widget<ColoredBox>(
        find.byWidgetPredicate((w) => w is ColoredBox && w.child is Stack),
      )
      .color;

  test('the hands point where the time says', () {
    final a = handAngles(DateTime(2026, 10, 21, 15, 30, 45));
    expect(a.hour, closeTo(3.5 / 12, 1e-9));
    expect(a.minute, 0.5);
    expect(a.second, 0.75);
    // Noon and midnight both point at 12.
    expect(handAngles(DateTime(2026, 10, 21, 12)).hour, 0);
    expect(handAngles(DateTime(2026, 10, 21, 0)).hour, 0);
  });

  test('the hand clock rows show only with its style picked', () async {
    final c = await container({});
    expect(c.settings.get(defs.screensaverHandNumbers), 'quarters');
    expect(c.settings.get(defs.screensaverHandSeconds), true);
    for (final def in [
      defs.screensaverHandNumbers,
      defs.screensaverHandSeconds,
      defs.screensaverHandColor,
      defs.screensaverHandBgColor,
    ]) {
      expect(c.settings.visible(def), true, reason: def.key);
    }
    // The dial goes around once in 12 hours and has no date, digital
    // seconds or digits to stack.
    for (final def in [
      defs.screensaverClock24h,
      defs.screensaverClockAmPm,
      defs.screensaverClockSeconds,
      defs.screensaverClockDate,
      defs.screensaverClockVertical,
      defs.screensaverClockColor,
    ]) {
      expect(c.settings.visible(def), false, reason: def.key);
    }
    expect(c.settings.visible(defs.screensaverClockFont), true);
    expect(c.settings.visible(defs.screensaverClockScale), true);

    await c.settings.set(defs.screensaverClockStyle, 'digital');
    expect(c.settings.visible(defs.screensaverHandNumbers), false);
    expect(c.settings.visible(defs.screensaverClock24h), true);
  });

  testWidgets('the face draws with its own colors and settings', (
    tester,
  ) async {
    final c = await container({});
    await tester.pumpWidget(MaterialApp(home: ClockScreensaver(container: c)));
    var face = tester.widget<HandClockFace>(find.byType(HandClockFace));
    expect(face.allNumbers, false);
    expect(face.seconds, true);
    expect(face.color, const Color(0xFFFAFAFA));
    expect(faceBackground(tester), Colors.black);

    await c.settings.set(defs.screensaverHandNumbers, 'all');
    await c.settings.set(defs.screensaverHandSeconds, false);
    await c.settings.set(defs.screensaverHandColor, '0,128,0');
    await c.settings.set(defs.screensaverHandBgColor, '0,0,255');
    await settle(tester);
    face = tester.widget<HandClockFace>(find.byType(HandClockFace));
    expect(face.allNumbers, true);
    expect(face.seconds, false);
    expect(face.color, const Color(0xFF008000));
    expect(faceBackground(tester), const Color(0xFF0000FF));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Night mode takes the hands and the backdrop', (tester) async {
    final c = await container({
      'ks.screensaver.clock_night_color': '130,34,34',
      'ks.screensaver.clock_night_bg_color': '10,10,10',
    });
    await tester.pumpWidget(
      MaterialApp(home: ClockScreensaver(container: c, night: true)),
    );
    final face = tester.widget<HandClockFace>(find.byType(HandClockFace));
    expect(face.color, const Color(0xFF822222));
    expect(faceBackground(tester), const Color(0xFF0A0A0A));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the seconds hand ticks every second', (tester) async {
    final c = await container({});
    await tester.pumpWidget(MaterialApp(home: ClockScreensaver(container: c)));
    final before = tester.widget<HandClockFace>(find.byType(HandClockFace));
    await tester.pump(const Duration(milliseconds: 1001));
    final after = tester.widget<HandClockFace>(find.byType(HandClockFace));
    expect(identical(before, after), false);
    expect(after.now.isAfter(before.now), true);
    await tester.pumpWidget(const SizedBox());
  });
}
