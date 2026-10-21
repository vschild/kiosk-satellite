import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_container.dart';
import '../l10n/messages.dart';
import '../managers/settings/definitions.dart' as defs;
import 'calendar_overlay.dart' show calendarTime;
import 'celestial_astronomy.dart';
import 'celestial_renderer.dart';

/// The time the sky shows: real time, or a timelapse running faster from
/// wherever the sky was when it started. Turning the timelapse off keeps
/// the sky at the time it reached, running at real speed, until the Time
/// chip brings it back to now.
class CelestialClock {
  CelestialClock([DateTime Function()? real]) : _real = real ?? DateTime.now {
    _anchor = _since = _real();
  }

  /// Off, one minute, ten minutes and one hour of sky per second.
  static const rates = [1.0, 60.0, 600.0, 3600.0];

  final DateTime Function() _real;
  late DateTime _anchor, _since;
  double _rate = 1;

  /// Bumped whenever the sky's time jumps or changes speed.
  int version = 0;

  double get rate => _rate;

  DateTime now() {
    final real = _real();
    final elapsed = real.difference(_since).inMicroseconds * _rate;
    return _anchor.add(Duration(microseconds: elapsed.round()));
  }

  /// Whether the sky is off real time, so the Time chip offers to return.
  bool get shifted =>
      _rate != 1 ||
      now().difference(_real()).abs() > const Duration(minutes: 1);

  /// The next speed, back to real speed after the fastest.
  void nextRate() {
    final i = rates.indexOf(_rate);
    _anchor = now();
    _since = _real();
    _rate = rates[(i + 1) % rates.length];
    version++;
  }

  /// Back to now at real speed.
  void reset() {
    _anchor = _since = _real();
    _rate = 1;
    version++;
  }
}

/// Whether any Celestial control is switched on.
bool celestialControlsEnabled(AppContainer c, {required bool compass}) {
  final s = c.settings;
  return s.get(defs.screensaverCelestialControlCoordinates) ||
      s.get(defs.screensaverCelestialControlAzimuth) ||
      s.get(defs.screensaverCelestialControlAltitude) ||
      s.get(defs.screensaverCelestialControlFov) ||
      s.get(defs.screensaverCelestialControlTime) ||
      s.get(defs.screensaverCelestialControlTimelapse) ||
      s.get(defs.screensaverCelestialControlMoonPhase) ||
      (compass && s.get(defs.screensaverCelestialControlPointAtSky));
}

/// The phase of the Moon from its mean age in the synodic month, 0 for
/// new to 7 for waning crescent.
int celestialMoonPhase(DateTime time) {
  final age = ((julianDay(time) - 2451550.1) / 29.530588853) % 1;
  return (age * 8).round() % 8;
}

/// The readouts and time controls a touch brings up along the bottom of
/// the sky, set like an observatory program's status bar: small, dim type
/// on a fade into the ground, nothing bright enough to spoil dark-adapted
/// eyes. Readouts on the left (position, where the screen faces, the
/// Moon), the sky's time and its controls on the right. Each has its own
/// switch in Controls. They refresh a few times a second while [visible],
/// and not at all while hidden.
class CelestialControls extends StatefulWidget {
  const CelestialControls({
    super.key,
    required this.container,
    required this.latitude,
    required this.longitude,
    required this.view,
    required this.clock,
    required this.compass,
    required this.visible,
    required this.onClock,
  });

  final AppContainer container;
  final double latitude, longitude;
  final ValueListenable<CelestialView> view;
  final CelestialClock clock;

  /// The device has a compass for Point at the sky.
  final bool compass;
  final bool visible;

  /// The timelapse or the time changed.
  final VoidCallback onClock;

  @override
  State<CelestialControls> createState() => _CelestialControlsState();
}

/// The bar's one color, a cool gray kept well below white.
const _ink = Color(0xFFD5DCE6);

