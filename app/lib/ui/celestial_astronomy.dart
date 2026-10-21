import 'dart:math' as math;

/// Positions of the Sun, the Moon and the planets for the Celestial
/// screensaver, accurate to a few arcminutes, which is under a pixel at
/// the widest field of view.
///
/// Orbital elements and perturbation terms follow Paul Schlyter's "How to
/// compute planetary positions", which gives coordinates for the equinox
/// of the date. Stars come in J2000 and are precessed to the same frame.
///
/// Horizon vectors are x east, y north, z up.

const _rad = math.pi / 180;
const _deg = 180 / math.pi;

double _sin(double degrees) => math.sin(degrees * _rad);
double _cos(double degrees) => math.cos(degrees * _rad);
double _rev(double degrees) => degrees - 360 * (degrees / 360).floorToDouble();

/// A direction or position, unit length for directions.
class SkyVector {
  const SkyVector(this.x, this.y, this.z);
  final double x, y, z;

  double dot(SkyVector o) => x * o.x + y * o.y + z * o.z;
  double get length => math.sqrt(x * x + y * y + z * z);
  SkyVector get unit {
    final l = length;
    return l == 0 ? this : SkyVector(x / l, y / l, z / l);
  }

  SkyVector operator -(SkyVector o) => SkyVector(x - o.x, y - o.y, z - o.z);
  SkyVector operator +(SkyVector o) => SkyVector(x + o.x, y + o.y, z + o.z);
  SkyVector operator *(double s) => SkyVector(x * s, y * s, z * s);
  SkyVector cross(SkyVector o) =>
      SkyVector(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  /// From right ascension and declination, or any longitude and latitude,
  /// in degrees.
  factory SkyVector.spherical(double lon, double lat) {
    final c = _cos(lat);
    return SkyVector(c * _cos(lon), c * _sin(lon), _sin(lat));
  }

  /// From altitude and azimuth in degrees, azimuth from north through east.
  factory SkyVector.horizon(double altitude, double azimuth) {
    final c = _cos(altitude);
    return SkyVector(c * _sin(azimuth), c * _cos(azimuth), _sin(altitude));
  }

  /// Altitude in degrees of a horizon vector.
  double get altitude => math.asin(z.clamp(-1.0, 1.0)) * _deg;

  /// Azimuth in degrees of a horizon vector, north through east.
  double get azimuth => _rev(math.atan2(x, y) * _deg);

  @override
  String toString() => 'SkyVector($x, $y, $z)';
}

/// A rotation, row major.
class SkyMatrix {
  const SkyMatrix(this.m);
  final List<double> m;

  static const identity = SkyMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  SkyVector apply(SkyVector v) => SkyVector(
    m[0] * v.x + m[1] * v.y + m[2] * v.z,
    m[3] * v.x + m[4] * v.y + m[5] * v.z,
    m[6] * v.x + m[7] * v.y + m[8] * v.z,
  );

  SkyMatrix operator *(SkyMatrix o) {
    final r = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        var sum = 0.0;
        for (var k = 0; k < 3; k++) {
          sum += m[i * 3 + k] * o.m[k * 3 + j];
        }
        r[i * 3 + j] = sum;
      }
    }
    return SkyMatrix(r);
  }

  SkyMatrix get transposed =>
      SkyMatrix([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);
}

/// Julian day of a moment.
double julianDay(DateTime time) =>
    time.toUtc().millisecondsSinceEpoch / 86400000.0 + 2440587.5;

/// Precession from J2000 to the mean equinox of [jd] (IAU 1976 angles).
SkyMatrix precessionFromJ2000(double jd) {
  final t = (jd - 2451545.0) / 36525;
  final zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) / 3600;
  final z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) / 3600;
  final theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) / 3600;
  final cz = _cos(zeta), sz = _sin(zeta);
  final cZ = _cos(z), sZ = _sin(z);
  final ct = _cos(theta), st = _sin(theta);
  return SkyMatrix([
    cz * cZ * ct - sz * sZ,
    -sz * cZ * ct - cz * sZ,
    -cZ * st,
    cz * sZ * ct + sz * cZ,
    -sz * sZ * ct + cz * cZ,
    -sZ * st,
    cz * st,
    -sz * st,
    ct,
  ]);
}

/// Greenwich mean sidereal time in degrees.
double greenwichSiderealTime(double jd) {
  final t = (jd - 2451545.0) / 36525;
  return _rev(
    280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        t * t * t / 38710000,
  );
}

/// Equatorial coordinates of the date to the horizon of an observer.
SkyMatrix equatorialToHorizon(double latitude, double localSiderealTime) {
  final sl = _sin(localSiderealTime), cl = _cos(localSiderealTime);
  final sp = _sin(latitude), cp = _cos(latitude);
  return SkyMatrix([-sl, cl, 0, -sp * cl, -sp * sl, cp, cp * cl, cp * sl, sp]);
}

