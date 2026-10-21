/// Map overlay for airframes (Skydio P1/P2): friendly platforms,
/// Remote ID broadcast contacts, and their operator positions.
///
/// Pure layer in the sensor_overlay.dart pattern: records + contacts
/// + a lat/lon→pixel projector in, widgets out. tracking.dart drops
/// these into its map Stack behind the AIR toggle.
///
/// Glyphs: a DIAMOND is an aircraft; a small SQUARE is its operator /
/// takeoff point (Remote ID System message — labeled by what the
/// broadcast says it is, never upgraded to "operator" when the
/// message reports a takeoff location).
///
/// Colors are the affiliation contract:
///  - green  FRIENDLY (registry or cooperative-feed corroborated)
///  - cyan   FRIENDLY (claimed) — a Remote ID serial asserted a
///           whitelist match; the broadcast is unauthenticated, so
///           the claim renders claimed until a Class A/B feed agrees
///  - amber  UNKNOWN — broadcast heard, no identity match
///
/// Absence is honest: this layer draws only what a feed reported.
/// Nothing here implies an empty sky.
library;

import 'package:flutter/material.dart';

import '../services/airframe_identity.dart';
import '../services/remote_id.dart';
import '../theme.dart';

Color airframeAffiliationColor(String affiliationLabel) {
  switch (affiliationLabel) {
    case 'FRIENDLY':
    case 'FRIENDLY (FEED)':
      return SentryColors.green;
    case 'FRIENDLY (claimed)':
      return SentryColors.cyan;
    default:
      return SentryColors.amber;
  }
}

List<Widget> airframeLayer({
  required List<AirframeRecord> records,
  required List<RidContact> ridContacts,
  required Offset Function(double lat, double lon) project,
}) {
  final out = <Widget>[];
  final recordSerials = <String>{
    for (final r in records)
      if (r.serial != null) r.serial!.toUpperCase(),
  };
  for (final r in records) {
    final lat = r.lat;
    final lon = r.lon;
    if (lat == null || lon == null) continue;
    final color = airframeAffiliationColor(r.affiliationLabel);
    out.add(_AirMarker(
      pos: project(lat, lon),
      color: color,
      operator: false,
      label: '${r.displayName} · ${r.klass.name.toUpperCase()}',
    ));
    final oLat = r.operatorLat;
    final oLon = r.operatorLon;
    if (oLat != null && oLon != null) {
      out.add(_AirMarker(
        pos: project(oLat, oLon),
        color: color,
        operator: true,
        label: ridOperatorLabel(r.operatorLocationType),
      ));
    }
  }
  // Broadcast contacts that no record absorbed: contacts whose
  // Basic ID hasn't arrived yet (no serial to key a record on).
  // Contacts WITH a serial are drawn by their record above.
  for (final c in ridContacts) {
    if (c.serial != null && recordSerials.contains(c.serial!.toUpperCase())) {
      continue;
    }
    final lat = c.lat;
    final lon = c.lon;
    if (lat == null || lon == null) continue;
    out.add(_AirMarker(
      pos: project(lat, lon),
      color: SentryColors.amber,
      operator: false,
      label: c.serial ?? 'RID · NO ID',
    ));
    final oLat = c.operatorLat;
    final oLon = c.operatorLon;
    if (oLat != null && oLon != null) {
      out.add(_AirMarker(
        pos: project(oLat, oLon),
        color: SentryColors.amber,
        operator: true,
        label: c.operatorLabel,
      ));
    }
  }
  return out;
}

class _AirMarker extends StatelessWidget {
  const _AirMarker({
    required this.pos,
    required this.color,
    required this.operator,
    required this.label,
  });

  final Offset pos;
  final Color color;
  final bool operator;
  final String label;

  @override
  Widget build(BuildContext context) {
    final glyph = operator ? 11.0 : 17.0;
    return Positioned(
      left: pos.dx - 40,
      top: pos.dy - glyph / 2,
      child: IgnorePointer(
        child: SizedBox(
          width: 80,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: Size(glyph, glyph),
                painter: _GlyphPainter(color: color, operator: operator),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                  shadows: const [
                    Shadow(color: Colors.black, blurRadius: 3),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Diamond for an aircraft, square for an operator point.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter({required this.color, required this.operator});
  final Color color;
  final bool operator;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final path = Path();
    if (operator) {
      final h = size.width / 2;
      path.addRect(Rect.fromLTRB(cx - h, cy - h, cx + h, cy + h));
    } else {
      path
        ..moveTo(cx, 0)
        ..lineTo(size.width, cy)
        ..lineTo(cx, size.height)
        ..lineTo(0, cy)
        ..close();
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.color != color || old.operator != operator;
}
