import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'assist_art.dart';

/// The HAL 9000 skin's indicator: HAL's eye from 2001: A Space Odyssey. A
/// fisheye lens in a polished chrome ring and a black barrel, its glass
/// lit from within by a red light with a hot yellow center. The light
/// flares with the voice and the answer, its center swelling and its red
/// filling the glass and spilling onto the chrome, pulses while the
/// assistant thinks and dims at rest. The lens, its metal and the reflections on its
/// glass are an image drawn once, and the light is a few gradients added
/// over it each frame, so a frame costs one image draw and no blur.
class HalArt extends StatefulWidget {
  const HalArt({
    super.key,
    required this.mode,
    required this.reactive,
    required this.level,
    required this.clock,
    this.compact = false,
    this.countdown,
    this.box,
  });

  final ArtMode mode;

  /// Listening or speaking with the reactive bar on: the light follows
  /// [level]. Otherwise it runs the mode's own animation.
  final bool reactive;
  final ValueListenable<double> level;
  final ArtClock clock;

  /// Docked over the dashboard: the eye sits on a dark disc that fills its
  /// box.
  final bool compact;

  /// 1 down to 0 as a docked conversation ends: a red ring around the
  /// chrome unwinds with it.
  final ValueListenable<double>? countdown;

  /// Where the eye goes, in the widget's own coordinates. Null fills the
  /// widget.
  final Rect? box;

  @override
  State<HalArt> createState() => _HalArtState();
}

class _HalArtState extends State<HalArt> {
  /// The light's strength as drawn, eased toward its target every frame so
  /// a change of mode glides.
  double _glow = 0.6;

  /// How hard the voice drives the light (0 to 1) as drawn: quick to rise,
  /// slower to fall, so each syllable flares and fades.
  double _pulse = 0;
  double _last = -1;

  /// The loudest recent level while listening and while speaking, each
  /// decaying, as the Voice Only mark scales them.
  double _micPeak = 0;
  double _playPeak = 0;

  /// The lens with its metal and reflections, drawn at [_facePx] pixels
  /// per artboard unit.
  ui.Image? _face;
  double _facePx = 0;

  /// The face at about [px] pixels per artboard unit. A small change of
  /// size keeps the one already drawn.
  ui.Image face(double px) {
    final current = _face;
    if (current != null && px <= _facePx * 1.15 && px >= _facePx / 1.5) {
      return current;
    }
    current?.dispose();
    _facePx = px;
    return _face = _HalPainter.bake(px);
  }

  @override
  void dispose() {
    _face?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _HalPainter(this, MediaQuery.devicePixelRatioOf(context)),
    ),
  );
}

class _HalPainter extends CustomPainter {
  _HalPainter(this.state, this.pixelRatio)
    : super(
        repaint: Listenable.merge([
          state.widget.level,
          state.widget.clock,
          state.widget.countdown,
        ]),
      );

  final _HalArtState state;
  final double pixelRatio;
  HalArt get w => state.widget;

  /// The artboard, in design units from the eye's center: the chrome ring
  /// out to [_rim], the black barrel inside it, then the glass.
  static const _rim = 1000.0;
  static const _chromeInner = 815.0;
  static const _barrelStep = 742.0;
  static const _retainer = 662.0;
  static const _glass = 640.0;

  /// How far the box reaches past the chrome: room for the countdown ring.
  static const _reach = 1.1;

  static const _red = Color(0xFFFF1E0A);

  static Rect _circle(double r, [Offset c = Offset.zero]) =>
      Rect.fromCircle(center: c, radius: r);

  static double _rad(double degrees) => degrees * math.pi / 180;

  /// A band of a ring between [inner] and [outer], [sweep] degrees from
  /// [start].
  static Path _sector(double inner, double outer, double start, double sweep) =>
      Path()
        ..arcTo(_circle(outer), _rad(start), _rad(sweep), true)
        ..arcTo(_circle(inner), _rad(start + sweep), _rad(-sweep), false)
        ..close();

