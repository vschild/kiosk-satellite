import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/led/led_scene.dart';

/// The status light frames (LedManager): any number of lights, every
/// effect, brightness applied last.
void main() {
  const blue = 0x0000FF;
  const cyan = 0x00C8FF;

  LedScene scene(
    LedEffect effect, {
    double brightness = 1,
    double fraction = 1,
  }) => LedScene(
    name: 'test',
    effect: effect,
    color: blue,
    accent: cyan,
    brightness: brightness,
    fraction: fraction,
  );

  test('colors read from the settings', () {
    expect(parseRgb('0,200,255'), cyan);
    expect(parseRgb(' 255 , 0 , 0 '), 0xFF0000);
    expect(parseRgb('999,0,-4'), 0xFF0000);
    expect(parseRgb('nope', fallback: 1), 1);
  });

  test('solid fills every light and brightness scales it', () {
    expect(
      renderLedFrame(scene(LedEffect.solid), pixels: 12),
      List.filled(12, blue),
    );
    expect(
      renderLedFrame(scene(LedEffect.solid, brightness: 0.5), pixels: 3),
      List.filled(3, 0x000080),
    );
  });

  test('the listening arc covers a quarter of the row', () {
    final frame = renderLedFrame(scene(LedEffect.arc), pixels: 12);
    expect(frame.where((c) => c == cyan), hasLength(3));
    expect(frame.where((c) => c == blue), hasLength(9));
  });

  test('a spin goes round once a second', () {
    final start = renderLedFrame(scene(LedEffect.spin), pixels: 12);
    final half = renderLedFrame(
      scene(LedEffect.spin),
      pixels: 12,
      t: const Duration(milliseconds: 500),
    );
    final again = renderLedFrame(
      scene(LedEffect.spin),
      pixels: 12,
      t: const Duration(seconds: 1),
    );
    expect(half, isNot(start));
    expect(again, start);
  });

  test('a chase alternates the two colors and steps', () {
    final a = renderLedFrame(scene(LedEffect.chase), pixels: 4);
    final b = renderLedFrame(
      scene(LedEffect.chase),
      pixels: 4,
      t: const Duration(milliseconds: 150),
    );
    expect(a, [blue, cyan, blue, cyan]);
    expect(b, [cyan, blue, cyan, blue]);
  });

  test('a pulse starts dim and peaks halfway', () {
    final dim = renderLedFrame(scene(LedEffect.pulse), pixels: 1).single;
    final peak = renderLedFrame(
      scene(LedEffect.pulse),
      pixels: 1,
      t: const Duration(milliseconds: 600),
    ).single;
    expect(dim & 0xFF, lessThan(peak & 0xFF));
    expect(peak, blue);
  });

  test('a countdown lights its share of the row', () {
    final frame = renderLedFrame(
      scene(LedEffect.countdown, fraction: 0.5),
      pixels: 12,
    );
    expect(frame.take(6), everyElement(blue));
    expect(frame.skip(6), everyElement(0));
  });

  test('works for any number of lights', () {
    for (final effect in LedEffect.values) {
      for (final pixels in [1, 5, 24]) {
        expect(
          renderLedFrame(
            scene(effect),
            pixels: pixels,
            t: const Duration(milliseconds: 333),
          ),
          hasLength(pixels),
          reason: '$effect x $pixels',
        );
      }
    }
  });

  test('still poses show each effect at its most telling moment', () {
    final pulse = renderLedFrame(
      scene(LedEffect.pulse),
      pixels: 1,
      t: ledStillPose(LedEffect.pulse),
    );
    expect(pulse.single, blue);
    final blend = renderLedFrame(
      scene(LedEffect.blend),
      pixels: 1,
      t: ledStillPose(LedEffect.blend),
    );
    expect(blend.single, cyan);
    final orbit = renderLedFrame(
      scene(LedEffect.orbit),
      pixels: 12,
      t: ledStillPose(LedEffect.orbit),
    );
    expect(orbit.first, cyan);
    expect(orbit[6], blue);
  });

  test('only moving effects animate', () {
    expect(scene(LedEffect.solid).animated, isFalse);
    expect(scene(LedEffect.arc).animated, isFalse);
    expect(scene(LedEffect.countdown).animated, isFalse);
    expect(scene(LedEffect.spin).animated, isTrue);
    expect(scene(LedEffect.breathe).animated, isTrue);
  });
}
