import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// "Why did it alert" — tap any crossing event to see the evidence:
/// which link, which direction, how deep, how long, which detector
/// channels fired, and the deviation history around the event.
class EvidenceSheet extends StatelessWidget {
  const EvidenceSheet({super.key, required this.event, required this.state});

  final CrossingEvent event;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final history = state.history[event.linkKey] ?? const <LinkSample>[];
    // Window around the event: 60 s before to 10 s after.
    final start = event.timestamp.subtract(const Duration(seconds: 60));
    final end = event.timestamp.add(const Duration(seconds: 10));
    final window =
        history.where((s) => s.timestamp.isAfter(start) && s.timestamp.isBefore(end)).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SentryColors.muted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('WHY DID IT ALERT', style: SentryType.section()),
            const SizedBox(height: 10),
            _row('LINK', shortLinkKey(event.linkKey)),
            _row('WHEN', _fmtTime(event.timestamp)),
            _row('DIRECTION',
                event.direction == 'rise' ? 'RISE + (signal rose)' : 'DIP − (signal fell)'),
            _row('DEPTH',
                '${event.direction == 'rise' ? '+' : '−'}${event.dipDepth.toStringAsFixed(1)} (est.)'),
            _row('LASTED', event.durationLabel),
            _row('SIZE', event.sizeLabel),
            _row(
                'CHANNELS',
                [
                  'mean-deviation',
                  if (event.viaVariance) 'variance (VRTI)',
                ].join(' + ')),
            if (event.aiLabel != null)
              _row('AI GUESS',
                  '${event.aiLabel} (${((event.aiConfidence ?? 0) * 100).toStringAsFixed(0)}% conf, synthetic-trained)'),
            _evidenceSection(
              state,
              'RF SIGNATURES',
              state.elrsEvidenceLines,
              'Protocol-pattern evidence only: consistent with, never '
              'confirmed. Any LoRa FHSS emitter can raise these.',
            ),
            _evidenceSection(
              state,
              'EMITTER COINCIDENCE',
              state.emitterEvidenceLines,
              'CoT emitter observation spatially coincident with this '
              'event: consistent with, never confirmed. An emitter is '
              'not an identification.',
            ),
            _evidenceSection(
              state,
              'CSI DISTURBANCE',
              state.csiEvidenceLines,
              'Class estimates from a synthetic-trained model: possible '
              'mover classes, never identity.',
            ),
            _evidenceSection(
              state,
              'PASSIVE DOPPLER',
              state.dopplerEvidenceLines,
              'Corroboration only: agreement can upgrade confidence, '
              'disagreement never downgrades a track.',
            ),
            _evidenceSection(
              state,
              'WPP-IDP',
              state.wppIdpEvidenceLines,
              'Doppler-line detections are estimates — R&D logging, not '
              'identification.',
            ),
            _evidenceSection(
              state,
              'PMR MONITOR (EXPERIMENTAL)',
              state.pmrMonitorLines,
              'Experimental preamble-jamming monitor: PMR readings only, '
              'never a confirmed jamming verdict. Report-only unless a '
              'threshold is set; a low PMR is consistent with preamble '
              'interference, not proof of jamming.',
            ),
            _bearingRow(window),
            const SizedBox(height: 12),
            Text('DEVIATION HISTORY (60s window)', style: SentryType.section()),
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              width: double.infinity,
              child: CustomPaint(
                painter: _DeviationPainter(window, event),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Deviation in the expected direction vs this link\u2019s own '
              'adaptive threshold (dashed). Estimates, not measurements.',
              style: SentryType.rowLabel().copyWith(fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 96,
                child: Text(label, style: SentryType.rowLabel())),
            Expanded(
                child: Text(value,
                    style: SentryType.rowValue(SentryColors.onDark))),
          ],
        ),
      );

  /// One evidence section (ELRS / CSI / Doppler / WPP-IDP): the raw
  /// lines plus a fixed honesty footnote. Empty sections render
  /// nothing — silence, never a guess.
  Widget _evidenceSection(
      AppState state, String title, List<String> lines, String footnote) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text(title, style: SentryType.section()),
        const SizedBox(height: 4),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(width: 96),
                Expanded(
                    child: Text(l,
                        style: SentryType.rowValue(SentryColors.onDark))),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 3),
          child: Text(
            footnote,
            style: SentryType.rowLabel().copyWith(fontSize: 10),
          ),
        ),
      ],
    );
  }

  Widget _bearingRow(List<LinkSample> window) {
    double? bearing;
    for (final s in window) {
      if (s.bearingDeg != null) bearing = s.bearingDeg;
    }
    if (bearing == null) return const SizedBox.shrink();
    return _row('BEARING',
        '${bearing.toStringAsFixed(0)}° (est. — one station: direction, not a fix)');
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

/// Sparkline of deviation vs threshold around the event.
class _DeviationPainter extends CustomPainter {
  _DeviationPainter(this.samples, this.event);

  final List<LinkSample> samples;
  final CrossingEvent event;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1A1A22);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bg,
    );
    if (samples.isEmpty) return;

    var maxV = 0.0;
    for (final s in samples) {
      if (s.dip > maxV) maxV = s.dip;
      if (s.threshold.isFinite && s.threshold > maxV) maxV = s.threshold;
    }
    maxV = maxV <= 0 ? 1.0 : maxV * 1.2;

    double x(int i) => size.width * i / (samples.length - 1).clamp(1, 1 << 30);
    double y(double v) => size.height - (v / maxV) * (size.height - 8) - 4;

    // Threshold (dashed).
    final thrPaint = Paint()
      ..color = SentryColors.amber.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    const dash = 5.0;
    final thr = samples.last.threshold;
    if (thr.isFinite) {
      var dx = 0.0;
      while (dx < size.width) {
        canvas.drawLine(Offset(dx, y(thr)), Offset(dx + dash, y(thr)), thrPaint);
        dx += dash * 2;
      }
    }

    // Deviation line.
    final linePaint = Paint()
      ..color = SentryColors.purple
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final px = x(i);
      final py = y(samples[i].dip.clamp(0, maxV));
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(path, linePaint);

    // Event marker.
    var best = 0;
    var bestDt = const Duration(days: 365);
    for (var i = 0; i < samples.length; i++) {
      final dt = samples[i].timestamp.difference(event.timestamp).abs();
      if (dt < bestDt) {
        bestDt = dt;
        best = i;
      }
    }
    final markPaint = Paint()
      ..color = SentryColors.red.withValues(alpha: 0.8)
      ..strokeWidth = 1.5;
    canvas.drawLine(
        Offset(x(best), 4), Offset(x(best), size.height - 4), markPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