  /// A ring between [inner] and [outer].
  static Path _ring(double inner, double outer) => Path()
    ..fillType = PathFillType.evenOdd
    ..addOval(_circle(outer))
    ..addOval(_circle(inner));

  static Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color;

  /// A radial gradient over [inner] to [outer] from the center, with
  /// [stops] given in artboard units rather than fractions.
  static Shader _radial(
    double outer,
    List<Color> colors,
    List<double> stops, {
    Offset center = Offset.zero,
  }) => ui.Gradient.radial(center, outer, colors, [
    for (final s in stops) (s / outer).clamp(0.0, 1.0),
  ]);

  /// Polished chrome turned on a lathe, as a sweep of the room's light
  /// around the ring: bright toward the top left where the studio lights
  /// hang, dark toward the floor, with sharp bands where the ring's curve
  /// catches the edges of things.
  static const _chromeSweep = [
    (0.00, Color(0xFF7A7D82)),
    (0.06, Color(0xFF3A3C40)),
    (0.14, Color(0xFF1E1F22)),
    (0.22, Color(0xFF55585D)),
    (0.27, Color(0xFFB9BCC1)),
    (0.30, Color(0xFF5E6166)),
    (0.38, Color(0xFF2A2B2E)),
    (0.47, Color(0xFF6F7277)),
    (0.55, Color(0xFFD5D8DC)),
    (0.585, Color(0xFFFFFFFF)),
    (0.61, Color(0xFFE2E4E7)),
    (0.66, Color(0xFF9A9DA2)),
    (0.71, Color(0xFFF2F3F5)),
    (0.76, Color(0xFFC4C7CB)),
    (0.82, Color(0xFF8C8F94)),
    (0.88, Color(0xFFB4B7BC)),
    (0.94, Color(0xFF6A6D72)),
    (1.00, Color(0xFF7A7D82)),
  ];

  /// The eye at [px] pixels per artboard unit, everything but its light:
  /// the chrome, the barrel, the dark glass and the reflections on it.
  /// The light is added over it each frame, and adding light commutes, so
  /// it reads as lighting the glass from behind.
  static ui.Image bake(double px) {
    final recorder = ui.PictureRecorder();
    final side = (2 * _rim * px).ceil();
    final canvas = Canvas(recorder)
      ..translate(side / 2, side / 2)
      ..scale(px);

    /// A soft shape: blurred in pixels with no scale applied, so both
    /// renderers agree on the blur.
    void soft(Path path, Paint paint, double sigma) {
      canvas.save();
      canvas.scale(1 / px);
      canvas.drawPath(
        path.transform(Matrix4.diagonal3Values(px, px, 1).storage),
        paint..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma * px),
      );
      canvas.restore();
    }

