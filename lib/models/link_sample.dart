/// Data models for the Shepherd tripwire.
///
/// Honest-units note: Silvus reports signal metrics in radio-internal units
/// (e.g. an SNR of "96" is not dB). Absolute values are therefore meaningless;
/// only *deviations from a rolling baseline* are used. Every user-facing
/// number derived from them is an estimate.
library;

/// One timestamped reading for a single link direction (node A -> node B).
class LinkSample {
  final DateTime timestamp;
  final String fromNode;
  final String toNode;

  /// Radio-internal SNR units. Estimate; use deltas, not absolutes.
  final double? snr;

  /// Link-adaptation MCS index, if reported.
  final int? mcs;

  /// Per-chain values from $pcns (chain RSSI / noise-ish, radio units).
  final List<double> pcns;

  final double? noiseFrom;
  final double? noiseTo;

  /// Deviation from baseline in the *expected* direction, radio units
  /// (baseline−snr on anti-fade links, snr−baseline on deep-fade links,
  /// larger of the two on intermediate links — see Tripwire). Estimate;
  /// use deltas, not absolutes.
  final double dip;

  /// Rolling median baseline the dip is measured against. Estimate.
  final double baseline;

  /// Dip depth at which THIS link counts as disturbed. The tripwire sets
  /// it per link from the link's own noise (see [TripwireConfig.adaptive]);
  /// NaN on raw samples that haven't been through the tripwire yet.
  final double threshold;

  /// Bearing in degrees (0–360), when this sample comes from a
  /// direction-finding driver (KrakenSDR). Null otherwise. A bearing is
  /// not a position — one station gives direction only.
  final double? bearingDeg;

  const LinkSample({
    required this.timestamp,
    required this.fromNode,
    required this.toNode,
    this.snr,
    this.mcs,
    this.pcns = const [],
    this.noiseFrom,
    this.noiseTo,
    this.dip = 0.0,
    this.baseline = double.nan,
    this.threshold = double.nan,
    this.bearingDeg,
  });

  String get linkKey => '$fromNode → $toNode';

  String get snrLabel => snr == null ? '—' : '${snr!.toStringAsFixed(0)} (est.)';
  String get dipLabel => '${dip >= 0 ? '-' : '+'}${dip.abs().toStringAsFixed(0)} (est.)';

  /// This link's own threshold, or [fallback] when none was attached.
  double effectiveThreshold(double fallback) =>
      threshold.isNaN ? fallback : threshold;

  /// True when the dip is at/above this link's own threshold.
  bool isDisturbed(double fallback) => dip >= effectiveThreshold(fallback);

  LinkSample copyWith(
          {double? dip,
          double? baseline,
          double? threshold,
          double? bearingDeg}) =>
      LinkSample(
        timestamp: timestamp,
        fromNode: fromNode,
        toNode: toNode,
        snr: snr,
        mcs: mcs,
        pcns: pcns,
        noiseFrom: noiseFrom,
        noiseTo: noiseTo,
        dip: dip ?? this.dip,
        baseline: baseline ?? this.baseline,
        threshold: threshold ?? this.threshold,
        bearingDeg: bearingDeg ?? this.bearingDeg,
      );
}

/// A confirmed link-crossing event emitted by the tripwire.
class CrossingEvent {
  final DateTime timestamp;
  final String linkKey;

  /// Peak dip depth during the disturbance, radio units. Estimate.
  final double dipDepth;

  /// How long the disturbance lasted, seconds. Estimate.
  final double durationSecs;

  /// Crude heuristic size class from dip depth: 'S', 'M' or 'L'.
  /// Estimate only — not identification.
  final String sizeEstimate;

  /// Direction of the disturbance: 'dip' (signal fell) or 'rise'
  /// (signal rose — the expected sign on deep-fade links).
  final String direction;

  /// True when the variance (VRTI) channel fired during this episode —
  /// motion raised RSS variance even though the mean barely moved.
  final bool viaVariance;

  /// Embedded-classifier label (PASSING / LINGERING / INTERFERENCE /
  /// FAULT) with confidence. Null when the model wasn't available.
  /// Heuristic estimate — trained on synthetic data, not an ID.
  final String? aiLabel;
  final double? aiConfidence;

  const CrossingEvent({
    required this.timestamp,
    required this.linkKey,
    required this.dipDepth,
    required this.durationSecs,
    required this.sizeEstimate,
    this.direction = 'dip',
    this.viaVariance = false,
    this.aiLabel,
    this.aiConfidence,
  });

  CrossingEvent copyWith({
    String? aiLabel,
    double? aiConfidence,
    String? direction,
    bool? viaVariance,
  }) =>
      CrossingEvent(
        timestamp: timestamp,
        linkKey: linkKey,
        dipDepth: dipDepth,
        durationSecs: durationSecs,
        sizeEstimate: sizeEstimate,
        direction: direction ?? this.direction,
        viaVariance: viaVariance ?? this.viaVariance,
        aiLabel: aiLabel ?? this.aiLabel,
        aiConfidence: aiConfidence ?? this.aiConfidence,
      );

  String get sizeLabel => '$sizeEstimate (est.)';

  String get durationLabel => '${durationSecs.toStringAsFixed(1)}s (est.)';

  String get summary {
    final arrow = direction == 'rise' ? '+' : '-';
    final via = viaVariance ? ' · variance channel' : '';
    return 'Crossing (est.) · $linkKey · $arrow${dipDepth.toStringAsFixed(0)} (est.) · '
        'size $sizeLabel · lasted $durationLabel$via';
  }
}
