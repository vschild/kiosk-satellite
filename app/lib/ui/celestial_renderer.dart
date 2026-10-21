import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'celestial_astronomy.dart';
import 'celestial_catalog.dart';

/// Where the screensaver looks: azimuth and altitude of the center of the
/// screen, and the field of view across the longer side, in degrees.
/// The screen's own axes in the observer's frame, from the device's
/// orientation sensor: the view of a tablet held up to the sky, roll
/// included.
@immutable
class CelestialFrame {
  const CelestialFrame(this.right, this.up, this.forward);
  final SkyVector right, up, forward;

  @override
  bool operator ==(Object other) =>
      other is CelestialFrame &&
      _same(other.right, right) &&
      _same(other.up, up) &&
      _same(other.forward, forward);

  static bool _same(SkyVector a, SkyVector b) =>
      a.x == b.x && a.y == b.y && a.z == b.z;

  @override
  int get hashCode => Object.hash(
    right.x,
    right.y,
    right.z,
    up.x,
    up.y,
    up.z,
    forward.x,
    forward.y,
    forward.z,
  );
}

@immutable
class CelestialView {
  const CelestialView({
    required this.azimuth,
    required this.altitude,
    required this.fov,
    this.frame,
  });

  static const minFov = 20.0, maxFov = 120.0, defaultFov = 100.0;
  static const minAltitude = -5.0, maxAltitude = 89.0;

  final double azimuth, altitude, fov;

  /// Set while the view follows the device; it overrides [azimuth] and
  /// [altitude] and is never saved.
  final CelestialFrame? frame;

  CelestialView copyWith({
    double? azimuth,
    double? altitude,
    double? fov,
    CelestialFrame? frame,
    bool clearFrame = false,
  }) => CelestialView(
    azimuth: (azimuth ?? this.azimuth) % 360,
    altitude: (altitude ?? this.altitude).clamp(minAltitude, maxAltitude),
    fov: (fov ?? this.fov).clamp(minFov, maxFov),
    frame: clearFrame ? null : frame ?? this.frame,
  );

  /// "azimuth,altitude,fov", as kept in the view setting.
  String encode() =>
      '${azimuth.toStringAsFixed(1)},${altitude.toStringAsFixed(1)},'
      '${fov.toStringAsFixed(1)}';

  static CelestialView? decode(String value) {
    final parts = value.split(',').map((p) => double.tryParse(p.trim()));
    final list = parts.toList();
    if (list.length != 3 || list.any((v) => v == null || !v.isFinite)) {
      return null;
    }
    return const CelestialView(
      azimuth: 0,
      altitude: 0,
      fov: defaultFov,
    ).copyWith(azimuth: list[0], altitude: list[1], fov: list[2]);
  }

  @override
  bool operator ==(Object other) =>
      other is CelestialView &&
      other.azimuth == azimuth &&
      other.altitude == altitude &&
      other.fov == fov &&
      other.frame == frame;

  @override
  int get hashCode => Object.hash(azimuth, altitude, fov, frame);
}

/// What the screensaver draws.
@immutable
class CelestialOptions {
  const CelestialOptions({
    this.lines = true,
    this.constellationNames = true,
    this.objectNames = true,
    this.planets = true,
    this.milkyWay = true,
    this.deepSky = true,
    this.twinkle = true,
    this.daytime = true,
    this.largeMoon = true,
    this.compass = true,
    this.terrain = 'hills',
    this.lightPollution = 0,
    this.labelScale = 1,
  });

  final bool lines,
      constellationNames,
      objectNames,
      planets,
      milkyWay,
      deepSky,
      twinkle,
      daytime,
      largeMoon,
      compass;
  final String terrain;

  /// City glow from 0 (a dark site) to 1 (a city center).
  final double lightPollution;

  /// The size of the labels on the sky, 1 for the default.
  final double labelScale;

  @override
  bool operator ==(Object other) =>
      other is CelestialOptions &&
      other.lightPollution == lightPollution &&
      other.labelScale == labelScale &&
      other.lines == lines &&
      other.constellationNames == constellationNames &&
      other.objectNames == objectNames &&
      other.planets == planets &&
      other.milkyWay == milkyWay &&
      other.deepSky == deepSky &&
      other.twinkle == twinkle &&
      other.daytime == daytime &&
      other.largeMoon == largeMoon &&
      other.compass == compass &&
      other.terrain == terrain;

  @override
  int get hashCode => Object.hash(
    lines,
    constellationNames,
    objectNames,
    planets,
    milkyWay,
    deepSky,
    twinkle,
    daytime,
    largeMoon,
    compass,
    terrain,
    lightPollution,
    labelScale,
  );
}

/// Names in the reader's language.
@immutable
class CelestialNames {
  const CelestialNames({
    required this.language,
    required this.bodies,
    required this.deepSky,
    required this.compass,
  });

  /// Language code for constellation names. Others show the IAU name.
  final String language;
  final Map<SkyBody, String> bodies;
  final Map<String, String> deepSky;

  /// North, east, south and west.
  final List<String> compass;

  @override
  bool operator ==(Object other) =>
      other is CelestialNames &&
      other.language == language &&
      _sameMap(other.bodies, bodies) &&
      _sameMap(other.deepSky, deepSky) &&
      other.compass.join('|') == compass.join('|');

  static bool _sameMap<K, V>(Map<K, V> a, Map<K, V> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  int get hashCode => Object.hash(language, compass.join('|'));
}

class CelestialRenderer extends StatefulWidget {
  const CelestialRenderer({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.options,
    required this.names,
    required this.view,
    required this.active,
    required this.lowPower,
    this.clock,
    this.timeRate = 1,
    this.timeVersion = 0,
    this.onReady,
    this.onError,
  });

  final double latitude, longitude;
  final CelestialOptions options;
  final CelestialNames names;
  final ValueListenable<CelestialView> view;

  /// Whether the scene animates. Off, it paints once per change.
  final bool active;

  /// Lower frame rate for the twinkle on 32-bit devices.
  final bool lowPower;

  /// The time the sky shows: a timelapse's, or fixed for previews and
  /// tests.
  final DateTime Function()? clock;