    // The chrome: the sweep of the room around the ring, then its profile
    // across the width, a rounded lip outside falling to a flat face and a
    // sharp bright bevel into the barrel.
    canvas.drawCircle(Offset.zero, _rim, Paint()..color = Colors.black);
    canvas.drawPath(
      _ring(_chromeInner, _rim - 6),
      Paint()
        ..shader = SweepGradient(
          transform: const GradientRotation(-math.pi / 2),
          colors: [for (final (_, c) in _chromeSweep) c],
          stops: [for (final (s, _) in _chromeSweep) s],
        ).createShader(_circle(_rim)),
    );
    canvas.drawPath(
      _ring(_chromeInner, _rim - 6),
      Paint()
        ..shader = _radial(
          _rim,
          const [
            Color(0x66000000),
            Color(0x1AFFFFFF),
            Color(0x00000000),
            Color(0x26000000),
            Color(0x00000000),
            Color(0x40FFFFFF),
            Color(0x00FFFFFF),
            Color(0x33000000),
            Color(0xB3000000),
          ],
          const [815, 825, 845, 880, 925, 958, 975, 988, 994],
        ),
    );
    // The lathe's fine turning marks, from a fixed seed.
    final random = math.Random(9000);
    for (var i = 0; i < 260; i++) {
      final r = _chromeInner + 4 + random.nextDouble() * (_rim - 14 - 819);
      final light = random.nextBool();
      canvas.drawCircle(
        Offset.zero,
        r,
        _stroke(
          (light ? Colors.white : Colors.black).withValues(
            alpha: 0.015 + random.nextDouble() * (light ? 0.035 : 0.05),
          ),
          0.8 + random.nextDouble() * 1.6,
        ),
      );
    }
    // Hard edges: a bright line where the lip turns toward the lights, the
    // dark seam at the barrel.
    canvas.drawCircle(
      Offset.zero,
      _rim - 8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..shader = SweepGradient(
          transform: const GradientRotation(-math.pi / 2),
          colors: const [
            Color(0x10FFFFFF),
            Color(0x10FFFFFF),
            Color(0xCCFFFFFF),
            Color(0x10FFFFFF),
            Color(0x10FFFFFF),
          ],
          stops: const [0, 0.48, 0.6, 0.75, 1],
        ).createShader(_circle(_rim)),
    );
    canvas.drawCircle(
      Offset.zero,
      _chromeInner + 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..shader = SweepGradient(
          transform: const GradientRotation(-math.pi / 2),
          colors: const [
            Color(0xFFE6E8EB),
            Color(0xFF6B6E73),
            Color(0xFF2B2C2F),
            Color(0xFF6B6E73),
            Color(0xFFE6E8EB),
          ],
          stops: const [0, 0.25, 0.5, 0.75, 1],
        ).createShader(_circle(_rim)),
    );
    canvas.drawCircle(Offset.zero, _chromeInner - 2, _stroke(Colors.black, 6));