class _CelestialControlsState extends State<CelestialControls> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(CelestialControls old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _sync();
  }

  void _sync() {
    _tick?.cancel();
    _tick = widget.visible
        ? Timer.periodic(const Duration(milliseconds: 200), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.container, s = c.settings;
    final clock = widget.clock;
    String t(String english) => screensaverText(context, english);
    final scale =
        (MediaQuery.sizeOf(context).shortestSide / 700).clamp(.8, 1.15) *
        (s.get(defs.screensaverCelestialControlScale) / 100).clamp(.5, 2);
    final view = widget.view.value;
    final facing = view.frame?.forward;
    final azimuth = facing?.azimuth ?? view.azimuth;
    final altitude = facing?.altitude ?? view.altitude;
    final time = clock.now();
    final following = s.get(defs.screensaverCelestialFollowDevice);
    final phase = celestialMoonPhase(time);
    final readouts = <Widget>[
      if (s.get(defs.screensaverCelestialControlCoordinates))
        _Readout(
          scale: scale,
          value: [
            '${widget.latitude.abs().toStringAsFixed(2)}° '
                '${t(widget.latitude >= 0 ? 'N' : 'S')}',
            '${widget.longitude.abs().toStringAsFixed(2)}° '
                '${t(widget.longitude >= 0 ? 'E' : 'W')}',
          ].join('  '),
        ),
      if (s.get(defs.screensaverCelestialControlAzimuth))
        _Readout(
          scale: scale,
          label: t('Az'),
          value:
              '${(azimuth.round() % 360).toString().padLeft(3, '0')}° '
              '${t(const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][(azimuth / 45).round() % 8])}',
        ),
      if (s.get(defs.screensaverCelestialControlAltitude))
        _Readout(
          scale: scale,
          label: t('Alt'),
          value:
              '${altitude.round() >= 0 ? '+' : '−'}'
              '${altitude.round().abs().toString().padLeft(2, '0')}°',
        ),
      if (s.get(defs.screensaverCelestialControlFov))
        _Readout(scale: scale, label: t('FOV'), value: '${view.fov.round()}°'),
      if (s.get(defs.screensaverCelestialControlMoonPhase))
        _Readout(
          scale: scale,
          lead: _MoonGlyph(
            size: 11 * scale,
            phase: phase,
            south: widget.latitude < 0,
          ),
          value:
              '${t(const ['New Moon', 'Waxing crescent', 'First quarter', 'Waxing gibbous', 'Full Moon', 'Waning gibbous', 'Last quarter', 'Waning crescent'][phase])} '
              '${(SkyEphemeris(time, widget.latitude, widget.longitude).moonIllumination * 100).round()}%',
        ),
    ];
    final clockItems = <Widget>[
      if (s.get(defs.screensaverCelestialControlTime))
        _Readout(
          scale: scale,
          value: _timeText(context, time),
          bright: clock.shifted,
        ),
      // Now comes before the buttons that stay, so it never moves them
      // from under the finger as it appears.
      if (clock.shifted &&
          (s.get(defs.screensaverCelestialControlTime) ||
              s.get(defs.screensaverCelestialControlTimelapse)))
        _Button(
          scale: scale,
          text: t('Now'),
          onTap: () {
            clock.reset();
            widget.onClock();
            setState(() {});
          },
        ),
      if (s.get(defs.screensaverCelestialControlTimelapse))
        _Button(
          scale: scale,
          icon: Icons.fast_forward_rounded,
          text: clock.rate == 1 ? null : '${clock.rate.round()}×',
          lit: clock.rate != 1,
          tooltip: defs.screensaverCelestialControlTimelapse.localizedTitle(
            context,
          ),
          onTap: () {
            clock.nextRate();
            widget.onClock();
            setState(() {});
          },
        ),
      if (widget.compass && s.get(defs.screensaverCelestialControlPointAtSky))
        _Button(
          scale: scale,
          icon: Icons.screen_rotation_alt_rounded,
          lit: following,
          tooltip: defs.screensaverCelestialFollowDevice.localizedTitle(
            context,
          ),
          onTap: () =>
              c.settings.set(defs.screensaverCelestialFollowDevice, !following),
        ),
    ];
    Widget group(List<Widget> items) => Wrap(
      spacing: 18 * scale,
      runSpacing: 4 * scale,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
    // A fade into the ground keeps the type legible over the terrain and
    // the Milky Way without a panel.
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0xB3000000), Color(0x00000000)],
          stops: [0, .45, 1],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 40, 12, 8) * scale,
        child: OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.start,
          overflowSpacing: 4 * scale,
          spacing: 24 * scale,
          children: [
            if (readouts.isNotEmpty) group(readouts),
            if (clockItems.isNotEmpty)
              Wrap(
                spacing: 6 * scale,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (i, w) in clockItems.indexed)
                    // A little more room between the time and its buttons.
                    i == 0 && w is _Readout
                        ? Padding(
                            padding: EdgeInsets.only(right: 6 * scale),
                            child: w,
                          )
                        : w,
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// The sky's time, with the date once a timelapse leaves today.
  String _timeText(BuildContext context, DateTime time) {
    final now = DateTime.now();
    final clock = calendarTime(context, time);
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return clock;
    }
    return '${DateFormat.MMMd().format(time)}  $clock';
  }
}