  /// How fast [clock] runs against real time. Above 1 the sky moves on
  /// every frame instead of every ten seconds.
  final double timeRate;

  /// Changes whenever [clock] jumps, so the sky follows at once.
  final int timeVersion;
  final VoidCallback? onReady;
  final void Function(Object error)? onError;

  @override
  State<CelestialRenderer> createState() => _CelestialRendererState();
}

class _Programs {
  _Programs(this.sky, this.moon, this.terrain);
  final ui.FragmentProgram sky, moon, terrain;

  static Future<_Programs>? _loading;
  static Future<_Programs> load() => _loading ??=
      Future.wait([
        ui.FragmentProgram.fromAsset('shaders/celestial_sky.frag'),
        ui.FragmentProgram.fromAsset('shaders/celestial_moon.frag'),
        ui.FragmentProgram.fromAsset('shaders/celestial_terrain.frag'),
      ]).then((p) => _Programs(p[0], p[1], p[2])).catchError((Object error) {
        _loading = null;
        throw error;
      });
}

/// Forgets loaded shaders, since each widget test has its own binding.
@visibleForTesting
void resetCelestialPrograms() => _Programs._loading = null;

/// Loads the shaders, the catalog, the sprites and [terrain]'s ground
/// ahead of the first frame. Tests call it with real async.
Future<void> preloadCelestial({String terrain = 'hills'}) async {
  await _Programs.load();
  await CelestialCatalog.load();
  await _Sprites.load();
  await _groundImage(terrain);
}

final _grounds = <String, Future<(CelestialTerrain, ui.Image)>>{};

/// One ground per style per run, about 32 KB of texture each.
Future<(CelestialTerrain, ui.Image)> _groundImage(String style) =>
    _grounds[style] ??= () async {
      final ground = CelestialTerrain(style);
      return (ground, await ground.toImage());
    }();

class _CelestialRendererState extends State<CelestialRenderer> {
  final _repaint = ValueNotifier<int>(0);
  _Scene? _scene;
  Timer? _timer, _sky;
  int? _frameCallback;
  bool _ready = false, _readySent = false, _paused = false;
  final _clock = Stopwatch()..start();
  Duration _period = const Duration(microseconds: 16667);
  int _timeStep = 0;

  @override
  void initState() {
    super.initState();
    widget.view.addListener(_viewChanged);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final programs = await _Programs.load();
      final catalog = await CelestialCatalog.load();
      final sprites = await _Sprites.load();
      if (!mounted) return;
      final scene = _Scene(
        catalog: catalog,
        sprites: sprites,
        sky: programs.sky.fragmentShader(),
        moon: programs.moon.fragmentShader(),
        terrain: programs.terrain.fragmentShader(),
      );
      scene.sky.setImageSampler(
        0,
        catalog.milkyWay,
        filterQuality: FilterQuality.low,
      );
      scene.moon.setImageSampler(
        0,
        catalog.moon,
        filterQuality: FilterQuality.medium,
      );
      await scene.setTerrain(widget.options.terrain);
      if (!mounted) {
        scene.dispose();
        return;
      }
      _scene = scene;
      _configure();
      _ready = true;
      _sky = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
      _refresh();
    } catch (error) {
      if (mounted) widget.onError?.call(error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rate = View.of(context).display.refreshRate;
    if (rate.isFinite && rate >= 20) {
      _period = Duration(microseconds: (1000000 / rate).round());
    }
    final paused = !TickerMode.valuesOf(context).enabled;
    if (paused != _paused) {
      _paused = paused;
      _schedule();
    }
  }

  @override
  void didUpdateWidget(CelestialRenderer old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view) {
      old.view.removeListener(_viewChanged);
      widget.view.addListener(_viewChanged);
    }
    final scene = _scene;
    if (scene != null && old.options.terrain != widget.options.terrain) {
      unawaited(
        scene.setTerrain(widget.options.terrain).then((_) {
          if (mounted) _refresh();
        }),
      );
    }
    _configure();
    if (old.latitude != widget.latitude ||
        old.longitude != widget.longitude ||
        old.options != widget.options ||
        old.names != widget.names ||
        old.timeRate != widget.timeRate ||
        old.timeVersion != widget.timeVersion) {
      _refresh();
    } else if (old.active != widget.active || old.lowPower != widget.lowPower) {
      _schedule();
    }
  }

  void _configure() {
    final scene = _scene;
    if (scene == null) return;
    scene
      ..options = widget.options
      ..names = widget.names
      ..latitude = widget.latitude
      ..longitude = widget.longitude;
  }

  void _viewChanged() {
    _scene?.invalidate();
    _paint();
  }

  /// A new sky for the current moment.
  void _refresh() {
    final scene = _scene;
    if (scene == null || !mounted) return;
    scene.time = (widget.clock ?? DateTime.now)();
    scene.invalidate(ephemeris: true);
    _paint();
    _schedule();
  }

  void _paint() {
    if (!mounted || !_ready) return;
    _repaint.value++;
    if (!_readySent) {
      _readySent = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call();
      });
    }
  }

  bool get _animating =>
      _ready &&
      widget.active &&
      !_paused &&
      (widget.options.twinkle || _timelapse);

  bool get _timelapse => widget.timeRate != 1;

  /// The twinkle and a timelapse run at a steady fraction of the
  /// display's rate, woken half a refresh before their frame so timer
  /// jitter never shifts it.
  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final callback = _frameCallback;
    if (callback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callback);
      _frameCallback = null;
    }
    if (!_animating) return;
    _frameCallback = SchedulerBinding.instance.scheduleFrameCallback(_frame);
  }

  void _frame(Duration timestamp) {
    _frameCallback = null;
    if (!_animating || !mounted) return;
    final fps = widget.lowPower ? 12 : 20;
    final vsyncs = math.max(
      1,
      (1000000 / fps / _period.inMicroseconds).round(),
    );
    _timer = Timer(_period * vsyncs - _period ~/ 2, () {
      if (!_animating || !mounted) return;
      final scene = _scene;
      scene?.seconds = _clock.elapsedMicroseconds / 1e6;
      // The slowest timelapse moves the sky a few pixels a second, so it
      // steps five times a second rather than on every frame.
      final now = _clock.elapsedMilliseconds;
      if (scene != null &&
          _timelapse &&
          (widget.timeRate > 60 || now - _timeStep >= 200)) {
        _timeStep = now;
        scene.time = (widget.clock ?? DateTime.now)();
        scene.invalidate(ephemeris: true);
      }
      _paint();
      _frameCallback = SchedulerBinding.instance.scheduleFrameCallback(_frame);
    });
  }

  @override
  void dispose() {
    widget.view.removeListener(_viewChanged);
    _timer?.cancel();
    _sky?.cancel();
    final callback = _frameCallback;
    if (callback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callback);
    }
    _scene?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(size: Size.infinite, painter: _CelestialPainter(this)),
  );
}