    // The barrel: matte black anodizing in two steps, the outer face
    // lifting a little toward the lights, with the lens's engraved ring
    // of fine ticks.
    canvas.drawPath(
      _ring(_barrelStep, _chromeInner - 4),
      Paint()
        ..shader = _radial(
          _chromeInner,
          const [Color(0xFF0B0B0C), Color(0xFF17181A), Color(0xFF0A0A0B)],
          const [_barrelStep, 780, _chromeInner],
        ),
    );
    canvas.drawPath(
      _ring(_barrelStep, _chromeInner - 4),
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(-600, -600),
          const Offset(600, 600),
          const [Color(0x1FFFFFFF), Color(0x00FFFFFF), Color(0x14000000)],
          const [0, 0.5, 1],
        ),
    );
    final ticks = Path();
    for (var i = 0; i < 180; i++) {
      final a = _rad(i * 2.0);
      final (inner, outer) = i % 5 == 0 ? (772.0, 798.0) : (782.0, 794.0);
      ticks
        ..moveTo(inner * math.cos(a), inner * math.sin(a))
        ..lineTo(outer * math.cos(a), outer * math.sin(a));
    }
    canvas.drawPath(ticks, _stroke(const Color(0x14FFFFFF), 2));
    // The step down into the inner barrel: lit on its upper left edge,
    // in shadow under it.
    canvas.drawCircle(
      Offset.zero,
      _barrelStep + 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..shader = ui.Gradient.linear(
          const Offset(-520, -520),
          const Offset(520, 520),
          const [Color(0x80FFFFFF), Color(0x0DFFFFFF), Color(0x00FFFFFF)],
          const [0, 0.45, 1],
        ),
    );
    canvas.drawPath(
      _ring(_retainer, _barrelStep),
      Paint()
        ..shader = _radial(
          _barrelStep,
          const [Color(0xFF050505), Color(0xFF101011), Color(0xFF030303)],
          const [_retainer, 700, _barrelStep],
        ),
    );
    // The ring that holds the glass: a thin bright edge of metal.
    canvas.drawPath(
      _ring(_glass, _retainer),
      Paint()
        ..shader = SweepGradient(
          transform: const GradientRotation(-math.pi / 2),
          colors: const [
            Color(0xFF55585C),
            Color(0xFF1C1D1F),
            Color(0xFF0E0E0F),
            Color(0xFF2E3033),
            Color(0xFFB8BBBF),
            Color(0xFF55585C),
          ],
          stops: const [0, 0.25, 0.4, 0.55, 0.65, 1],
        ).createShader(_circle(_rim)),
    );
    canvas.drawCircle(Offset.zero, _glass + 1, _stroke(Colors.black, 3));

    // The glass: near black, a deep red left in its middle even unlit,
    // and the edges of the lens's inner elements as faint rings.
    canvas.drawCircle(
      Offset.zero,
      _glass,
      Paint()
        ..shader = _radial(
          _glass,
          const [
            Color(0xFF1A0202),
            Color(0xFF0C0101),
            Color(0xFF040000),
            Color(0xFF000000),
          ],
          const [0, 220, 450, _glass],
        ),
    );
    for (final (r, a) in const [(560.0, 0.05), (455.0, 0.04), (330.0, 0.03)]) {
      canvas.drawCircle(
        Offset.zero,
        r,
        _stroke(Colors.white.withValues(alpha: a), 2),
      );
    }
    // Dust on the glass, from a fixed seed.
    for (var i = 0; i < 140; i++) {
      final a = random.nextDouble() * 2 * math.pi;
      final r = math.sqrt(random.nextDouble()) * (_glass - 30);
      canvas.drawCircle(
        Offset(r * math.cos(a), r * math.sin(a)),
        0.8 + random.nextDouble() * 1.8,
        Paint()
          ..color = Colors.white.withValues(
            alpha: 0.03 + random.nextDouble() * 0.07,
          ),
      );
    }

    // The dome's reflections: a broad soft sheen from the top left, the
    // window of studio lights caught bright in it, a thin crescent along
    // the upper edge where the dome turns away and a faint bounce from
    // the floor at the bottom right.
    canvas.drawCircle(
      Offset.zero,
      _glass,
      Paint()
        ..shader = _radial(
          560,
          const [Color(0x1FFFFFFF), Color(0x08FFFFFF), Color(0x00FFFFFF)],
          const [0, 250, 560],
          center: const Offset(-210, -250),
        ),
    );
    final crescent = Path.combine(
      PathOperation.difference,
      Path()..addOval(_circle(_glass - 22)),
      Path()..addOval(_circle(_glass - 30, const Offset(38, 52))),
    );
    soft(
      crescent,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(-0.75 * _glass * px, -0.75 * _glass * px),
          Offset(0.1 * _glass * px, 0.15 * _glass * px),
          const [Color(0x99FFFFFF), Color(0x26FFFFFF), Color(0x00FFFFFF)],
          const [0, 0.45, 1],
        ),
      5,
    );
    // The studio's softbox, bent along the dome, the brightest thing on
    // the glass: a soft band with a hotter streak inside it.
    soft(
      _sector(452, 548, 203, 44),
      Paint()..color = const Color(0x4DFFFFFF),
      16,
    );
    soft(
      _sector(478, 522, 208, 34),
      Paint()..color = const Color(0xB3FFFFFF),
      5,
    );
    // The chrome, mirrored small in the glass near its upper edge.
    soft(
      Path()..addArc(_circle(_glass - 52), _rad(190), _rad(150)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = const Color(0x1FFFFFFF),
      4,
    );
    soft(
      Path()..addOval(
        Rect.fromCenter(
          center: const Offset(-150, -205),
          width: 46,
          height: 20,
        ),
      ),
      Paint()..color = const Color(0x8CFFFFFF),
      4,
    );
    soft(
      Path()..addArc(_circle(_glass - 40), _rad(15), _rad(70)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = const Color(0x1AFFFFFF),
      8,
    );
    // The glass darkens toward its edge, where it turns from the viewer.
    canvas.drawCircle(
      Offset.zero,
      _glass,
      Paint()
        ..shader = _radial(
          _glass,
          const [Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
          const [0, 520, _glass],
        ),
    );

    final picture = recorder.endRecording();
    final image = picture.toImageSync(side, side);
    picture.dispose();
    return image;
  }

  /// The level against its source's recent peak: a peak decays to half in
  /// about two seconds, and the gain stops at 4x so room noise stays low.
  double _scaled(double dt) {
    final l = w.level.value.clamp(0.0, 1.0);
    final decay = math.exp(-0.35 * dt);
    final speaking = w.mode == ArtMode.speaking;
    final peak = math.max(
      l,
      (speaking ? state._playPeak : state._micPeak) * decay,
    );
    if (speaking) {
      state._playPeak = peak;
    } else {
      state._micPeak = peak;
    }
    return (l * math.min(4.0, 0.9 / math.max(peak, 0.1))).clamp(0.0, 1.0);
  }

  /// The light's steady strength for the mode: about 0.6 at rest and
  /// near 1 through a conversation.
  double _glowTarget(double t) => switch (w.mode) {
    ArtMode.idle => 0.6 + 0.04 * math.sin(2 * math.pi * t / 4),
    ArtMode.thinking => 0.85,
    ArtMode.listening || ArtMode.speaking => 0.9,
  };

  /// How hard the voice drives the light, 0 to 1. Without a level to
  /// follow the answer still flares, and thinking pulses slowly.
  double _pulseTarget(double t, double l) {
    switch (w.mode) {
      case ArtMode.idle:
        return 0;
      case ArtMode.thinking:
        return 0.3 * (0.5 + 0.5 * math.sin(2 * math.pi * t / 1.2));
      case ArtMode.listening || ArtMode.speaking when w.reactive:
        // Lifted so a quiet voice still shows.
        return math.pow(l, 0.6).toDouble();
      case ArtMode.speaking:
        final beat =
            0.5 + 0.5 * math.sin(2 * math.pi * 2.3 * t) * math.sin(2.9 * t);
        return 0.25 + 0.55 * beat;
      case ArtMode.listening:
        return 0.08 + 0.05 * math.sin(2 * math.pi * t / 2.4);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final watch = Stopwatch()..start();
    final t = w.clock.seconds;
    final dt = state._last < 0 ? 1.0 : (t - state._last).clamp(0.0, 0.1);
    state._last = t;
    final l = w.reactive ? _scaled(dt) : 0.0;
    state._glow += (_glowTarget(t) - state._glow) * (1 - math.exp(-5 * dt));
    final target = _pulseTarget(t, l).clamp(0.0, 1.0);
    // About 30 ms to rise and 110 to fall most of the way.
    final rate = target > state._pulse ? 35.0 : 9.0;
    state._pulse += (target - state._pulse) * (1 - math.exp(-rate * dt));
    final g = state._glow.clamp(0.0, 1.0);
    final p = state._pulse.clamp(0.0, 1.0);

    final area = w.box ?? Offset.zero & size;
    final radius = math.min(area.width, area.height) / 2 / _reach;
    if (radius <= 0) return;
    final scale = radius / _rim;
    canvas.save();
    canvas.translate(area.center.dx, area.center.dy);
    canvas.scale(scale);

    // Docked over the dashboard, it sits on a disc of the bubble's dark.
    if (w.compact) {
      canvas.drawCircle(
        Offset.zero,
        _rim * _reach,
        Paint()..color = const Color(0xF0080202),
      );
    }

    final face = state.face((scale * pixelRatio).clamp(0.1, 3.0));
    final k = 2 * _rim / face.width;
    canvas.drawImageRect(
      face,
      Offset.zero & Size(face.width.toDouble(), face.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: face.width * k,
        height: face.height * k,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );

    // The light, added over the glass: a red that fills more of the lens
    // as the voice drives it and fades before its edge, the faint rings of
    // the inner elements it catches, a hot yellow center that swells from
    // a point to a blaze, and its spill onto the ring that holds the glass
    // and, when loud, the chrome.
    final add = Paint()..blendMode = BlendMode.plus;
    final a = math.min(1.0, g + 0.4 * p);
    double grow(double rest, double loud) => rest + (loud - rest) * p;
    canvas.drawCircle(
      Offset.zero,
      _glass,
      add
        ..shader = _radial(
          _glass,
          [
            const Color(0xFFFF3A12).withValues(alpha: a),
            const Color(0xFFF01405).withValues(alpha: 0.95 * a),
            const Color(0xFFB80000).withValues(alpha: 0.8 * a),
            const Color(0xFF6A0000).withValues(alpha: 0.55 * a),
            const Color(0xFF320000).withValues(alpha: 0.45 * a),
            const Color(0x00000000),
          ],
          [
            0,
            grow(80, 200),
            grow(200, 380),
            grow(340, 520),
            grow(500, 610),
            grow(620, _glass),
          ],
        ),
    );
    for (final (r, alpha) in const [
      (165.0, 0.22),
      (290.0, 0.14),
      (455.0, 0.1),
      (560.0, 0.08),
    ]) {
      final lit = alpha * a * (1 + 1.5 * p);
      canvas.drawCircle(
        Offset.zero,
        r,
        _stroke(_red.withValues(alpha: math.min(1, 0.25 * lit)), 40)
          ..blendMode = BlendMode.plus,
      );
      canvas.drawCircle(
        Offset.zero,
        r,
        _stroke(_red.withValues(alpha: math.min(1, 0.5 * lit)), 3)
          ..blendMode = BlendMode.plus,
      );
    }
    final core = grow(90, 400);
    canvas.drawCircle(
      Offset.zero,
      core,
      add
        ..shader = _radial(
          core,
          [
            const Color(0xFFFFFBE0).withValues(alpha: a),
            const Color(0xFFFFE070).withValues(alpha: 0.95 * a),
            const Color(0xFFFF8A1A).withValues(alpha: 0.75 * a),
            const Color(0xFFFF3008).withValues(alpha: 0.35 * a),
            const Color(0x00000000),
          ],
          [
            0,
            core * grow(0.16, 0.3),
            core * grow(0.38, 0.55),
            core * grow(0.7, 0.78),
            core,
          ],
        ),
    );
    // A loud voice blooms the whole glass and throws red onto the metal.
    if (p > 0.01) {
      canvas.drawCircle(
        Offset.zero,
        _glass,
        add
          ..shader = _radial(
            _glass,
            [
              const Color(0xFFFF5A20).withValues(alpha: 0.55 * p),
              const Color(0xFFFF1E0A).withValues(alpha: 0.35 * p),
              const Color(0xFFC00800).withValues(alpha: 0.18 * p),
              const Color(0x00000000),
            ],
            const [0, 220, 480, _glass],
          ),
      );
      canvas.drawCircle(
        Offset.zero,
        _rim,
        add
          ..shader = _radial(
            _rim,
            [
              const Color(0x00000000),
              const Color(0xFFFF1E0A).withValues(alpha: 0.3 * p),
              const Color(0xFFFF1E0A).withValues(alpha: 0.1 * p),
              const Color(0xFFFF1E0A).withValues(alpha: 0.12 * p),
              const Color(0x00000000),
            ],
            const [
              _glass - 10,
              _glass + 8,
              _barrelStep,
              _chromeInner + 20,
              _rim,
            ],
          ),
      );
    }
    canvas.drawCircle(
      Offset.zero,
      _barrelStep,
      add
        ..shader = _radial(
          _barrelStep,
          [
            const Color(0x00000000),
            const Color(0xFFB01000).withValues(alpha: 0.22 * a),
            const Color(0xFFB01000).withValues(alpha: 0.05 * a),
            const Color(0x00000000),
          ],
          const [_glass, _glass + 6, _retainer + 10, _barrelStep],
        ),
    );

    // Docked, a red ring around the chrome unwinds as the conversation
    // ends.
    final countdown = w.countdown;
    if (w.compact && countdown != null) {
      final left = countdown.value.clamp(0.0, 1.0);
      const r = (_rim + _rim * _reach) / 2;
      canvas.drawCircle(
        Offset.zero,
        r,
        _stroke(_red.withValues(alpha: 0.2), 18),
      );
      if (left > 0) {
        canvas.drawArc(
          _circle(r),
          -math.pi / 2,
          2 * math.pi * left,
          false,
          _stroke(_red, 18)..strokeCap = StrokeCap.round,
        );
      }
    }
    canvas.restore();
    ArtCost.paint(watch);
  }

  @override
  bool shouldRepaint(_HalPainter old) => true;
}
