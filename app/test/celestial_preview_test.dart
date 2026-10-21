import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/celestial_astronomy.dart';
import 'package:kiosk_satellite/ui/celestial_renderer.dart';

// Renders previews into CELESTIAL_PREVIEW_DIR when set. Development aid.
void main() {
  final dir = Platform.environment['CELESTIAL_PREVIEW_DIR'];
  setUpAll(() async {
    final font = FontLoader('Rubik')
      ..addFont(rootBundle.load('assets/fonts/Rubik.ttf'));
    await font.load();
  });

  final scenes =
      <
        (
          String,
          DateTime,
          double,
          double,
          CelestialView,
          Size,
          CelestialOptions,
        )
      >[
        (
          'night_south',
          DateTime.utc(2026, 10, 21, 3, 30),
          40.71,
          -74.01,
          const CelestialView(azimuth: 180, altitude: 20, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(),
        ),
        (
          'night_east_mountains',
          DateTime.utc(2026, 1, 15, 4, 0),
          40.71,
          -74.01,
          const CelestialView(azimuth: 100, altitude: 20, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(terrain: 'mountains'),
        ),
        (
          'milkyway_summer',
          DateTime.utc(2026, 7, 15, 7, 0),
          36.0,
          -112.0,
          const CelestialView(azimuth: 170, altitude: 25, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(),
        ),
        (
          'dusk_west',
          DateTime.utc(2026, 10, 20, 22, 50),
          40.71,
          -74.01,
          const CelestialView(azimuth: 240, altitude: 15, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(),
        ),
        (
          'day',
          DateTime.utc(2026, 10, 20, 17, 0),
          40.71,
          -74.01,
          const CelestialView(azimuth: 180, altitude: 20, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(),
        ),
        (
          'moon_zoom',
          DateTime.utc(2026, 10, 24, 1, 0),
          40.71,
          -74.01,
          const CelestialView(azimuth: 190, altitude: 25, fov: 30),
          const Size(1280, 800),
          const CelestialOptions(),
        ),
        (
          'echo5',
          DateTime.utc(2026, 10, 21, 3, 30),
          40.71,
          -74.01,
          const CelestialView(azimuth: 180, altitude: 16, fov: 100),
          const Size(960, 480),
          const CelestialOptions(terrain: 'plains'),
        ),
        (
          'city',
          DateTime.utc(2026, 7, 15, 7, 0),
          36.0,
          -112.0,
          const CelestialView(azimuth: 170, altitude: 25, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(lightPollution: 0.6),
        ),
        (
          'flat',
          DateTime.utc(2026, 7, 15, 7, 0),
          36.0,
          -112.0,
          const CelestialView(azimuth: 170, altitude: 25, fov: 100),
          const Size(1280, 800),
          const CelestialOptions(terrain: 'none'),
        ),
        (
          'phone',
          DateTime.utc(2026, 10, 21, 3, 30),
          -33.87,
          151.21,
          const CelestialView(azimuth: 0, altitude: 31, fov: 100),
          const Size(390, 844),
          const CelestialOptions(),
        ),
      ];

  for (final scene in scenes) {
    testWidgets('preview ${scene.$1}', (tester) async {
      if (dir == null) return;
      final (name, time, lat, lon, view0, size, options) = scene;
      var view = view0;
      if (name == 'moon_zoom') {
        final m = SkyEphemeris(time, lat, lon).moon.horizon;
        view = view.copyWith(azimuth: m.azimuth, altitude: m.altitude);
      }
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => preloadCelestial(terrain: options.terrain));
      final key = GlobalKey();
      final ready = <bool>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: CelestialRenderer(
              latitude: lat,
              longitude: lon,
              options: options,
              names: const CelestialNames(
                language: 'en',
                bodies: {
                  SkyBody.sun: 'Sun',
                  SkyBody.moon: 'Moon',
                  SkyBody.mercury: 'Mercury',
                  SkyBody.venus: 'Venus',
                  SkyBody.mars: 'Mars',
                  SkyBody.jupiter: 'Jupiter',
                  SkyBody.saturn: 'Saturn',
                  SkyBody.uranus: 'Uranus',
                  SkyBody.neptune: 'Neptune',
                },
                deepSky: {
                  'andromedaGalaxy': 'Andromeda Galaxy',
                  'orionNebula': 'Orion Nebula',
                  'pleiades': 'Pleiades',
                  'largeMagellanicCloud': 'Large Magellanic Cloud',
                  'smallMagellanicCloud': 'Small Magellanic Cloud',
                  'lagoonNebula': 'Lagoon Nebula',
                  'carinaNebula': 'Carina Nebula',
                  'triangulumGalaxy': 'Triangulum Galaxy',
                  'beehiveCluster': 'Beehive Cluster',
                  'doubleCluster': 'Double Cluster',
                  'omegaCentauri': 'Omega Centauri',
                  'tucanae47': '47 Tucanae',
                },
                compass: ['N', 'E', 'S', 'W'],
              ),
              view: ValueNotifier(view),
              active: false,
              lowPower: false,
              clock: () => time,
              onReady: () => ready.add(true),
              onError: (e) => fail('$e'),
            ),
          ),
        ),
      );
      for (var i = 0; i < 50 && ready.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(ready, isNotEmpty);
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      File('$dir/$name.png').writeAsBytesSync(bytes!);
    });
  }
}