class _CelestialPainter extends CustomPainter {
  _CelestialPainter(this.state) : super(repaint: state._repaint);
  final _CelestialRendererState state;

  @override
  void paint(Canvas canvas, Size size) {
    final scene = state._scene;
    if (scene == null || size.isEmpty) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      return;
    }
    scene.paint(canvas, size, state.widget.view.value);
  }

  @override
  bool shouldRepaint(_CelestialPainter old) => old.state != state;
}

/// The stereographic projection for one view and screen size.
class _Projection {
  _Projection(CelestialView view, Size size)
    : cx = size.width / 2,
      cy = size.height / 2,
      scale =
          math.max(size.width, size.height) /
          (4 * math.tan(view.fov * math.pi / 720)),
      forward =
          view.frame?.forward ?? SkyVector.horizon(view.altitude, view.azimuth),
      right =
          view.frame?.right ??
          SkyVector(
            math.cos(view.azimuth * math.pi / 180),
            -math.sin(view.azimuth * math.pi / 180),
            0,
          ) {
    up = view.frame?.up ?? right.cross(forward);
  }

  final double cx, cy, scale;
  final SkyVector forward, right;
  late final SkyVector up;

  /// Screen position, or null for directions behind the viewer.
  Offset? project(SkyVector h) {
    final z = h.dot(forward);
    if (z < -0.6) return null;
    final k = 2 / (1 + z);
    return Offset(cx + k * h.dot(right) * scale, cy - k * h.dot(up) * scale);
  }

  /// Pixels per radian at a screen position, from the projection's local
  /// magnification.
  double pixelsPerRadian(Offset p) {
    final x = (p.dx - cx) / scale, y = (p.dy - cy) / scale;
    return scale * (4 + x * x + y * y) / 4;
  }
}

/// Star sprites: a sharp core, a wide glare for the brightest and a soft
/// blob for galaxies and nebulae, each in a 64 pixel cell.
class _Sprites {
  _Sprites(this.image);
  final ui.Image image;

  static const cell = 64.0;
  static const core = Rect.fromLTWH(0, 0, cell, cell);
  static const glare = Rect.fromLTWH(cell, 0, cell, cell);
  static const blob = Rect.fromLTWH(cell * 2, 0, cell, cell);

  static List<double> ltrb(Rect r) => [r.left, r.top, r.right, r.bottom];

  /// Sigma of the core in its cell, in pixels.
  static const coreSigma = 6.0;

  static Future<_Sprites>? _loading;
  static Future<_Sprites> load() => _loading ??= _build();

  static Future<_Sprites> _build() {
    const size = 64, width = size * 3;
    final pixels = Uint8List(width * size * 4);
    void put(int cellIndex, double Function(double r) alpha) {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final dx = x + 0.5 - size / 2, dy = y + 0.5 - size / 2;
          final r = math.sqrt(dx * dx + dy * dy);
          final edge = (1 - ((r - 26) / 6).clamp(0.0, 1.0));
          final a = (alpha(r) * edge * 255).round().clamp(0, 255);
          final o = (y * width + cellIndex * size + x) * 4;
          pixels[o] = a;
          pixels[o + 1] = a;
          pixels[o + 2] = a;
          pixels[o + 3] = a;
        }
      }
    }

    put(0, (r) => math.exp(-r * r / (2 * coreSigma * coreSigma)));
    put(1, (r) => 0.55 * math.exp(-r / 7) + 0.25 * math.exp(-r * r / 200));
    put(2, (r) => math.exp(-r * r / (2 * 9.0 * 9.0)));
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      size,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future.then(_Sprites.new);
  }
}

/// One label candidate, placed in priority order.
class _Label {
  _Label(this.text, this.style, this.anchor, this.align, {this.fade = 1});
  final String text;

  /// Opacity from the label's place on screen, 0 to 1.
  final double fade;
  final _LabelStyle style;
  final Offset anchor;

  /// Left of the text at the anchor (after a gap), or centered on it.
  final _Align align;
}

enum _Align { right, center, below }

enum _LabelStyle {
  constellation,
  star,
  designation,
  planet,
  moon,
  deepSky,
  compass,
}

/// Everything one frame needs, rebuilt only when the view, the size, the
/// time or the options change. Twinkle frames only recolor the stars.
class _Scene {
  _Scene({
    required this.catalog,
    required this.sprites,
    required this.sky,
    required this.moon,
    required this.terrain,
  });

  final CelestialCatalog catalog;
  final _Sprites sprites;
  final ui.FragmentShader sky, moon, terrain;
  CelestialTerrain? ground;

  CelestialOptions options = const CelestialOptions();
  CelestialNames names = const CelestialNames(
    language: 'en',
    bodies: {},
    deepSky: {},
    compass: ['N', 'E', 'S', 'W'],
  );
  double latitude = 0, longitude = 0;
  DateTime time = DateTime.now();
  double seconds = 0;

  SkyEphemeris? _ephemeris;
  bool _dirty = true, _ephemerisDirty = true;
  CelestialView? _builtView;
  Size? _builtSize;

  // Built per change.
  double _darkness = 1;
  Float32List _transforms = Float32List(0);
  Float32List _rects = Float32List(0);
  Int32List _colors = Int32List(0);
  Float32List _baseColors = Float32List(0);
  Float32List _twinkle = Float32List(0);
  int _count = 0;
  Float32List _glareTransforms = Float32List(0);
  Float32List _glareRects = Float32List(0);
  Int32List _glareColors = Int32List(0);

