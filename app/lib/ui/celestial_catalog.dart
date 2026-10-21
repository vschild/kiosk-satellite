import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

import 'celestial_astronomy.dart';

/// A constellation's figure and name.
class CelestialConstellation {
  const CelestialConstellation({
    required this.id,
    required this.name,
    required this.names,
    required this.rank,
    required this.label,
    required this.segments,
    required this.ends,
  });

  final String id;

  /// The IAU (Latin) name, and its translations by language code.
  final String name;
  final Map<String, String> names;

  /// 1 for the major constellations, up to 3 for the faint ones.
  final int rank;

  /// Where the name goes, as a J2000 unit vector.
  final SkyVector label;

  /// Line segments as J2000 unit vectors, six floats per segment.
  final Float32List segments;

  /// Magnitude of the star at each end of each segment, two per segment.
  final Float32List ends;

  String nameFor(String language) => names[language] ?? name;
}

/// A galaxy, nebula or cluster with a name worth showing.
class CelestialDeepSky {
  const CelestialDeepSky({
    required this.key,
    required this.kind,
    required this.direction,
    required this.magnitude,
    required this.major,
    required this.minor,
    required this.angle,
  });

  /// Message key of its name.
  final String key;

  /// galaxy, nebula, cloud or cluster.
  final String kind;
  final SkyVector direction;
  final double magnitude;

  /// Apparent size in arcminutes.
  final double major, minor;

  /// Position angle of the major axis, degrees east of north.
  final double angle;
}

/// The bundled sky: stars, constellations, deep-sky objects and images.
class CelestialCatalog {
  CelestialCatalog._({
    required this.stars,
    required this.magnitudes,
    required this.colors,
    required this.starNames,
    required this.starDesignations,
    required this.constellations,
    required this.deepSky,
    required this.milkyWay,
    required this.moon,
  });

  /// J2000 unit vectors, three floats per star, brightest first.
  final Float32List stars;
  final Float32List magnitudes;

  /// Display color per star from its B-V index, as RGB in 0..1.
  final Float32List colors;

  /// Proper names of stars, by star index.
  final Map<int, String> starNames;

  /// The Bayer letter or Flamsteed number of stars without a proper name,
  /// like γ Cen or 61 Cyg, by star index.
  final Map<int, String> starDesignations;
  final List<CelestialConstellation> constellations;
  final List<CelestialDeepSky> deepSky;
  final ui.Image milkyWay, moon;

  int get starCount => magnitudes.length;

  static Future<CelestialCatalog>? _loading;

  /// Loads once per process. The images stay in memory, about 10 MB of
  /// texture between them.
  static Future<CelestialCatalog> load() =>
      _loading ??= _load().catchError((Object error) {
        _loading = null;
        throw error;
      });

  static Future<CelestialCatalog> _load() async {
    final bin = await rootBundle.load('assets/celestial/stars.bin');
    final count = bin.getUint32(4, Endian.little);
    final stars = Float32List(count * 3);
    final magnitudes = Float32List(count);
    final colors = Float32List(count * 3);
    for (var i = 0; i < count; i++) {
      final o = 8 + i * 12;
      final ra = bin.getFloat32(o, Endian.little);
      final dec = bin.getFloat32(o + 4, Endian.little);
      final v = SkyVector.spherical(ra, dec);
      stars[i * 3] = v.x;
      stars[i * 3 + 1] = v.y;
      stars[i * 3 + 2] = v.z;
      magnitudes[i] = bin.getInt16(o + 8, Endian.little) / 100;
      final rgb = starColor(bin.getInt16(o + 10, Endian.little) / 1000);
      colors[i * 3] = rgb.$1;
      colors[i * 3 + 1] = rgb.$2;
      colors[i * 3 + 2] = rgb.$3;
    }
    final sky =
        jsonDecode(await rootBundle.loadString('assets/celestial/sky.json'))
            as Map<String, Object?>;
    final constellations = [
      for (final c in sky['constellations'] as List)
        _constellation(c as Map<String, Object?>),
    ];
    final deepSky = [
      for (final d in sky['dsos'] as List) _deepSky(d as Map<String, Object?>),
    ];
    final starNames = {
      for (final e in (sky['starNames'] as Map<String, Object?>).entries)
        int.parse(e.key): e.value as String,
    };
    final starDesignations = {
      for (final e
          in (sky['starDesignations'] as Map<String, Object?>? ?? const {})
              .entries)
        int.parse(e.key): e.value as String,
    };
    final milkyWay = await _image('assets/celestial/milky_way.jpg');
    final moon = await _image('assets/celestial/moon.jpg');
    return CelestialCatalog._(
      stars: stars,
      magnitudes: magnitudes,
      colors: colors,
      starNames: starNames,
      starDesignations: starDesignations,
      constellations: constellations,
      deepSky: deepSky,
      milkyWay: milkyWay,
      moon: moon,
    );
  }

