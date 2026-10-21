import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/celestial_astronomy.dart';

/// Separation in degrees between two altitude and azimuth pairs.
double _separation(List<num> a, SkyVector b) {
  final v = SkyVector.horizon(a[0].toDouble(), a[1].toDouble());
  return math.acos(v.dot(b).clamp(-1.0, 1.0)) * 180 / math.pi;
}

void main() {
  // Generated with Astronomy Engine (MIT), which is good to an arcminute,
  // without refraction: below the horizon it keeps a scaled refraction
  // that the screensaver has no use for.
  final cases =
      jsonDecode(
            File('test/fixtures/celestial_ephemeris.json').readAsStringSync(),
          )
          as List;

  test('the Sun, Moon and planets land within a few arcminutes', () {
    for (final c in cases) {
      final sky = SkyEphemeris(
        DateTime.parse(c['time'] as String),
        (c['lat'] as num).toDouble(),
        (c['lon'] as num).toDouble(),
        refracted: false,
      );
      final expected = c['bodies'] as Map<String, Object?>;
      for (final body in SkyBody.values) {
        final position = sky.bodies[body]!;
        final error = _separation(
          (expected[body.name] as List).cast<num>(),
          position.horizon,
        );
        expect(
          error,
          lessThan(0.06),
          reason: '${body.name} at ${c['time']} is off by $error degrees',
        );
      }
    }
  });

  test('J2000 stars precess to the observer\'s horizon', () {
    const stars = {
      'Sirius': (101.2872, -16.7161),
      'Polaris': (37.9546, 89.2641),
      'Vega': (279.2347, 38.7837),
    };
    for (final c in cases) {
      final sky = SkyEphemeris(
        DateTime.parse(c['time'] as String),
        (c['lat'] as num).toDouble(),
        (c['lon'] as num).toDouble(),
      );
      final expected = c['stars'] as Map<String, Object?>;
      stars.forEach((name, radec) {
        final v = sky.j2000ToHorizon.apply(
          SkyVector.spherical(radec.$1, radec.$2),
        );
        final error = _separation((expected[name] as List).cast<num>(), v);
        // Nutation and aberration are left out, about 20 arcseconds each.
        expect(error, lessThan(0.02), reason: '$name at ${c['time']}: $error');
      });
    }
  });

  test('refraction lifts the horizon by about half a degree', () {
    expect(refraction(0), closeTo(0.48, 0.03));
    expect(refraction(45), closeTo(0.0167, 0.002));
    expect(refraction(-5), 0);
  });

  test('the Moon is brightest when full', () {
    // 2026-10-26 is a full moon, 2026-10-10 a new one.
    final full = SkyEphemeris(DateTime.utc(2026, 10, 26, 4), 0, 0);
    final fresh = SkyEphemeris(DateTime.utc(2026, 10, 10, 16), 0, 0);
    expect(full.moonIllumination, greaterThan(0.95));
    expect(fresh.moonIllumination, lessThan(0.05));
    expect(full.moon.magnitude, lessThan(fresh.moon.magnitude));
  });
}