  /// Constellation lines in [_lineLevels] groups, faded toward the edges
  /// of the screen.
  List<Float32List> _lines = const [];
  static const _lineLevels = 8;
  final List<_DeepSkyGlow> _glows = [];
  _MoonDisk? _moonDisk;
  Rect? _terrainRect;
  final List<(TextPainter, Offset)> _placed = [];
  final Map<String, TextPainter> _texts = {};

  /// The texts the labels being built use, which the cache keeps.
  final Set<String> _textsUsed = {};

  /// Drops cached texts the last labels did not use once the cache grows
  /// large, before new labels are built. Never during a build: a label
  /// already placed would paint a disposed text.
  void _trimTexts() {
    if (_texts.length > 600) {
      _texts.removeWhere((key, painter) {
        if (_textsUsed.contains(key)) return false;
        painter.dispose();
        return true;
      });
    }
    _textsUsed.clear();
  }

  Future<void> setTerrain(String style) async {
    if (ground?.style == style) return;
    final (next, image) = await _groundImage(style);
    ground = next;
    terrain.setImageSampler(0, image, filterQuality: FilterQuality.low);
    _dirty = true;
  }

  void invalidate({bool ephemeris = false}) {
    _dirty = true;
    if (ephemeris) _ephemerisDirty = true;
  }

  void dispose() {
    _back?.dispose();
    _front?.dispose();
    sky.dispose();
    moon.dispose();
    terrain.dispose();
    for (final t in _texts.values) {
      t.dispose();
    }
  }

  /// The Sun's altitude the sky follows: kept under the horizon with the
  /// daytime sky turned off.
  double get _skySun {
    final s = _ephemeris!.sun.horizon.altitude;
    return options.daytime ? s : math.min(s, -24);
  }

  static double _smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  void paint(Canvas canvas, Size size, CelestialView view) {
    if (_ephemerisDirty || _ephemeris == null) {
      _ephemeris = SkyEphemeris(time, latitude, longitude);
      _ephemerisDirty = false;
      _dirty = true;
    }
    if (_dirty || view != _builtView || size != _builtSize) {
      _build(size, view);
      _record(size);
      _dirty = false;
      _builtView = view;
      _builtSize = size;
    }
    // Twinkle frames replay the layers recorded at the last change and
    // only recolor the stars between them.
    canvas.drawPicture(_back!);
    if (_count > 0) {
      _applyTwinkle();
      canvas.drawRawAtlas(
        sprites.image,
        _transforms,
        _rects,
        _colors,
        BlendMode.modulate,
        null,
        Paint()
          ..blendMode = BlendMode.plus
          ..filterQuality = FilterQuality.low,
      );
    }
    canvas.drawPicture(_front!);
  }

  ui.Picture? _back, _front;

  /// Records what stays still between changes: the sky, glows and lines
  /// behind the stars, and the glare, the Moon, the ground and the labels
  /// in front of them.
  void _record(Size size) {
    _back?.dispose();
    _front?.dispose();
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder);
    canvas.drawRect(Offset.zero & size, Paint()..shader = sky);
    for (final glow in _glows) {
      canvas.save();
      canvas.translate(glow.center.dx, glow.center.dy);
      canvas.rotate(glow.angle);
      canvas.scale(glow.width / _Sprites.cell, glow.height / _Sprites.cell);
      canvas.drawImageRect(
        sprites.image,
        _Sprites.blob,
        const Rect.fromLTWH(
          -_Sprites.cell / 2,
          -_Sprites.cell / 2,
          _Sprites.cell,
          _Sprites.cell,
        ),
        Paint()
          ..colorFilter = ColorFilter.mode(glow.color, BlendMode.modulate)
          ..blendMode = BlendMode.plus,
      );
      canvas.restore();
    }
    final alpha = 0.26 * (1 - _smooth(-13, -6, _skySun));
    if (alpha > 0.01) {
      for (var level = 0; level < _lines.length; level++) {
        if (_lines[level].isEmpty) continue;
        canvas.drawRawPoints(
          ui.PointMode.lines,
          _lines[level],
          Paint()
            ..color = Color.fromRGBO(
              140,
              165,
              220,
              alpha * (level + 1) / _lineLevels,
            )
            ..strokeWidth = 1
            ..isAntiAlias = true,
        );
      }
    }
    _back = recorder.endRecording();

