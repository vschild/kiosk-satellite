import 'dart:math' as math;

/// What the status lights show, and how it moves (LedManager picks one at a
/// time). Rendered for any number of lights by [renderLedFrame], so a new
/// device needs no new effects.
enum LedEffect {
  /// Every light in [LedScene.color].
  solid,

  /// The whole row fades slowly in and out.
  breathe,

  /// The whole row fades quickly in and out.
  pulse,

  /// [LedScene.color] with an arc of [LedScene.accent] standing still.
  arc,

  /// A dim [LedScene.color] with an arc of [LedScene.accent] going round.
  spin,

  /// [LedScene.color] at full with an arc of [LedScene.accent] going round.
  orbit,

  /// [LedScene.color] and [LedScene.accent] alternating and stepping round.
  chase,

  /// The row fades between [LedScene.color] and [LedScene.accent].
  blend,

  /// Lit up to [LedScene.fraction] of the row, the rest dark.
  countdown,
}

/// One color as 0xRRGGBB.
typedef Rgb = int;

class LedScene {
  const LedScene({
    required this.name,
    required this.effect,
    required this.color,
    this.accent,
    this.brightness = 1,
    this.fraction = 1,
  });

  /// What it is for, for the log and the remote admin: `voice_listening`.
  final String name;
  final LedEffect effect;
  final Rgb color;
  final Rgb? accent;

  /// 0..1, applied to every light.
  final double brightness;

  /// For [LedEffect.countdown]: the share of the row still lit.
  final double fraction;

  /// Whether the frame changes over time at a steady pace.
  bool get animated => switch (effect) {
    LedEffect.solid || LedEffect.arc || LedEffect.countdown => false,
    _ => true,
  };

  @override
  bool operator ==(Object other) =>
      other is LedScene &&
      other.name == name &&
      other.effect == effect &&
      other.color == color &&
      other.accent == accent &&
      other.brightness == brightness &&
      other.fraction == fraction;

  @override
  int get hashCode =>
      Object.hash(name, effect, color, accent, brightness, fraction);
}

/// The moment of [effect] that stands for it on lights that cannot
/// animate (LedDevice.animates): a pulse at its brightest, an arc where it
/// starts, a fade at its accent.
Duration ledStillPose(LedEffect effect) => switch (effect) {
  LedEffect.breathe => const Duration(milliseconds: 1500),
  LedEffect.pulse => const Duration(milliseconds: 600),
  LedEffect.blend => const Duration(milliseconds: 700),
  _ => Duration.zero,
};

/// "r,g,b" as stored by the color settings, or [fallback] when unreadable.
Rgb parseRgb(String value, {Rgb fallback = 0xFFFFFF}) {
  final parts = value.split(',');
  if (parts.length != 3) return fallback;
  final c = [for (final p in parts) int.tryParse(p.trim())];
  if (c.any((v) => v == null)) return fallback;
  int ch(int v) => v.clamp(0, 255);
  return (ch(c[0]!) << 16) | (ch(c[1]!) << 8) | ch(c[2]!);
}

Rgb _scale(Rgb c, double f) {
  final k = f.clamp(0.0, 1.0);
  int ch(int shift) => (((c >> shift) & 0xFF) * k).round();
  return (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

Rgb _mix(Rgb a, Rgb b, double t) {
  final k = t.clamp(0.0, 1.0);
  int ch(int shift) {
    final x = (a >> shift) & 0xFF;
    final y = (b >> shift) & 0xFF;
    return (x + (y - x) * k).round();
  }

  return (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// 0..1 and back over [period], starting dark.
double _wave(Duration t, Duration period) =>
    0.5 -
    0.5 * math.cos(2 * math.pi * t.inMicroseconds / period.inMicroseconds);

/// One frame of [scene] at [t] since it started, [pixels] lights long.
List<Rgb> renderLedFrame(
  LedScene scene, {
  required int pixels,
  Duration t = Duration.zero,
}) {
  final accent = scene.accent ?? scene.color;
  // An arc covers a quarter of the row, at least one light.
  final arcLength = math.max(1, (pixels / 4).round());
  final List<Rgb> frame;
  switch (scene.effect) {
    case LedEffect.solid:
      frame = List.filled(pixels, scene.color);
    case LedEffect.breathe:
      final f = 0.15 + 0.85 * _wave(t, const Duration(milliseconds: 3000));
      frame = List.filled(pixels, _scale(scene.color, f));
    case LedEffect.pulse:
      final f = 0.2 + 0.8 * _wave(t, const Duration(milliseconds: 1200));
      frame = List.filled(pixels, _scale(scene.color, f));
    case LedEffect.arc:
      frame = [
        for (var i = 0; i < pixels; i++) i < arcLength ? accent : scene.color,
      ];
    case LedEffect.spin || LedEffect.orbit:
      // One turn a second, the arc's tail fading into the base behind its
      // head. Spin dims the base so the arc stands out on its own.
      final base = scene.effect == LedEffect.spin
          ? _scale(scene.color, 0.3)
          : scene.color;
      final head = (t.inMilliseconds % 1000) / 1000 * pixels;
      frame = [
        for (var i = 0; i < pixels; i++)
          () {
            final behind = (head - i) % pixels;
            if (behind < arcLength) {
              return _mix(accent, base, behind / arcLength);
            }
            return base;
          }(),
      ];

    case LedEffect.chase:
      final step = t.inMilliseconds ~/ 150;
      frame = [
        for (var i = 0; i < pixels; i++)
          (i + step).isEven ? scene.color : accent,
      ];
    case LedEffect.blend:
      final f = _wave(t, const Duration(milliseconds: 1400));
      frame = List.filled(pixels, _mix(scene.color, accent, f));
    case LedEffect.countdown:
      final lit = scene.fraction.clamp(0.0, 1.0) * pixels;
      frame = [
        for (var i = 0; i < pixels; i++)
          i < lit.floor()
              ? scene.color
              : i == lit.floor()
              ? _scale(scene.color, lit - lit.floor())
              : 0,
      ];
  }
  if (scene.brightness >= 1) return frame;
  return [for (final c in frame) _scale(c, scene.brightness)];
}
