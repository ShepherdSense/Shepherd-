/// Map overlay helpers for sensor observations.
///
/// Pure functions: observations + a lat/lon→pixel projector in,
/// widgets out. No app state, no drivers — tracking.dart supplies its
/// own projection and drops these into its Stack.
///
/// SEAM: at merge, in tracking.dart's map Stack (after the node layer,
/// before/after the track layer — above tracks reads best):
///   ...sensorObservationLayer(
///     observations: sensorObservations,   // from GenericSensorDriver
///     project: (lat, lon) => /* existing lat/lon→Offset */,
///     metersToPx: /* existing scale */,
///   ),
/// Gate the whole layer on a map toggle ("SENSORS") next to the
/// existing shadow/health toggles. Observations without sensorLat/Lon
/// are skipped (never plotted at 0,0).
library;

import 'package:flutter/material.dart';

import '../models/sensor_observation.dart';

/// Compose the full observation layer. Returns positioned widgets for
/// the map Stack. [project] converts WGS-84 to map pixels;
/// [metersToPx] scales range arcs at the current zoom.
List<Widget> sensorObservationLayer({
  required List<SensorObservation> observations,
  required Offset Function(double lat, double lon) project,
  required double metersToPx,
  DateTime? now,
}) {
  final cutoff =
      (now ?? DateTime.now()).subtract(const Duration(minutes: 5));
  final out = <Widget>[];
  for (final o in observations) {
    if (o.timestamp.isBefore(cutoff)) continue;
    final lat = o.sensorLat;
    final lon = o.sensorLon;
    if (lat == null || lon == null) continue;
    final px = project(lat, lon);
    switch (o.type) {
      case SensorObsType.range:
        final d = o.distanceM;
        if (d == null || !d.isFinite || d <= 0) continue;
        out.add(_PositionedPaint(
          pos: px,
          // Arc sized generously so it stays visible at any zoom.
          size: d * metersToPx * 2 + 48,
          painter: _RangeArcPainter(
            distPx: d * metersToPx,
            angleDeg: o.angleDeg,
          ),
        ));
      case SensorObsType.bearing:
        final b = o.bearingDeg;
        if (b == null || !b.isFinite) continue;
        out.add(_PositionedPaint(
          pos: px,
          size: 240,
          painter: _BearingPainter(
            bearingDeg: b,
            confidence: o.confidence,
          ),
        ));
      case SensorObsType.spectrum:
        final peak = o.spectralPeak;
        out.add(_PositionedPaint(
          pos: px,
          size: 120,
          painter: _SpectrumPainter(
            hasPeak: peak != null && peak.mag > 0,
          ),
          label: peak != null && peak.mag > 0
              ? '${peak.hz.toStringAsFixed(0)} Hz'
              : null,
        ));
      case SensorObsType.binary:
        if (o.triggered != true) continue;
        out.add(_MotionMarker(pos: px, color: Colors.orange));
      case SensorObsType.energy:
        // Energy already renders via the tripwire's own link display;
        // no separate glyph (avoids double-plotting one measurement).
        continue;
      case SensorObsType.motion:
        out.add(_MotionMarker(pos: px, color: Colors.lightBlueAccent));
    }
  }
  return out;
}

/// Small labeled marker for motion/binary triggers.
class _MotionMarker extends StatelessWidget {
  const _MotionMarker({required this.pos, required this.color});
  final Offset pos;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: pos.dx - 7,
      top: pos.dy - 7,
      child: IgnorePointer(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black54, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _PositionedPaint extends StatelessWidget {
  const _PositionedPaint({
    required this.pos,
    required this.size,
    required this.painter,
    this.label,
  });
  final Offset pos;
  final double size;
  final CustomPainter painter;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: pos.dx - size / 2,
      top: pos.dy - size / 2,
      child: IgnorePointer(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: painter,
            child: label == null
                ? null
                : Align(
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      label!,
                      style: const TextStyle(
                          fontSize: 9, color: Colors.white70),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Range arc: full circle for omnidirectional, wedge for directional.
class _RangeArcPainter extends CustomPainter {
  _RangeArcPainter({required this.distPx, this.angleDeg});
  final double distPx;
  final double? angleDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final paint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final r = distPx.clamp(8.0, size.width / 2 - 2);
    if (angleDeg == null) {
      canvas.drawCircle(c, r, paint);
    } else {
      // Canvas 0 rad = east, clockwise positive after flip; bearing
      // deg is clockwise from north → radians = (bearing-90).
      final a = (angleDeg! - 90) * 3.141592653589793 / 180;
      const sweep = 0.6; // ~34° wedge: honest field of regard
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a - sweep / 2,
          sweep, false, paint);
      // Radial ticks at wedge edges.
      final tick = Paint()
        ..color = Colors.cyanAccent.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      for (final e in [a - sweep / 2, a + sweep / 2]) {
        canvas.drawLine(
            c + Offset.fromDirection(e) * (r - 6),
            c + Offset.fromDirection(e) * r,
            tick);
      }
    }
    // Sensor dot at center.
    canvas.drawCircle(
        c, 3, Paint()..color = Colors.cyanAccent.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _RangeArcPainter old) =>
      old.distPx != distPx || old.angleDeg != angleDeg;
}

/// Bearing line + uncertainty wedge (±25° corroboration gate).
class _BearingPainter extends CustomPainter {
  _BearingPainter({required this.bearingDeg, required this.confidence});
  final double bearingDeg;
  final double confidence;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final a = (bearingDeg - 90) * 3.141592653589793 / 180;
    final len = size.width / 2 - 4;
    // Uncertainty wedge first (under the line).
    const half = 25 * 3.141592653589793 / 180;
    final wedge = Paint()
      ..color = Colors.amber.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: len), a - half, half * 2,
          false)
      ..close();
    canvas.drawPath(path, wedge);
    // Bearing line, alpha by confidence.
    final line = Paint()
      ..color = Colors.amber
          .withValues(alpha: 0.35 + 0.55 * confidence.clamp(0.0, 1.0))
      ..strokeWidth = 2;
    canvas.drawLine(c, c + Offset.fromDirection(a) * len, line);
    canvas.drawCircle(
        c, 3, Paint()..color = Colors.amber.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _BearingPainter old) =>
      old.bearingDeg != bearingDeg || old.confidence != confidence;
}

/// Spectrum presence glyph: ring pulses when a tonal peak is present.
class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({required this.hasPeak});
  final bool hasPeak;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      size.width / 2 - 6,
      Paint()
        ..color = (hasPeak ? Colors.purpleAccent : Colors.white24)
            .withValues(alpha: hasPeak ? 0.6 : 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hasPeak ? 2 : 1,
    );
    canvas.drawCircle(
        c, 3, Paint()..color = Colors.purpleAccent.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.hasPeak != hasPeak;
}
