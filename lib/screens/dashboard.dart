import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../services/health.dart';
import '../services/radio_driver.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'evidence_sheet.dart';

/// Dot color for a crossing event's size estimate. Pure function so the
/// timeline and the detection card agree — and so it's unit-testable.
Color eventSizeColor(String sizeEstimate) => switch (sizeEstimate) {
      'S' => SentryColors.blue,
      'M' => SentryColors.amber,
      _ => SentryColors.red,
    };

/// Events for the timeline strip: the last [n] events, oldest first.
/// Pure function so the mapping is unit-testable.
List<CrossingEvent> timelineEvents(List<CrossingEvent> events, [int n = 24]) {
  final take = events.length > n ? n : events.length;
  // events is newest-first; timeline reads oldest-first.
  return events.take(take).toList().reversed.toList();
}

/// Alert-first dashboard in the RuView observatory style: a floating
/// PERIMETER STATUS panel with a giant readout, a LATEST DETECTION panel
/// with technical rows, mesh link health, and the event log.
/// No spectrum charts — this screen answers one question: was something
/// detected? Dark mode only. All signal numbers are estimates
/// (radio-internal units).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final disturbed = state.disturbedLinks;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _alertPanel(disturbed),
            const SizedBox(height: 12),
            _controlRow(),
            const SizedBox(height: 12),
            _radiosCard(),
            const SizedBox(height: 12),
            _latestDetection(),
            const SizedBox(height: 12),
            _linksCompact(disturbed),
            const SizedBox(height: 12),
            _spectrumCard(),
            if (state.hasSdrDriver) const SizedBox(height: 12),
            _timelineStrip(context),
            const SizedBox(height: 12),
            _eventsCard(context),
            const SizedBox(height: 12),
            const _ScopeNote(),
          ],
        );
      },
    );
  }

  /// The big one: CLEAR (shield) vs DETECTED (warning), observatory style.
  Widget _alertPanel(List<String> disturbed) {
    final h = state.health;
    final idle = !state.polling;
    final detected = !idle && disturbed.isNotEmpty;
    // CLEAR is only shown when the system can vouch for it. A detection
    // always wins; otherwise a failed or partial system is never green.
    final blind = !idle && !detected && h.level == Coverage.blind;
    final degraded = !idle && !detected && h.level == Coverage.degraded;
    final starting = !idle && !detected && h.level == Coverage.starting;
    final color = idle
        ? SentryColors.muted
        : detected
            ? SentryColors.amber
            : blind
                ? SentryColors.red
                : degraded
                    ? SentryColors.orange
                    : starting
                        ? SentryColors.muted
                        : SentryColors.green;
    final icon = idle
        ? Icons.pause_circle_outline
        : detected
            ? Icons.warning_amber_rounded
            : blind
                ? Icons.sensors_off
                : degraded
                    ? Icons.error_outline
                    : starting
                        ? Icons.hourglass_empty
                        : Icons.shield_outlined;
    final title = idle
        ? 'PAUSED'
        : detected
            ? 'DETECTED'
            : blind
                ? 'NO DATA'
                : degraded
                    ? 'DEGRADED'
                    : starting
                        ? 'STARTING'
                        : 'CLEAR';
    final subtitle = idle
        ? 'PRESS START TO BEGIN MONITORING'
        : detected
            ? '${disturbed.length} LINK DIRECTION(S) DISTURBED'
            : blind
                ? 'NOT MONITORING - CLEAR CANNOT BE ASSUMED'
                : degraded
                    ? 'CLEAR ON ${h.liveLinks} OF ${h.expectedLinks} LINK DIRECTION(S)'
                    : starting
                        ? 'WAITING FOR LINK DATA'
                        : 'MONITORING ${h.liveLinks} LINK DIRECTION(S)';
    final showReasons = !idle && h.reasons.isNotEmpty;
    final live = !state.settings.simulatedMode;
    return SentryPanel(
      glow: idle ? null : color,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('PERIMETER STATUS', style: SentryType.section()),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: SentryColors.border),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: live ? SentryColors.green : SentryColors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      live ? 'LIVE' : 'SIM',
                      style: SentryType.chip(
                        live ? SentryColors.green : SentryColors.orange,
                      ).copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(icon, color: color, size: 52),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: SentryType.readout(40, color)
                      .copyWith(letterSpacing: 5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: SentryType.section(11)),
          if (detected) ...[
            const SizedBox(height: 8),
            Text(
              disturbed.join('  ·  '),
              style: SentryType.rowValue(SentryColors.amber)
                  .copyWith(fontSize: 11),
            ),
            const SizedBox(height: 6),
            Text(
              'HEURISTIC DETECTION — LINK DISTURBANCE CONFIRMED, '
              'NOT IDENTIFICATION. SIZE AND AI LABELS ARE ESTIMATES.',
              style: SentryType.section(10).copyWith(
                  height: 1.6, color: SentryColors.muted),
            ),
          ],
          if (showReasons) ...[
            const SizedBox(height: 8),
            for (final r in h.reasons.take(4))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  r,
                  style: SentryType.rowValue(
                    blind ? SentryColors.red : SentryColors.orange,
                  ).copyWith(fontSize: 11),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton(
                onPressed: state.polling ? state.stop : state.start,
                child: Text(state.polling ? 'STOP' : 'START'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: state.toggleAlerts,
                icon: Icon(
                  state.alertsEnabled ? Icons.volume_up : Icons.volume_off,
                  size: 18,
                ),
                label: Text(state.alertsEnabled ? 'ALERTS ON' : 'MUTED'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlRow() {
    final live = !state.settings.simulatedMode;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SOURCE', style: SentryType.section()),
          const SizedBox(height: 10),
          _dataRow(
            live ? 'RADIO' : 'MODE',
            live ? state.settings.radioIp : 'SIMULATED LINK DATA',
            SentryColors.blue,
          ),
          const SizedBox(height: 6),
          _dataRow('STATUS', state.connectionLabel, SentryColors.muted),
          if (state.cotStatusLine != null) ...[
            const SizedBox(height: 6),
            _dataRow('COT', state.cotStatusLine!, SentryColors.purple),
          ],
          if (state.error != null) ...[
            const SizedBox(height: 6),
            Text(state.error!,
                style: SentryType.rowValue(SentryColors.red)),
          ],
        ],
      ),
    );
  }

  /// Most recent confirmed crossing, with size estimate and duration.
  /// Per-radio status: which drivers are polling, their link counts,
  /// and any errors. The banner above fires if ANY driver detects.
  Widget _radiosCard() {
    final statuses = state.driverStatuses;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('RADIOS', style: SentryType.section()),
              const Spacer(),
              Text(
                state.settings.simulatedMode
                    ? 'SIMULATED'
                    : '${statuses.length} DRIVER${statuses.length == 1 ? '' : 'S'}',
                style: SentryType.section(10).copyWith(
                    color: SentryColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!state.polling)
            Text('NOT POLLING — PRESS START.',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.muted))
          else if (statuses.isEmpty)
            Text('NO RADIOS ENABLED — ADD ONE IN SETTINGS.',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.orange))
          else
            for (final s in statuses)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.error != null
                            ? SentryColors.red
                            : driverColor(s.driverId),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.label,
                        style: SentryType.rowValue(
                                SentryColors.onDark)
                            .copyWith(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      s.error ??
                          '${s.linkCount} LINKS',
                      style: SentryType.section(10).copyWith(
                          color: s.error != null
                              ? SentryColors.red
                              : SentryColors.muted),
                    ),
                  ],
                ),
              ),
          if (state.polling) _takLinkRow(),
        ],
      ),
    );
  }

  /// TAK/CoT emit link state, same card as the radios. Only shown
  /// while polling; OFF is dimmed, LINKED/MULTICAST are neutral,
  /// RETRYING is amber.
  Widget _takLinkRow() {
    final link = state.cotLinkStatus;
    final color = link == 'LINKED' || link == 'MULTICAST'
        ? SentryColors.muted
        : link == 'RETRYING'
            ? SentryColors.orange
            : SentryColors.muted.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: link == 'LINKED'
                  ? SentryColors.green
                  : link == 'RETRYING'
                      ? SentryColors.orange
                      : SentryColors.muted.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'TAK LINK',
              style: SentryType.rowValue(SentryColors.onDark)
                  .copyWith(fontSize: 12),
            ),
          ),
          Text(
            link,
            style: SentryType.section(10).copyWith(color: color),
          ),
        ],
      ),
    );
  }

  Widget _latestDetection() {
    if (state.events.isEmpty) {
      return SentryPanel(
        child: Row(
          children: [
            const Icon(Icons.radar,
                color: SentryColors.muted, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('LATEST DETECTION', style: SentryType.section()),
                  const SizedBox(height: 6),
                  Text('NO CROSSINGS DETECTED YET',
                      style: SentryType.rowLabel()),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final e = state.events.first;
    final sizeColor = eventSizeColor(e.sizeEstimate);
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('LATEST DETECTION', style: SentryType.section()),
              const Spacer(),
              SentryChip(label: 'SIZE ${e.sizeEstimate}', color: sizeColor),
            ],
          ),
          const SizedBox(height: 12),
          _dataRow('TIME', _fmtTime(e.timestamp), SentryColors.onDark),
          const SizedBox(height: 6),
          _dataRow('LINK', shortLinkKey(e.linkKey), SentryColors.onDark),
          const SizedBox(height: 6),
          _dataRow('DIP',
              '-${e.dipDepth.toStringAsFixed(0)} EST', SentryColors.red),
          const SizedBox(height: 6),
          _dataRow('LASTED', e.durationLabel, SentryColors.onDark),
          const SizedBox(height: 6),
          _dataRow(
              'AI CLASSIFY',
              e.aiLabel == null
                  ? '—'
                  : e.aiConfidence == null
                      ? '${e.aiLabel} EST'
                      : '${e.aiLabel} ${(e.aiConfidence! * 100).toStringAsFixed(0)}% EST',
              SentryColors.purple),
          const SizedBox(height: 10),
          Text('SIZE AND AI LABELS ARE HEURISTIC ESTIMATES, NOT IDENTIFICATION. '
              'THE CLASSIFIER WAS TRAINED ON SYNTHETIC DATA.',
              style: SentryType.section(9)),
        ],
      ),
    );
  }

  /// Label / value technical row, RuView style.
  Widget _dataRow(String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(label, style: SentryType.rowLabel())),
        Expanded(
            child: Text(value, style: SentryType.rowValue(color))),
      ],
    );
  }

  /// One compact row per link direction — health only, no charts.
  Widget _linksCompact(List<String> disturbed) {
    final keys = state.history.keys.toList()..sort();
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MESH LINKS', style: SentryType.section()),
          const SizedBox(height: 10),
          if (keys.isEmpty)
            Text('NO LINK DATA YET', style: SentryType.rowLabel()),
          for (final k in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: disturbed.contains(k)
                          ? SentryColors.amber
                          : SentryColors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(shortLinkKey(k), style: SentryType.rowValue(SentryColors.onDark)),
                  ),
                  Text(
                    'SNR ${state.history[k]!.last.snrLabel}  ·  DIP ${state.history[k]!.last.dipLabel}',
                    style: SentryType.rowLabel().copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Horizontal event timeline: one dot per crossing (colored by size
  /// estimate), tap for the evidence sheet. Oldest first, newest last.
  /// Works on the live event list and on replayed recordings alike —
  /// both land in [AppState.events].
  Widget _timelineStrip(BuildContext context) {
    final evts = timelineEvents(state.events);
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('EVENT TIMELINE', style: SentryType.section()),
              const Spacer(),
              Text(
                  evts.length < state.events.length
                      ? 'SHOWING ${evts.length} OF ${state.events.length} EVENTS'
                      : '${state.events.length} EVENTS',
                  style: SentryType.section(10)),
            ],
          ),
          const SizedBox(height: 10),
          if (evts.isEmpty)
            Text('NO EVENTS YET', style: SentryType.rowLabel())
          else ...[
            SizedBox(
              height: 56,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: evts.length,
                itemBuilder: (ctx, i) {
                  final e = evts[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _openEvidence(context, e),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: eventSizeColor(e.sizeEstimate),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(_fmtTime(e.timestamp),
                              style: SentryType.section(9)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmtTime(evts.first.timestamp),
                    style: SentryType.section(9)),
                Text('SIZE: S/M/L (EST)',
                    style: SentryType.section(9)),
                Text(_fmtTime(evts.last.timestamp),
                    style: SentryType.section(9)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _openEvidence(BuildContext context, CrossingEvent e) {
    showModalBottomSheet(
      context: context,
      backgroundColor: SentryColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => EvidenceSheet(event: e, state: state),
    );
  }

  Widget _eventsCard(BuildContext context) {
    final stats = state.triageStats;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('CROSSING EVENTS', style: SentryType.section()),
              const Spacer(),
              Text(
                'ACK ${stats['acked']} · FA ${stats['falseAlarm']} · '
                'NEW ${stats['unreviewed']}',
                style: SentryType.section(10),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.events.isEmpty)
            Text('NO CROSSINGS DETECTED YET',
                style: SentryType.rowLabel()),
          for (final e in state.events.take(30)) _eventRow(context, e),
        ],
      ),
    );
  }

  /// One event row: tap for evidence, ACK / FALSE ALARM for triage.
  /// Acked rows dim; false alarms mute. Triage never deletes the event.
  Widget _eventRow(BuildContext context, CrossingEvent e) {
    final verdict = state.triage[AppState.triageKeyFor(e)];
    final acked = verdict == AppState.triageAcked;
    final falseAlarm = verdict == AppState.triageFalseAlarm;
    final aiConf = e.aiConfidence;
    final aiLabel = e.aiLabel == null
        ? '—'
        : aiConf == null
            ? 'AI ${e.aiLabel} EST'
            : 'AI ${e.aiLabel} ${(aiConf * 100).toStringAsFixed(0)}% EST';
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openEvidence(context, e),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              falseAlarm
                  ? Icons.do_not_disturb_on_outlined
                  : Icons.warning_amber_rounded,
              color:
                  falseAlarm ? SentryColors.muted : SentryColors.amber,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_fmtTime(e.timestamp)} · ${shortLinkKey(e.linkKey)} · $aiLabel',
                    style: SentryType.rowValue(falseAlarm
                        ? SentryColors.muted
                        : SentryColors.onDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'SIZE ${e.sizeEstimate} EST · ${e.direction == 'rise' ? 'RISE +' : 'DIP -'}${e.dipDepth.toStringAsFixed(0)} EST · LASTED ${e.durationLabel}',
                    style: SentryType.rowLabel().copyWith(
                        fontSize: 11,
                        color: falseAlarm ? SentryColors.muted : null),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      _triageBtn(e, AppState.triageAcked, 'ACK',
                          SentryColors.green),
                      const SizedBox(width: 8),
                      _triageBtn(e, AppState.triageFalseAlarm,
                          'FALSE ALARM', SentryColors.red),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: SentryColors.muted, size: 18),
          ],
        ),
      ),
    );
    return Opacity(opacity: acked ? 0.55 : 1.0, child: row);
  }

  /// Small triage toggle button. Active state is highlighted; tapping
  /// the active verdict again clears it.
  Widget _triageBtn(
      CrossingEvent e, String verdict, String label, Color color) {
    final active =
        state.triage[AppState.triageKeyFor(e)] == verdict;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => state.triageEvent(e, verdict),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(
              color: active ? color : SentryColors.border),
          borderRadius: BorderRadius.circular(6),
          color:
              active ? color.withAlpha(28) : Colors.transparent,
        ),
        child: Text(
          label,
          style: SentryType.chip(
                  active ? color : SentryColors.muted)
              .copyWith(fontSize: 10),
        ),
      ),
    );
  }

  /// Spectrum bands watched by live SDR drivers. One honest bar per
  /// band — band-median energy (dBFS) with a noise-floor marker. No
  /// waterfall: a waterfall would imply time resolution the sweep
  /// doesn't have. Bars follow the same disturbed-link state as the
  /// tripwire. Shown only when an SDR driver is active.
  Widget _spectrumCard() {
    if (!state.hasSdrDriver) return const SizedBox.shrink();
    final bands = state.sdrBands;
    final disturbed = state.disturbedLinks.toSet();
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('SPECTRUM BANDS', style: SentryType.section()),
              const Spacer(),
              Text('ENERGY dBFS', style: SentryType.section(10)),
            ],
          ),
          const SizedBox(height: 10),
          if (bands.isEmpty)
            Text('WAITING FOR SWEEP DATA',
                style: SentryType.rowLabel()),
          for (final b in bands) _bandRow(b, disturbed),
          const SizedBox(height: 6),
          Text(
            'BAND-MEDIAN ENERGY, NOT A WATERFALL. LEVELS ARE ESTIMATES '
            '(dBFS, RECEIVER-RELATIVE — NOT dBm).',
            style: SentryType.section(9),
          ),
        ],
      ),
    );
  }

  Widget _bandRow(SdrBand b, Set<String> disturbed) {
    // Same virtual link key the tripwire uses, so disturbance state
    // agrees between the panel and the detector.
    final linkKey = 'sdr:${b.radio} → sdr:band-${b.band}';
    final hot = disturbed.contains(linkKey);
    final color = hot ? SentryColors.amber : SentryColors.blue;
    // Bar scale: -100..-20 dBFS.
    double frac(double db) => ((db + 100) / 80).clamp(0.0, 1.0);
    final spanMhz = b.spanMhz ?? b.bwMhz;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(b.band.toUpperCase(),
                  style:
                      SentryType.rowValue(SentryColors.onDark)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${b.centerMhz.toStringAsFixed(1)} MHz · '
                  '${spanMhz.toStringAsFixed(1)} MHz SPAN'
                  '${b.sigHint != null ? ' · ${b.sigHint}' : ''}',
                  style: SentryType.rowLabel()
                      .copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${b.energyDbfs.toStringAsFixed(1)} EST',
                style: SentryType.rowValue(color)
                    .copyWith(fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 10,
            child: LayoutBuilder(
              builder: (ctx, c) {
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: SentryColors.surface2,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: frac(b.energyDbfs),
                      child: Container(
                        decoration: BoxDecoration(
                          color: color.withAlpha(170),
                          borderRadius:
                              BorderRadius.circular(5),
                        ),
                      ),
                    ),
                    // Noise-floor marker (10th-percentile PSD).
                    Positioned(
                      left: (c.maxWidth * frac(b.noiseDbfs) - 1)
                          .clamp(0.0, c.maxWidth),
                      top: 0,
                      bottom: 0,
                      child: Container(
                          width: 2,
                          color: SentryColors.muted),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    return SentryPanel(
      child: Text(
        'SCOPE — WITH 2 RADIOS THIS IS A SINGLE-LINK TRIPWIRE: CROSSING ALERTS '
        'PLUS A CRUDE SIZE ESTIMATE (S/M/L) FROM THE DIP. TYPE, HEADING, SPEED '
        'AND POSITION NEED 3+ MESH NODES; THOSE READOUTS UNLOCK AS RADIOS JOIN.',
        style: SentryType.section(10).copyWith(height: 1.6),
      ),
    );
  }
}