  static CelestialConstellation _constellation(Map<String, Object?> c) {
    final lines = c['lines'] as List;
    final segments = <double>[];
    final ends = <double>[];
    for (final line in lines) {
      // ra, dec and the magnitude of the star there, per vertex.
      final points = (line as List).cast<num>();
      for (var i = 0; i + 5 < points.length; i += 3) {
        final a = SkyVector.spherical(
          points[i].toDouble(),
          points[i + 1].toDouble(),
        );
        final b = SkyVector.spherical(
          points[i + 3].toDouble(),
          points[i + 4].toDouble(),
        );
        segments.addAll([a.x, a.y, a.z, b.x, b.y, b.z]);
        ends.addAll([points[i + 2].toDouble(), points[i + 5].toDouble()]);
      }
    }
    return CelestialConstellation(
      id: c['id'] as String,
      name: c['name'] as String,
      names: (c['names'] as Map<String, Object?>).map(
        (k, v) => MapEntry(k, v as String),
      ),
      rank: (c['rank'] as num).toInt(),
      label: SkyVector.spherical(
        (c['ra'] as num).toDouble(),
        (c['dec'] as num).toDouble(),
      ),
      segments: Float32List.fromList(segments),
      ends: Float32List.fromList(ends),
    );
  }

  static CelestialDeepSky _deepSky(Map<String, Object?> d) {
    final size = (d['size'] as List).cast<num>();
    return CelestialDeepSky(
      key: d['key'] as String,
      kind: d['kind'] as String,
      direction: SkyVector.spherical(
        (d['ra'] as num).toDouble(),
        (d['dec'] as num).toDouble(),
      ),
      magnitude: (d['mag'] as num).toDouble(),
      major: size[0].toDouble(),
      minor: size[1].toDouble(),
      angle: (d['pa'] as num).toDouble(),
    );
  }

  static Future<ui.Image> _image(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }
}

/// A star's tint from its B-V color index: the temperature from
/// Ballesteros' formula, then a black body, kept pale the way the eye sees
/// stars.
(double, double, double) starColor(double bv) {
  final t = 4600 * (1 / (0.92 * bv + 1.7) + 1 / (0.92 * bv + 0.62));
  final k = t / 100;
  double r, g, b;
  if (k <= 66) {
    r = 255;
    g = 99.4708025861 * math.log(k) - 161.1195681661;
    b = k <= 19 ? 0 : 138.5177312231 * math.log(k - 10) - 305.0447927307;
  } else {
    r = 329.698727446 * math.pow(k - 60, -0.1332047592);
    g = 288.1221695283 * math.pow(k - 60, -0.0755148492);
    b = 255;
  }
  double norm(double v) => (v.clamp(0, 255)) / 255;
  final rgb = (norm(r), norm(g), norm(b));
  // Halfway to white: saturated black bodies look like Christmas lights.
  const keep = 0.5;
  return (
    1 - (1 - rgb.$1) * keep,
    1 - (1 - rgb.$2) * keep,
    1 - (1 - rgb.$3) * keep,
  );
}

/// The ground around the observer as two ridgelines, far and near, in
/// degrees of altitude for each of [samples] azimuths.
class CelestialTerrain {
  CelestialTerrain._(this.style, this.near, this.far);

  static const samples = 4096;

  final String style;
  final Float32List near, far;

  /// Height of the ground in degrees at [azimuth], interpolated.
  double heightAt(double azimuth) {
    final x = (azimuth / 360 % 1) * samples;
    final i = x.floor() % samples;
    final f = x - x.floorToDouble();
    final j = (i + 1) % samples;
    final n = near[i] + (near[j] - near[i]) * f;
    final m = far[i] + (far[j] - far[i]) * f;
    return math.max(n, m);
  }

