import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/celestial_renderer.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('Rubik')
      ..addFont(rootBundle.load('assets/fonts/Rubik.ttf'));
    await font.load();
  });

  // A timelapse or a device turning in the hand rebuilds the labels on
  // every frame, with new names coming and going all the time. The text
  // cache must never drop a label the frame being built still holds.
  testWidgets('labels survive the text cache filling up mid-frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(preloadCelestial);
    final view = ValueNotifier(
      const CelestialView(azimuth: 0, altitude: 30, fov: 30),
    );
    final ready = <bool>[];
    Widget sky(double latitude) => Directionality(
      textDirection: TextDirection.ltr,
      child: CelestialRenderer(
        latitude: latitude,
        longitude: -79.87,
        options: const CelestialOptions(daytime: false),
        names: const CelestialNames(
          language: 'en',
          bodies: {},
          deepSky: {},
          compass: ['N', 'E', 'S', 'W'],
        ),
        view: view,
        active: false,
        lowPower: false,
        clock: () => DateTime.utc(2026, 10, 21, 3),
        onReady: () => ready.add(true),
        onError: (e) => fail('$e'),
      ),
    );
    await tester.pumpWidget(sky(-2.12));
    for (var i = 0; i < 50 && ready.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(ready, isNotEmpty);
    // Sweep the whole sky zoomed in, so hundreds of different names pass
    // through the cache.
    for (final latitude in [-2.12, 60.0, -60.0]) {
      await tester.pumpWidget(sky(latitude));
      for (final fov in [15.0, 25.0, 45.0]) {
        for (var az = 0; az < 360; az += 4) {
          for (final alt in [0.0, 20.0, 40.0, 60.0, 80.0]) {
            view.value = CelestialView(
              azimuth: az.toDouble(),
              altitude: alt,
              fov: fov,
            );
            await tester.pump();
            final error = tester.takeException();
            if (error != null) fail('$error');
          }
        }
      }
    }
    expect(tester.takeException(), isNull);
  });
}