    recorder = ui.PictureRecorder();
    canvas = Canvas(recorder);
    if (_glareColors.isNotEmpty) {
      canvas.drawRawAtlas(
        sprites.image,
        _glareTransforms,
        _glareRects,
        _glareColors,
        BlendMode.modulate,
        null,
        Paint()
          ..blendMode = BlendMode.plus
          ..filterQuality = FilterQuality.low,
      );
    }
    final disk = _moonDisk;
    if (disk != null) {
      canvas.drawRect(
        Rect.fromCircle(center: disk.center, radius: disk.radius + 2),
        Paint()..shader = moon,
      );
    }
    final ground = _terrainRect;
    if (ground != null) canvas.drawRect(ground, Paint()..shader = terrain);
    for (final (text, at) in _placed) {
      text.paint(canvas, at);
    }
    _front = recorder.endRecording();
  }

  void _applyTwinkle() {
    final t = seconds;
    final animate = options.twinkle;
    for (var i = 0; i < _count; i++) {
      final b = i * 4;
      var f = 1.0;
      if (animate) {
        final amp = _twinkle[i * 3];
        if (amp > 0) {
          final speed = _twinkle[i * 3 + 1], phase = _twinkle[i * 3 + 2];
          f +=
              amp *
              (0.6 * math.sin(t * speed + phase) +
                  0.4 * math.sin(t * speed * 2.7 + phase * 1.7));
        }
      }
      final a = (_baseColors[b + 3] * f).clamp(0.0, 1.0);
      _colors[i] = _argb(
        a,
        _baseColors[b] * a,
        _baseColors[b + 1] * a,
        _baseColors[b + 2] * a,
      );
    }
  }

  static int _argb(double a, double r, double g, double b) =>
      ((a.clamp(0.0, 1.0) * 255).round() << 24) |
      ((r.clamp(0.0, 1.0) * 255).round() << 16) |
      ((g.clamp(0.0, 1.0) * 255).round() << 8) |
      (b.clamp(0.0, 1.0) * 255).round();

  void _build(Size size, CelestialView view) {
    final eph = _ephemeris!;
    final p = _Projection(view, size);
    final toHorizon = eph.j2000ToHorizon;
    final s = _skySun;
    final sunAlt = eph.sun.horizon.altitude;
    final moonAlt = eph.moon.horizon.altitude;
    final moonlight =
        math.pow(eph.moonIllumination, 1.5) * _smooth(-3, 10, moonAlt);
    final glow = options.lightPollution.clamp(0.0, 1.0);
    _darkness =
        (1 - _smooth(-18, -11, s)) *
        (1 - 0.7 * moonlight) *
        (1 - _smooth(0.05, 0.6, glow));

    // Faintest magnitude the sky lets through.
    // Faintest magnitude the sky lets through: 6.2 under a dark sky, about
    // 2 in a city center, less in twilight and moonlight.
    final dark = 6.2 - 4.2 * glow;
    final limit =
        dark - (dark + 4) * _smooth(-18, 0, s) - 1.6 * moonlight * (1 - glow);

    // With no landscape there is no ground and no air along the horizon:
    // the whole screen is sky, stars below the horizon included.
    final open = options.terrain == 'none';
    final groundModel = open ? null : ground;
    double groundAt(SkyVector h) =>
        open ? -90 : groundModel?.heightAt(h.azimuth) ?? 0;
    double air(double alt) => open ? 1 : airMass(alt);
    final margin = 24.0;
    bool onScreen(Offset o) =>
        o.dx > -margin &&
        o.dy > -margin &&
        o.dx < size.width + margin &&
        o.dy < size.height + margin;

    // Uniforms shared by the sky and the terrain.
    void common(ui.FragmentShader shader) {
      final sun = eph.sun.horizon, moonDir = eph.moon.horizon;
      final values = [
        p.cx, p.cy, p.scale, 1.0, //
        p.right.x, p.right.y, p.right.z, 0,
        p.up.x, p.up.y, p.up.z, 0,
        p.forward.x, p.forward.y, p.forward.z, open ? 1.0 : 0.0,
        sun.x, sun.y, sun.z, sunAlt,
        moonDir.x, moonDir.y, moonDir.z, moonlight.toDouble(),
        options.milkyWay ? _darkness * 0.9 : 0.0,
        options.daytime ? 1.0 : 0.0,
        0.004654 * (options.largeMoon ? 2.0 : 1.0),
        glow,
      ];
      for (var i = 0; i < values.length; i++) {
        shader.setFloat(i, values[i].toDouble());
      }
    }

    common(sky);
    final inverse = toHorizon.transposed.m;
    for (var i = 0; i < 9; i++) {
      // Three vec4 rows after the 28 shared floats.
      sky.setFloat(28 + (i ~/ 3) * 4 + i % 3, inverse[i]);
    }
    for (var row = 0; row < 3; row++) {
      sky.setFloat(28 + row * 4 + 3, 0);
    }
    common(terrain);
    final (nearColor, farColor) = switch (options.terrain) {
      'mountains' => (const [0.10, 0.11, 0.09], const [0.36, 0.38, 0.42]),
      'plains' => (const [0.17, 0.19, 0.08], const [0.22, 0.26, 0.16]),
      'none' => (const [0.12, 0.13, 0.11], const [0.12, 0.13, 0.11]),
      _ => (const [0.10, 0.15, 0.07], const [0.20, 0.27, 0.18]),
    };
    for (var i = 0; i < 3; i++) {
      terrain.setFloat(28 + i, nearColor[i]);
      terrain.setFloat(32 + i, farColor[i]);
    }
    terrain.setFloat(31, 0);
    terrain.setFloat(35, 0);

    // Stars.
    final starCount = catalog.starCount;
    final transforms = <double>[];
    final rects = <double>[];
    final base = <double>[];
    final twinkle = <double>[];
    final glareT = <double>[];
    final glareR = <double>[];
    final glareC = <int>[];
    final labels = <_Label>[];
    // Named stars are candidates brightest first, down to magnitude 3.5 at
    // the default zoom and fainter as the view narrows: the share of the
    // screen each name may take decides how many show. Zoomed in, stars
    // without a name get their Bayer letter or Flamsteed number, like
    // γ Cen, as star charts do.
    final nameLimit = view.fov >= 80 ? 3.5 : 3.5 + (80 - view.fov) / 60 * 2.5;
    final designationLimit = 2.5 + (70 - view.fov) / 50 * 3.5;
    final designations = <_Label>[];
    final random = math.Random(7);

    void addPoint(
      Offset o,
      double magnitude,
      double r,
      double g,
      double b,
      double alt, {
      double twinkleScale = 1,
    }) {
      final flux = math.pow(10, -0.4 * (magnitude - limit)).toDouble();
      if (flux < 0.12) return;
      // Brightness follows the flux closely up to about two and a half
      // magnitudes above the limit; brighter stars grow instead.
      final sigma = 0.65 + 0.7 * math.log(1 + flux) / math.ln10;
      final alpha = (0.35 * math.sqrt(flux)).clamp(0.06, 1.0);
      final scale = sigma / _Sprites.coreSigma;
      transforms.addAll([
        scale,
        0,
        o.dx - _Sprites.cell / 2 * scale,
        o.dy - _Sprites.cell / 2 * scale,
      ]);
      rects.addAll(_Sprites.ltrb(_Sprites.core));
      base.addAll([r, g, b, alpha]);
      final low = 1 - _smooth(5, 45, alt);
      final amp = flux > 4 ? (0.03 + 0.10 * low) * twinkleScale : 0.0;
      twinkle.addAll([
        amp,
        2.5 + random.nextDouble() * 5,
        random.nextDouble() * math.pi * 2,
      ]);
      if (flux > 15) {
        final strength = (0.12 * math.log(flux / 15) / math.ln10 + 0.06).clamp(
          0.0,
          0.5,
        );
        final glareScale =
            (2.5 + 2.4 * math.log(flux / 15) / math.ln10) / 7 * 1.6;
        glareT.addAll([
          glareScale,
          0,
          o.dx - _Sprites.cell / 2 * glareScale,
          o.dy - _Sprites.cell / 2 * glareScale,
        ]);
        glareR.addAll(_Sprites.ltrb(_Sprites.glare));
        glareC.add(_argb(strength, r * strength, g * strength, b * strength));
      }
    }

    for (var i = 0; i < starCount; i++) {
      final m = catalog.magnitudes[i];
      if (m - limit > 2.3) break; // Sorted brightest first.
      var h = toHorizon.apply(
        SkyVector(
          catalog.stars[i * 3],
          catalog.stars[i * 3 + 1],
          catalog.stars[i * 3 + 2],
        ),
      );
      final alt0 = h.altitude;
      if (alt0 < -1 && !open) continue;
      if (alt0 < 15 && alt0 > -1) h = refract(h);
      final alt = h.altitude;
      if (alt < groundAt(h) - 0.3) continue;
      final o = p.project(h);
      if (o == null || !onScreen(o)) continue;
      final extinct = m + 0.25 * (air(alt) - 1);
      addPoint(
        o,
        extinct,
        catalog.colors[i * 3],
        catalog.colors[i * 3 + 1],
        catalog.colors[i * 3 + 2],
        alt,
      );
      if (options.objectNames && extinct < limit - 1.5) {
        final name = catalog.starNames[i];
        if (name != null) {
          if (m <= nameLimit) {
            labels.add(_Label(name, _LabelStyle.star, o, _Align.right));
          }
        } else if (m <= designationLimit) {
          final designation = catalog.starDesignations[i];
          if (designation != null) {
            designations.add(
              _Label(designation, _LabelStyle.designation, o, _Align.right),
            );
          }
        }
      }
    }

    // Planets.
    final planetLabels = <_Label>[];
    if (options.planets) {
      for (final body in const [
        SkyBody.mercury,
        SkyBody.venus,
        SkyBody.mars,
        SkyBody.jupiter,
        SkyBody.saturn,
        SkyBody.uranus,
        SkyBody.neptune,
      ]) {
        final pos = eph.bodies[body]!;
        final h = pos.horizon;
        final alt = h.altitude;
        if (alt < groundAt(h) - 0.3) continue;
        final o = p.project(h);
        if (o == null || !onScreen(o)) continue;
        final (r, g, b) = switch (body) {
          SkyBody.mars => (1.0, 0.72, 0.52),
          SkyBody.jupiter => (1.0, 0.96, 0.88),
          SkyBody.saturn => (1.0, 0.93, 0.76),
          SkyBody.mercury => (0.95, 0.92, 0.88),
          SkyBody.uranus => (0.80, 0.96, 1.0),
          SkyBody.neptune => (0.70, 0.82, 1.0),
          _ => (1.0, 1.0, 0.96),
        };
        final extinct = pos.magnitude + 0.25 * (air(alt) - 1);
        addPoint(o, extinct, r, g, b, alt, twinkleScale: 0.2);
        if (options.objectNames && extinct < limit - 1) {
          final name = names.bodies[body];
          if (name != null) {
            planetLabels.add(_Label(name, _LabelStyle.planet, o, _Align.right));
          }
        }
      }
    }

    _count = base.length ~/ 4;
    _transforms = Float32List.fromList(transforms);
    _rects = Float32List.fromList(rects);
    _baseColors = Float32List.fromList(base);
    _twinkle = Float32List.fromList(twinkle);
    _colors = Int32List(_count);
    _glareTransforms = Float32List.fromList(glareT);
    _glareRects = Float32List.fromList(glareR);
    _glareColors = Int32List.fromList(glareC);

    // Constellation figures, fading out toward the edges of the screen so
    // the figures near the middle read clearly. Each line is cut into short
    // pieces, grouped by how faded they are.
    final lines = [for (var i = 0; i < _lineLevels; i++) <double>[]];
    if (options.lines) {
      for (final c in catalog.constellations) {
        final seg = c.segments;
        for (var i = 0; i < seg.length; i += 6) {
          final a = toHorizon.apply(SkyVector(seg[i], seg[i + 1], seg[i + 2]));
          final b = toHorizon.apply(
            SkyVector(seg[i + 3], seg[i + 4], seg[i + 5]),
          );
          if (a.z < -0.05 && b.z < -0.05 && !open) continue;
          final oa = p.project(a), ob = p.project(b);
          if (oa == null || ob == null) continue;
          if (!onScreen(oa) && !onScreen(ob)) continue;
          // Stop short of each star bright enough to show, so the line
          // leaves it visible. Under a bright sky the line runs on
          // through the stars the glow hides.
          final d = ob - oa;
          final len = d.distance;
          if (len < 8) continue;
          final u = d / len;
          // As wide as the star's sprite, which grows with its flux.
          double gap(double magnitude) {
            final flux = math.pow(10, -0.4 * (magnitude - limit)).toDouble();
            if (flux < 0.25) return 0;
            final sigma = 0.65 + 0.7 * math.log(1 + flux) / math.ln10;
            return math.min(1.5 + 2.2 * sigma, len * 0.25);
          }

          final sa = oa + u * gap(c.ends[i ~/ 3]);
          final sb = ob - u * gap(c.ends[i ~/ 3 + 1]);
          final pieces = math.max(1, ((sb - sa).distance / 24).ceil());
          for (var k = 0; k < pieces; k++) {
            final from = Offset.lerp(sa, sb, k / pieces)!;
            final to = Offset.lerp(sa, sb, (k + 1) / pieces)!;
            final fade = _centerFade((from + to) / 2, size);
            final level = (fade * _lineLevels).ceil();
            if (level <= 0) continue;
            lines[level - 1].addAll([from.dx, from.dy, to.dx, to.dy]);
          }
        }
      }
    }
    _lines = [for (final l in lines) Float32List.fromList(l)];

    // Galaxies and nebulae.
    _glows.clear();
    final deepLabels = <_Label>[];
    if (options.deepSky) {
      for (final d in catalog.deepSky) {
        final h = toHorizon.apply(d.direction);
        final alt = h.altitude;
        if (alt < groundAt(h)) continue;
        final o = p.project(h);
        if (o == null || !onScreen(o)) continue;
        final visibility =
            _darkness * math.exp(-0.25 * (air(alt) - 1)).toDouble();
        if (visibility < 0.05) continue;
        final ppr = p.pixelsPerRadian(o);
        final major = d.major / 60 * math.pi / 180 * ppr;
        final minor = d.minor / 60 * math.pi / 180 * ppr;
        if (d.kind == 'galaxy' || d.kind == 'nebula') {
          // Position angle runs from north toward east. North on screen
          // is where the pole lies.
          final north = _screenNorth(p, h, toHorizon);
          final angle =
              math.atan2(north.dy, north.dx) +
              math.pi / 2 -
              d.angle * math.pi / 180;
          final color = d.kind == 'galaxy'
              ? const Color(0xFFFFF1DC)
              : const Color(0xFFFFB4C8);
          final strength = (d.kind == 'galaxy' ? 0.30 : 0.22) * visibility;
          _glows.add(
            _DeepSkyGlow(
              o,
              math.max(minor * 1.4, 4),
              math.max(major * 1.4, 4),
              angle,
              color.withValues(alpha: strength),
            ),
          );
          if (d.key == 'andromedaGalaxy') {
            _glows.add(
              _DeepSkyGlow(
                o,
                math.max(minor * 0.35, 3),
                math.max(major * 0.35, 3),
                angle,
                color.withValues(alpha: strength * 1.4),
              ),
            );
          }
        }
        if (options.objectNames && visibility > 0.25) {
          final name = names.deepSky[d.key];
          if (name != null) {
            deepLabels.add(_Label(name, _LabelStyle.deepSky, o, _Align.below));
          }
        }
      }
    }

    // The Moon.
    _moonDisk = null;
    final moonLabels = <_Label>[];
    {
      final h = eph.moon.horizon;
      final o = p.project(h);
      final alt = h.altitude;
      if (o != null && alt > groundAt(h) - 1 && onScreen(o)) {
        final ppr = p.pixelsPerRadian(o);
        final angular = math.asin(1737.4 / eph.moon.distance);
        final radius = math.max(
          angular * ppr * (options.largeMoon ? 3 : 1),
          2.5,
        );
        final north = _screenNorth(p, h, toHorizon);
        // In shader space y runs up.
        final nx = north.dx, ny = -north.dy;
        final rotation = math.atan2(-nx, ny);
        final sunDir = eph.sun.horizon;
        final along = sunDir - h * h.dot(sunDir);
        final inPlane = along.length;
        double lx = 0, ly = 0;
        if (inPlane > 1e-6) {
          final tip = p.project((h + along * (0.01 / inPlane)).unit);
          if (tip != null) {
            final dx = tip.dx - o.dx, dy = -(tip.dy - o.dy);
            final l = math.sqrt(dx * dx + dy * dy);
            if (l > 0) {
              lx = dx / l * inPlane;
              ly = dy / l * inPlane;
            }
          }
        }
        final lz = -h.dot(sunDir);
        final illum = eph.moonIllumination;
        final mass = air(math.max(alt, 0));
        final day = _smooth(-5, 10, s);
        moon
          ..setFloat(0, o.dx)
          ..setFloat(1, o.dy)
          ..setFloat(2, radius)
          ..setFloat(3, rotation)
          ..setFloat(4, lx)
          ..setFloat(5, ly)
          ..setFloat(6, lz)
          ..setFloat(7, 0.035 * math.pow(1 - illum, 2) * (1 - day))
          ..setFloat(8, math.exp(-0.10 * (mass - 1)))
          ..setFloat(9, math.exp(-0.22 * (mass - 1)))
          ..setFloat(10, math.exp(-0.40 * (mass - 1)))
          ..setFloat(11, day);
        _moonDisk = _MoonDisk(o, radius);
        final name = names.bodies[SkyBody.moon];
        if (options.objectNames && name != null) {
          moonLabels.add(
            _Label(name, _LabelStyle.moon, o + Offset(radius, 0), _Align.right),
          );
        }
      }
    }

    // The Sun, named beside its disk like the Moon.
    final sunLabels = <_Label>[];
    {
      final h = eph.sun.horizon;
      final o = p.project(h);
      final name = names.bodies[SkyBody.sun];
      if (options.objectNames &&
          name != null &&
          o != null &&
          onScreen(o) &&
          h.altitude > math.max(groundAt(h), -1) - 0.5) {
        final radius =
            0.004654 * (options.largeMoon ? 2 : 1) * p.pixelsPerRadian(o);
        sunLabels.add(
          _Label(
            name,
            _LabelStyle.moon,
            // Clear of the brightest part of the glare.
            o + Offset(radius * 3 + 8, 0),
            _Align.right,
          ),
        );
      }
    }

    // The ground, bounded to where it can show.
    _terrainRect = null;
    if (groundModel != null) {
      var top = double.infinity;
      for (var az = 0.0; az < 360; az += 1) {
        final h = SkyVector.horizon(groundModel.heightAt(az) + 0.2, az);
        final o = p.project(h);
        if (o == null || o.dx < -60 || o.dx > size.width + 60) continue;
        top = math.min(top, o.dy);
      }
      if (view.frame != null) {
        // A device held at any roll can show the ground anywhere on screen.
        _terrainRect = Offset.zero & size;
      } else if (top.isFinite && top < size.height) {
        _terrainRect = Rect.fromLTRB(
          0,
          math.max(0, top - 2),
          size.width,
          size.height,
        );
      } else if (view.altitude < 0) {
        _terrainRect = Offset.zero & size;
      }
    }

    // Constellation names.
    final constellationLabels = <_Label>[];
    if (options.constellationNames) {
      final maxRank = view.fov > 110 ? 2 : 3;
      final fade = 1 - _smooth(-12, -4, s);
      if (fade > 0.05) {
        for (final c in catalog.constellations) {
          if (c.rank > maxRank) continue;
          final h = toHorizon.apply(c.label);
          if (h.altitude < groundAt(h) + 1) continue;
          final o = p.project(h);
          if (o == null || !onScreen(o)) continue;
          final fade = _centerFade(o, size);
          if (fade < 0.1) continue;
          constellationLabels.add(
            _Label(
              c.nameFor(names.language).toUpperCase(),
              _LabelStyle.constellation,
              o,
              _Align.center,
              fade: fade,
            ),
          );
        }
      }
    }

    // Compass points sit on the ground below the horizon, or just under
    // the horizon line with no landscape.
    final compassLabels = <_Label>[];
    if (options.compass && (groundModel != null || open)) {
      for (var k = 0; k < 4; k++) {
        final az = k * 90.0;
        final h = SkyVector.horizon(
          math.min(groundModel?.heightAt(az) ?? 0, 1.5) - 1.6,
          az,
        );
        final o = p.project(h);
        if (o == null || !onScreen(o)) continue;
        compassLabels.add(
          _Label(names.compass[k], _LabelStyle.compass, o, _Align.center),
        );
      }
    }

    // Place labels in priority order, skipping any that would overlap.
    // Star names also share out the screen: it is cut into cells and each
    // takes the brightest one or few, so a crowded Milky Way stays clear
    // and a sparse stretch still gets its brightest stars named. Zooming in
    // allows more per cell.
    _placed.clear();
    _trimTexts();
    final taken = <Rect>[];
    final textScale =
        (size.shortestSide / 700).clamp(0.8, 1.4) * options.labelScale;
    final cell = size.shortestSide / 4.5;
    final perCell = view.fov > 80
        ? 1
        : view.fov > 45
        ? 2
        : 3;
    final starsInCell = <int, int>{};
    for (final label in [
      ...compassLabels,
      ...moonLabels,
      ...sunLabels,
      ...planetLabels,
      ...labels,
      ...deepLabels,
      ...constellationLabels,
      ...designations,
    ]) {
      // A full cell skips the star before its text is laid out.
      final key =
          label.style == _LabelStyle.star ||
              label.style == _LabelStyle.designation
          ? (label.anchor.dx ~/ cell) * 1024 + (label.anchor.dy ~/ cell)
          : null;
      if (key != null && (starsInCell[key] ?? 0) >= perCell) continue;
      final painter = _text(label, textScale, s);
      final w = painter.width, h = painter.height;
      final at = switch (label.align) {
        _Align.right => label.anchor + Offset(7 * textScale, -h / 2),
        _Align.center => label.anchor - Offset(w / 2, h / 2),
        _Align.below => label.anchor + Offset(-w / 2, 6 * textScale),
      };
      final box = (at & Size(w, h)).inflate(3);
      if (taken.any(box.overlaps)) continue;
      if (box.right < 0 ||
          box.bottom < 0 ||
          box.left > size.width ||
          box.top > size.height) {
        continue;
      }
      taken.add(box);
      _placed.add((painter, at));
      if (key != null) starsInCell[key] = (starsInCell[key] ?? 0) + 1;
    }
  }

  /// 1 in the middle of the screen, fading to 0 at its edges.
  static double _centerFade(Offset o, Size size) {
    final dx = (o.dx - size.width / 2) / (size.width / 2);
    final dy = (o.dy - size.height / 2) / (size.height / 2);
    return 1 - _smooth(0.3, 1.0, math.sqrt(dx * dx + dy * dy));
  }

  /// Direction toward the celestial north pole on screen at [h].
  Offset _screenNorth(_Projection p, SkyVector h, SkyMatrix toHorizon) {
    final pole = toHorizon.apply(const SkyVector(0, 0, 1));
    final along = pole - h * h.dot(pole);
    final l = along.length;
    final o = p.project(h);
    if (l < 1e-6 || o == null) return const Offset(0, -1);
    final tip = p.project((h + along * (0.01 / l)).unit);
    if (tip == null) return const Offset(0, -1);
    final d = tip - o;
    return d.distance == 0 ? const Offset(0, -1) : d / d.distance;
  }

  TextPainter _text(_Label label, double scale, double sunAltitude) {
    final night = 1 - _smooth(-10, 2, sunAltitude);
    final (color, size, spacing, weight) = switch (label.style) {
      _LabelStyle.constellation => (
        Color.fromRGBO(
          150,
          172,
          225,
          0.62 * night * (label.fade * 10).round() / 10,
        ),
        11.5,
        1.6,
        FontWeight.w400,
      ),
      _LabelStyle.star => (
        Color.fromRGBO(225, 230, 240, 0.72),
        12.0,
        0.2,
        FontWeight.w400,
      ),
      _LabelStyle.designation => (
        Color.fromRGBO(225, 230, 240, 0.5),
        11.0,
        0.2,
        FontWeight.w400,
      ),
      _LabelStyle.planet => (
        const Color.fromRGBO(255, 222, 170, 0.9),
        13.0,
        0.3,
        FontWeight.w500,
      ),
      _LabelStyle.moon => (
        const Color.fromRGBO(240, 240, 235, 0.85),
        13.0,
        0.3,
        FontWeight.w500,
      ),
      _LabelStyle.deepSky => (
        Color.fromRGBO(190, 200, 225, 0.6 * night),
        11.0,
        0.3,
        FontWeight.w400,
      ),
      _LabelStyle.compass => (
        const Color.fromRGBO(255, 255, 255, 0.8),
        16.0,
        0.5,
        FontWeight.w600,
      ),
    };
    final key =
        '${label.style.index}|${label.text}|${scale.toStringAsFixed(2)}|'
        '${color.toARGB32()}';
    _textsUsed.add(key);
    final cached = _texts[key];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(
        text: label.text,
        style: TextStyle(
          // A painter does not inherit the app's theme font.
          fontFamily: 'Rubik',
          color: color,
          fontSize: size * scale,
          letterSpacing: spacing * scale,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return _texts[key] = painter;
  }
}

class _DeepSkyGlow {
  _DeepSkyGlow(this.center, this.width, this.height, this.angle, this.color);
  final Offset center;
  final double width, height, angle;
  final Color color;
}

class _MoonDisk {
  _MoonDisk(this.center, this.radius);
  final Offset center;
  final double radius;
}