  factory CelestialTerrain(String style) {
    final random = math.Random(switch (style) {
      'none' => 0,
      'mountains' => 11,
      'plains' => 37,
      _ => 23,
    });
    final near = Float32List(samples), far = Float32List(samples);
    final farNoise = _Noise(random), nearNoise = _Noise(random);
    final forest = _Noise(random);
    for (var i = 0; i < samples; i++) {
      final u = i / samples;
      switch (style) {
        case 'mountains':
          final ridged = 1 - (farNoise.fbm(u, 6, 6) * 2 - 1).abs();
          far[i] =
              1 +
              13 *
                  math.pow(ridged, 1.8) *
                  (0.35 + 0.65 * farNoise.fbm(u, 2, 2));
          // Jagged crests, rougher the higher the ridge.
          far[i] += (farNoise.fbm(u, 90, 4) - 0.5) * (0.4 + far[i] * 0.22);
          near[i] = 0.3 + 3.2 * math.pow(nearNoise.fbm(u, 6, 5), 1.4);
        case 'none':
          // A level horizon with nothing on it.
          far[i] = 0;
          near[i] = 0;
        case 'plains':
          far[i] = 0.05 + 0.4 * math.pow(farNoise.fbm(u, 48, 4), 2);
          near[i] = -0.25 + 0.2 * nearNoise.fbm(u, 8, 3);
        default:
          far[i] = 0.4 + 6 * math.pow(farNoise.fbm(u, 16, 6), 1.8);
          near[i] = 0.15 + 2.4 * math.pow(nearNoise.fbm(u, 11, 5), 1.5);
      }
    }
    // Woods along the near ground: a canopy of rounded crowns, billowed
    // noise, in stands that thin out at their edges, with conifer tips
    // rising out of it.
    if (style == 'none') return CelestialTerrain._(style, near, far);
    final canopyHeight = switch (style) {
      'mountains' => 0.9,
      'plains' => 0.55,
      _ => 1.1,
    };
    final threshold = style == 'plains' ? 0.58 : 0.44;
    final crowns = _Noise(random);
    for (var i = 0; i < samples; i++) {
      final u = i / samples;
      final stand = ((forest.fbm(u, 11, 3) - threshold) / 0.08).clamp(0.0, 1.0);
      if (stand <= 0) continue;
      var billow = 0.0, weight = 0.0, amplitude = 1.0, cells = 420;
      for (var o = 0; o < 3; o++) {
        billow += (1 - (crowns.fbm(u, cells, 1) * 2 - 1).abs()) * amplitude;
        weight += amplitude;
        amplitude *= 0.45;
        cells *= 2;
      }
      final canopy = canopyHeight * (0.2 + 0.8 * billow / weight);
      near[i] = math.max(near[i], near[i] - 0.1 + canopy * stand);
    }
    final spires = style == 'hills' ? 500 : 900;
    for (var t = 0; t < spires; t++) {
      final u = random.nextDouble();
      if (forest.fbm(u, 11, 3) < threshold + 0.04) continue;
      final width = 0.22 + random.nextDouble() * 0.22;
      final height = canopyHeight * (0.25 + random.nextDouble() * 0.6);
      final center = u * samples;
      final half = width / 360 * samples / 2;
      final base = near[center.floor() % samples];
      for (var x = (center - half).floor(); x <= (center + half).ceil(); x++) {
        final d = ((x - center) / half).abs();
        if (d > 1) continue;
        final i = x % samples;
        near[i] = math.max(near[i], base + height * math.pow(1 - d, 1.6));
      }
    }
    return CelestialTerrain._(style, near, far);
  }

  /// The profile as a 4096 by 2 image for the terrain shader: row 0 near,
  /// row 1 far, each height in red (high byte) and green (low byte).
  Future<ui.Image> toImage() {
    final pixels = Uint8List(samples * 2 * 4);
    void row(Float32List heights, int y) {
      for (var i = 0; i < samples; i++) {
        final v = (((heights[i] + 2) / 16).clamp(0.0, 1.0) * 65535).round();
        final o = (y * samples + i) * 4;
        pixels[o] = v >> 8;
        pixels[o + 1] = v & 0xff;
        pixels[o + 2] = 0;
        pixels[o + 3] = 255;
      }
    }

    row(near, 0);
    row(far, 1);
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      samples,
      2,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}

/// Periodic value noise over one turn of azimuth.
class _Noise {
  _Noise(math.Random random)
    : _values = Float64List.fromList([
        for (var i = 0; i < 2048; i++) random.nextDouble(),
      ]);

  final Float64List _values;

  double _at(double u, int cells) {
    final x = (u % 1) * cells;
    final i = x.floor();
    final f = x - i;
    double v(int k) => _values[(k % cells + cells) % cells * 7 % 2048];
    // Cubic through four neighbors keeps ridges smooth.
    final p0 = v(i - 1), p1 = v(i), p2 = v(i + 1), p3 = v(i + 2);
    final a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
    final b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3;
    final c = -0.5 * p0 + 0.5 * p2;
    return (((a * f + b) * f + c) * f + p1).clamp(0.0, 1.0);
  }

  /// Fractal sum from [cells] cells per turn over [octaves] octaves, 0..1.
  double fbm(double u, int cells, int octaves) {
    var sum = 0.0, weight = 0.0, amplitude = 1.0, n = cells;
    for (var o = 0; o < octaves; o++) {
      sum += _at(u, n) * amplitude;
      weight += amplitude;
      amplitude *= 0.5;
      n *= 2;
    }
    return sum / weight;
  }
}