/// Atmospheric refraction in degrees for a true altitude (Saemundsson),
/// for standard pressure and temperature.
double refraction(double altitude) {
  if (altitude < -2) return 0;
  final h = math.max(altitude, -1.9);
  return 1.02 / math.tan((h + 10.3 / (h + 5.11)) * _rad) / 60;
}

/// A horizon vector lifted by refraction.
SkyVector refract(SkyVector v) {
  final alt = v.altitude;
  final r = refraction(alt);
  if (r == 0) return v;
  return SkyVector.horizon(alt + r, v.azimuth);
}

/// Air masses along the line of sight at [altitude] (Kasten and Young).
double airMass(double altitude) {
  final h = math.max(altitude, -0.5);
  return 1 / (_sin(h) + 0.50572 * math.pow(h + 6.07995, -1.6364));
}

enum SkyBody {
  sun,
  moon,
  mercury,
  venus,
  mars,
  jupiter,
  saturn,
  uranus,
  neptune,
}

/// A body of the solar system for one moment and place.
class SkyBodyPosition {
  const SkyBodyPosition(
    this.body,
    this.horizon,
    this.magnitude, {
    this.distance = 0,
  });
  final SkyBody body;

  /// Apparent direction above the observer's horizon, refraction included.
  final SkyVector horizon;
  final double magnitude;

  /// Kilometers, for the Moon's apparent size.
  final double distance;
}

class _Elements {
  const _Elements(this.n, this.i, this.w, this.a, this.e, this.m);
  final double n, i, w, a, e, m;
}

_Elements _planetElements(SkyBody body, double d) => switch (body) {
  SkyBody.mercury => _Elements(
    48.3313 + 3.24587e-5 * d,
    7.0047 + 5.00e-8 * d,
    29.1241 + 1.01444e-5 * d,
    0.387098,
    0.205635 + 5.59e-10 * d,
    168.6562 + 4.0923344368 * d,
  ),
  SkyBody.venus => _Elements(
    76.6799 + 2.46590e-5 * d,
    3.3946 + 2.75e-8 * d,
    54.8910 + 1.38374e-5 * d,
    0.723330,
    0.006773 - 1.302e-9 * d,
    48.0052 + 1.6021302244 * d,
  ),
  SkyBody.mars => _Elements(
    49.5574 + 2.11081e-5 * d,
    1.8497 - 1.78e-8 * d,
    286.5016 + 2.92961e-5 * d,
    1.523688,
    0.093405 + 2.516e-9 * d,
    18.6021 + 0.5240207766 * d,
  ),
  SkyBody.jupiter => _Elements(
    100.4542 + 2.76854e-5 * d,
    1.3030 - 1.557e-7 * d,
    273.8777 + 1.64505e-5 * d,
    5.20256,
    0.048498 + 4.469e-9 * d,
    19.8950 + 0.0830853001 * d,
  ),
  SkyBody.saturn => _Elements(
    113.6634 + 2.38980e-5 * d,
    2.4886 - 1.081e-7 * d,
    339.3939 + 2.97661e-5 * d,
    9.55475,
    0.055546 - 9.499e-9 * d,
    316.9670 + 0.0334442282 * d,
  ),
  SkyBody.uranus => _Elements(
    74.0005 + 1.3978e-5 * d,
    0.7733 + 1.9e-8 * d,
    96.6612 + 3.0565e-5 * d,
    19.18171 - 1.55e-8 * d,
    0.047318 + 7.45e-9 * d,
    142.5905 + 0.011725806 * d,
  ),
  SkyBody.neptune => _Elements(
    131.7806 + 3.0173e-5 * d,
    1.7700 - 2.55e-7 * d,
    272.8461 - 6.027e-6 * d,
    30.05826 + 3.313e-8 * d,
    0.008606 + 2.15e-9 * d,
    260.2471 + 0.005995147 * d,
  ),
  _ => throw ArgumentError(body),
};

/// Eccentric anomaly in degrees.
double _eccentricAnomaly(double m, double e) {
  var ea = m + e * _deg * _sin(m) * (1 + e * _cos(m));
  for (var k = 0; k < 8; k++) {
    final delta = (ea - e * _deg * _sin(ea) - m) / (1 - e * _cos(ea));
    ea -= delta;
    if (delta.abs() < 1e-6) break;
  }
  return ea;
}