TextStyle _type(double scale, {double alpha = .78, FontWeight? weight}) =>
    TextStyle(
      fontFamily: 'Rubik',
      fontSize: 12.5 * scale,
      fontWeight: weight,
      letterSpacing: .3,
      color: _ink.withValues(alpha: alpha),
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.2,
    );

/// A dim label and its value, the numbers in fixed-width figures so they
/// hold still while they change.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.scale,
    required this.value,
    this.label,
    this.lead,
    this.bright = false,
  });

  final double scale;
  final String value;
  final String? label;
  final Widget? lead;

  /// Set apart from real time, as a timelapse leaves the clock.
  final bool bright;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (lead != null) ...[lead!, SizedBox(width: 6 * scale)],
      if (label != null) ...[
        Text(label!, style: _type(scale, alpha: .45)),
        SizedBox(width: 5 * scale),
      ],
      Text(value, style: _type(scale, alpha: bright ? .95 : .78)),
    ],
  );
}

/// A small square-cornered button with a hairline edge. On, it takes a
/// faint fill and a brighter edge. The touch area reaches past the
/// drawing so the small button stays easy to hit.
class _Button extends StatelessWidget {
  const _Button({
    required this.scale,
    required this.onTap,
    this.icon,
    this.text,
    this.lit = false,
    this.tooltip,
  });

  final double scale;
  final VoidCallback onTap;
  final IconData? icon;
  final String? text;
  final bool lit;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final alpha = lit ? .95 : .7;
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 6 * scale),
        child: Container(
          height: 26 * scale,
          constraints: BoxConstraints(minWidth: 30 * scale),
          padding: EdgeInsets.symmetric(horizontal: 7 * scale),
          decoration: BoxDecoration(
            color: _ink.withValues(alpha: lit ? .14 : 0),
            borderRadius: BorderRadius.circular(4 * scale),
            border: Border.all(
              color: _ink.withValues(alpha: lit ? .45 : .2),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(
                  icon,
                  size: 15 * scale,
                  color: _ink.withValues(alpha: alpha),
                ),
              if (icon != null && text != null) SizedBox(width: 4 * scale),
              if (text != null) Text(text!, style: _type(scale, alpha: alpha)),
            ],
          ),
        ),
      ),
    );
    return tooltip == null
        ? button
        : Semantics(label: tooltip, button: true, child: button);
  }
}

/// The Moon as it looks tonight, in a few pixels: the lit part bright,
/// the rest a faint disc. Waxing lights the right side from the north and
/// the left from the south.
class _MoonGlyph extends StatelessWidget {
  const _MoonGlyph({
    required this.size,
    required this.phase,
    required this.south,
  });

  final double size;
  final int phase;
  final bool south;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _MoonGlyphPainter(phase, south),
  );
}

class _MoonGlyphPainter extends CustomPainter {
  _MoonGlyphPainter(this.phase, this.south);
  final int phase;
  final bool south;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = size.center(Offset.zero);
    canvas.drawCircle(center, r, Paint()..color = _ink.withValues(alpha: .16));
    if (phase == 0) return;
    final lit = Paint()..color = _ink.withValues(alpha: .8);
    if (phase == 4) {
      canvas.drawCircle(center, r, lit);
      return;
    }
    // The terminator is an ellipse whose width follows the phase: a half
    // disc on the lit side, then the ellipse added for gibbous or cut
    // away for crescent.
    final waxing = phase < 4;
    final right = waxing != south;
    final k = math.cos(phase * math.pi / 4).abs();
    final half = Path()
      ..addArc(
        Rect.fromCircle(center: center, radius: r),
        right ? -math.pi / 2 : math.pi / 2,
        math.pi,
      );
    final ellipse = Path()
      ..addOval(
        Rect.fromCenter(center: center, width: 2 * r * k, height: 2 * r),
      );
    final gibbous = phase == 3 || phase == 5;
    final crescent = phase == 1 || phase == 7;
    final shape = gibbous
        ? Path.combine(PathOperation.union, half, ellipse)
        : crescent
        ? Path.combine(PathOperation.difference, half, ellipse)
        : half;
    canvas.drawPath(shape, lit);
  }

  @override
  bool shouldRepaint(_MoonGlyphPainter old) =>
      old.phase != phase || old.south != south;
}