/// Heliocentric ecliptic position of an orbit, in its own distance unit.
SkyVector _orbitPosition(_Elements el) {
  final ea = _eccentricAnomaly(_rev(el.m), el.e);
  final xv = el.a * (_cos(ea) - el.e);
  final yv = el.a * math.sqrt(1 - el.e * el.e) * _sin(ea);
  final v = math.atan2(yv, xv) * _deg;
  final r = math.sqrt(xv * xv + yv * yv);
  final vw = v + el.w;
  return SkyVector(
    r * (_cos(el.n) * _cos(vw) - _sin(el.n) * _sin(vw) * _cos(el.i)),
    r * (_sin(el.n) * _cos(vw) + _cos(el.n) * _sin(vw) * _cos(el.i)),
    r * _sin(vw) * _sin(el.i),
  );
}

/// Applies longitude and latitude corrections in degrees to an ecliptic
/// position.
SkyVector _perturb(SkyVector p, double dLon, double dLat) {
  if (dLon == 0 && dLat == 0) return p;
  final r = p.length;
  final lon = math.atan2(p.y, p.x) * _deg + dLon;
  final lat = math.asin(p.z / r) * _deg + dLat;
  return SkyVector.spherical(lon, lat) * r;
}

/// Everything about the sky for one moment and place.
class SkyEphemeris {
  SkyEphemeris._(
    this.time,
    this.latitude,
    this.longitude,
    this.j2000ToHorizon,
    this.bodies,
  );

  factory SkyEphemeris(
    DateTime time,
    double latitude,
    double longitude, {
    bool refracted = true,
  }) {
    SkyVector lift(SkyVector v) => refracted ? refract(v) : v;
    final jd = julianDay(time);
    // Terrestrial time runs about 69 s ahead of UTC.
    final d = jd + 69.0 / 86400 - 2451543.5;
    final lst = _rev(greenwichSiderealTime(jd) + longitude);
    final toHorizon = equatorialToHorizon(latitude, lst);
    final ecl = 23.4393 - 3.563e-7 * d;
    final ce = _cos(ecl), se = _sin(ecl);
    SkyVector toEquatorial(SkyVector p) =>
        SkyVector(p.x, p.y * ce - p.z * se, p.y * se + p.z * ce);

    // The Sun, as the Earth's orbit seen from the other side.
    final sunElements = _Elements(
      0,
      0,
      282.9404 + 4.70935e-5 * d,
      1,
      0.016709 - 1.151e-9 * d,
      356.0470 + 0.9856002585 * d,
    );
    final sun = _orbitPosition(sunElements);
    final bodies = <SkyBody, SkyBodyPosition>{};
    final sunHorizon = toHorizon.apply(toEquatorial(sun).unit);
    bodies[SkyBody.sun] = SkyBodyPosition(
      SkyBody.sun,
      lift(sunHorizon),
      -26.7,
      distance: sun.length * 149597870.7,
    );
    bodies[SkyBody.moon] = _moon(d, sun, toEquatorial, toHorizon, lift);

    final mj = _rev(19.8950 + 0.0830853001 * d);
    final ms = _rev(316.9670 + 0.0334442282 * d);
    final mu = _rev(142.5905 + 0.011725806 * d);
    for (final body in const [
      SkyBody.mercury,
      SkyBody.venus,
      SkyBody.mars,
      SkyBody.jupiter,
      SkyBody.saturn,
      SkyBody.uranus,
      SkyBody.neptune,
    ]) {
      var helio = _orbitPosition(_planetElements(body, d));
      if (body == SkyBody.jupiter) {
        helio = _perturb(
          helio,
          -0.332 * _sin(2 * mj - 5 * ms - 67.6) -
              0.056 * _sin(2 * mj - 2 * ms + 21) +
              0.042 * _sin(3 * mj - 5 * ms + 21) -
              0.036 * _sin(mj - 2 * ms) +
              0.022 * _cos(mj - ms) +
              0.023 * _sin(2 * mj - 3 * ms + 52) -
              0.016 * _sin(mj - 5 * ms - 69),
          0,
        );
      } else if (body == SkyBody.saturn) {
        helio = _perturb(
          helio,
          0.812 * _sin(2 * mj - 5 * ms - 67.6) -
              0.229 * _cos(2 * mj - 4 * ms - 2) +
              0.119 * _sin(mj - 2 * ms - 3) +
              0.046 * _sin(2 * mj - 6 * ms - 69) +
              0.014 * _sin(mj - 3 * ms + 32),
          -0.020 * _cos(2 * mj - 4 * ms - 2) +
              0.018 * _sin(2 * mj - 6 * ms - 49),
        );
      } else if (body == SkyBody.uranus) {
        helio = _perturb(
          helio,
          0.040 * _sin(ms - 2 * mu + 6) +
              0.035 * _sin(ms - 3 * mu + 33) -
              0.015 * _sin(mj - mu + 20),
          0,
        );
      }
      final geo = helio + sun;
      final r = helio.length, distance = geo.length, s = sun.length;
      final phase =
          math.acos(
            ((r * r + distance * distance - s * s) / (2 * r * distance)).clamp(
              -1.0,
              1.0,
            ),
          ) *
          _deg;
      final base = 5 * math.log(r * distance) / math.ln10;
      final magnitude = switch (body) {
        SkyBody.mercury =>
          -0.36 + base + 0.027 * phase + 2.2e-13 * math.pow(phase, 6),
        SkyBody.venus =>
          -4.34 + base + 0.013 * phase + 4.2e-7 * math.pow(phase, 3),
        SkyBody.mars => -1.51 + base + 0.016 * phase,
        SkyBody.jupiter => -9.25 + base + 0.014 * phase,
        // The rings add about half a magnitude on average.
        SkyBody.saturn => -9.0 + base + 0.044 * phase - 0.5,
        SkyBody.uranus => -7.15 + base + 0.001 * phase,
        _ => -6.90 + base + 0.001 * phase,
      };
      bodies[body] = SkyBodyPosition(
        body,
        lift(toHorizon.apply(toEquatorial(geo).unit)),
        magnitude,
        distance: distance * 149597870.7,
      );
    }
    return SkyEphemeris._(
      time,
      latitude,
      longitude,
      toHorizon * precessionFromJ2000(jd),
      bodies,
    );
  }

  static SkyBodyPosition _moon(
    double d,
    SkyVector sun,
    SkyVector Function(SkyVector) toEquatorial,
    SkyMatrix toHorizon,
    SkyVector Function(SkyVector) lift,
  ) {
    final el = _Elements(
      125.1228 - 0.0529538083 * d,
      5.1454,
      318.0634 + 0.1643573223 * d,
      60.2666,
      0.054900,
      115.3654 + 13.0649929509 * d,
    );
    var p = _orbitPosition(el);
    final mm = _rev(el.m);
    final msun = _rev(356.0470 + 0.9856002585 * d);
    final lm = _rev(el.n + el.w + mm);
    final ls = _rev(282.9404 + 4.70935e-5 * d + msun);
    final dd = lm - ls;
    final f = lm - el.n;
    final dLon =
        -1.274 * _sin(mm - 2 * dd) +
        0.658 * _sin(2 * dd) -
        0.186 * _sin(msun) -
        0.059 * _sin(2 * mm - 2 * dd) -
        0.057 * _sin(mm - 2 * dd + msun) +
        0.053 * _sin(mm + 2 * dd) +
        0.046 * _sin(2 * dd - msun) +
        0.041 * _sin(mm - msun) -
        0.035 * _sin(dd) -
        0.031 * _sin(mm + msun) -
        0.015 * _sin(2 * f - 2 * dd) +
        0.011 * _sin(mm - 4 * dd);
    final dLat =
        -0.173 * _sin(f - 2 * dd) -
        0.055 * _sin(mm - f - 2 * dd) -
        0.046 * _sin(mm + f - 2 * dd) +
        0.033 * _sin(f + 2 * dd) +
        0.017 * _sin(2 * mm + f);
    final dR = -0.58 * _cos(mm - 2 * dd) - 0.46 * _cos(2 * dd);
    p = _perturb(p, dLon, dLat);
    final radii = p.length + dR;
    final geocentric = toHorizon.apply(toEquatorial(p).unit);
    // Topocentric: the Moon sits lower by its parallax.
    final alt = geocentric.altitude;
    final parallax = math.asin(1 / radii) * _deg * _cos(alt);
    final topo = SkyVector.horizon(alt - parallax, geocentric.azimuth);
    // Brightness from the illuminated fraction.
    final elongation = math.acos(p.unit.dot(sun.unit).clamp(-1.0, 1.0)) * _deg;
    final phase = 180 - elongation;
    final magnitude = -12.73 + 0.026 * phase + 4e-9 * math.pow(phase, 4);
    return SkyBodyPosition(
      SkyBody.moon,
      lift(topo),
      magnitude,
      distance: radii * 6378.14,
    );
  }

  final DateTime time;
  final double latitude, longitude;

  /// J2000 equatorial unit vectors to the observer's horizon.
  final SkyMatrix j2000ToHorizon;
  final Map<SkyBody, SkyBodyPosition> bodies;

  SkyBodyPosition get sun => bodies[SkyBody.sun]!;
  SkyBodyPosition get moon => bodies[SkyBody.moon]!;

  /// Fraction of the Moon's disk in sunlight, 0 to 1.
  double get moonIllumination {
    final cosE = sun.horizon.dot(moon.horizon);
    return (1 - cosE) / 2;
  }
}
