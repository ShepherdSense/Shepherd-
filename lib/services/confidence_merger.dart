/// Gated confidence merger — the upgrade-only rule as confidence math.
///
/// Literature basis: AV-FDTI (P5, lane3 §2.1) — asymmetric, entropy-gated
/// fusion. The always-available modality (our RF mesh) carries the track;
/// conditional modalities contribute only when their *measured information
/// content* is high. Their decisive ablation: an ungated audio-visual net
/// (ASDNet) got the WORST localization of all methods tested, because it
/// "relies on visual information to infer the drone's location, even when
/// the drone is outside the field of view or in dark conditions." The
/// gate is what makes fusion a strict improvement over the RF baseline.
///
/// Formula:
///   C_display = clamp(C_RF + U, C_RF, C_max)
///   U = U_max · (1 − exp(−Σ_s (w_s · e_s) / U_max))     (saturating)
///   w_s = freshness_s · health_s · quality_s             (reliability gate)
///
/// Hard properties (all property-tested in test/confidence_merger_test.dart):
///  - NEVER SUBTRACTIVE: C_display >= C_RF by construction. The merger has
///    no code path that lowers confidence; silence contributes nothing,
///    never a penalty (P5's "never reduced by silence" rule).
///  - SATURATING: exponential approach to the cap U_max = +0.35. One strong
///    corroboration counts ~linearly; ten weak PIR triggers asymptote —
///    they cannot manufacture certainty.
///  - GATED: a sensor with no recent data, a dead source, or poor
///    alignment gets w_s = 0 — the degraded modality's weight collapses
///    exactly as AV-FDTI's gate does (h → 0 ⇒ ~100% weight on the audio).
///  - CONSISTENCY-GATED: upgrades are suspended while the track is
///    internally inconsistent (see track_consistency.dart). Upgrading a
///    misassociated track is the failure mode P8 warns about.
///
/// The merger never originates a detection: the tripwire does that. It
/// only computes the displayed confidence of a track the RF core already
/// supports. C_max = 0.95 — confidence, never identity.
library;

import 'dart:math' as math;

import '../models/sensor_observation.dart';

/// Maximum total confidence upgrade the merger can award, no matter how
/// many sensors agree. 0.35 keeps a fully-corroborated track below the
/// C_max = 0.95 ceiling even when C_RF sits at its own 0.80 cap.
const double kMaxTotalUpgrade = 0.35;

/// Displayed confidence never reaches 1.0 — confidence, never identity
/// (lane3 §160: "C_track saturates below 1").
const double kMaxDisplayConfidence = 0.95;

/// RF-core confidence cap. The RF core is heuristic (see
/// [rfCoreConfidence]); corroboration must always have headroom.
const double kRfCoreCap = 0.80;

/// How long an observation of each type stays admissible as
/// corroboration. Past the horizon the observation carries no measured
/// information about the *current* track — the AV-FDTI "degraded
/// modality" case — so its gate weight is exactly 0, not a decayed
/// tail. Horizons reflect the sensors' natural cadence: fast frames
/// (lidar/acoustic/camera) go stale in seconds; a PIR trigger is an
/// event with a longer useful shadow.
Duration stalenessHorizonFor(SensorObsType type) {
  switch (type) {
    case SensorObsType.range:
      return const Duration(seconds: 10);
    case SensorObsType.bearing:
      return const Duration(seconds: 10);
    case SensorObsType.spectrum:
      return const Duration(seconds: 10);
    case SensorObsType.binary:
      return const Duration(minutes: 2);
    case SensorObsType.energy:
      return const Duration(seconds: 30);
    case SensorObsType.motion:
      return const Duration(seconds: 30);
  }
}

/// Reliability gate w_s ∈ [0, 1] for one corroborating observation.
///
/// Computed from MEASURED information content only:
///  - [alignmentQuality]: the 0..1 geometry-alignment channel from
///    [Corroboration.quality] (how well the observation lined up).
///  - [age] vs [stalenessHorizon]: observation freshness. An observation
///    older than its horizon gets w = 0 — a sensor with no recent data
///    contributes nothing, exactly the AV-FDTI gate with h → 0.
///  - [sourceHealthy]: driver alive / recent data (the caller measures
///    this from the driver's last-poll / last-ingest timestamps).
///
/// Multiplicative on purpose: any single zero collapses the weight.
/// This is the entropy-gate analogue — predicted information content,
/// not a tunable fudge.
double reliabilityGate({
  required double alignmentQuality,
  required Duration age,
  required Duration stalenessHorizon,
  required bool sourceHealthy,
}) {
  if (!sourceHealthy) return 0.0;
  final q = alignmentQuality.clamp(0.0, 1.0);
  if (q <= 0) return 0.0;
  final horizonUs = stalenessHorizon.inMicroseconds;
  if (horizonUs <= 0) return 0.0;
  final freshness = 1.0 - age.inMicroseconds / horizonUs;
  if (freshness <= 0) return 0.0;
  return (freshness * q).clamp(0.0, 1.0);
}

/// One gated corroboration feeding the merger: evidence e_s with its
/// reliability weight w_s.
class GatedCorroboration {
  const GatedCorroboration({
    required this.sensorId,
    required this.boost,
    required this.gateWeight,
    this.note = '',
  });

  /// e_s >= 0 — the merger never subtracts.
  final double boost;

  /// w_s ∈ [0, 1] from [reliabilityGate].
  final double gateWeight;

  final String sensorId;
  final String note;
}

/// The merged confidence verdict for one track.
class MergedConfidence {
  const MergedConfidence({
    required this.base,
    required this.displayed,
    required this.upgrade,
    required this.trackConsistent,
    required this.applied,
  });

  /// C_RF — the RF-core confidence, untouched by sensors, normalized
  /// into [0, C_max] (a hand-passed base above the display ceiling is
  /// not "confidence", it is a caller bug the merger refuses to
  /// propagate).
  final double base;

  /// C_display — what the UI shows. Always >= [base].
  final double displayed;

  /// displayed − base. Always >= 0; capped at [kMaxTotalUpgrade].
  final double upgrade;

  /// False when upgrades were suspended for track inconsistency.
  final bool trackConsistent;

  /// Contributions that actually counted (w_s > 0, e_s > 0).
  final List<GatedCorroboration> applied;
}

/// Merge corroborating sensors into the track's displayed confidence.
///
/// [baseConfidence] is C_RF (see [rfCoreConfidence]). [trackConsistent]
/// comes from the consistency monitor — when false, upgrades are
/// suspended entirely (a misassociated track must not be upgraded).
/// Detection authority is untouched: this function only computes a
/// display number for a track the RF core already supports.
MergedConfidence mergeTrackConfidence({
  required double baseConfidence,
  required List<GatedCorroboration> contributions,
  required bool trackConsistent,
  double maxTotalUpgrade = kMaxTotalUpgrade,
  double maxConfidence = kMaxDisplayConfidence,
}) {
  final base = baseConfidence.clamp(0.0, maxConfidence);
  final applied = <GatedCorroboration>[];
  var weighted = 0.0;
  if (trackConsistent) {
    for (final c in contributions) {
      final w = c.gateWeight.clamp(0.0, 1.0);
      // Defensive: Corroboration asserts boost >= 0 at construction,
      // but the merger must be non-subtractive even for a hand-built
      // input. Negative evidence is discarded, never applied.
      final e = c.boost < 0 ? 0.0 : c.boost;
      if (w > 0 && e > 0) applied.add(c);
      weighted += w * e;
    }
  }
  // Saturating: exponential approach to the cap. Small totals stay
  // ~linear (one strong corroboration counts in full); large totals
  // asymptote, so N weak triggers can't manufacture certainty.
  final upgrade = maxTotalUpgrade <= 0
      ? 0.0
      : maxTotalUpgrade * (1 - math.exp(-weighted / maxTotalUpgrade));
  final displayed = (base + upgrade).clamp(base, maxConfidence);
  assert(displayed >= base, 'merger is never subtractive');
  return MergedConfidence(
    base: base,
    displayed: displayed,
    upgrade: displayed - base,
    trackConsistent: trackConsistent,
    applied: applied,
  );
}

/// RF-core confidence C_RF: a heuristic existence probability from the
/// deterministic tracker. More independently-disturbed links = higher
/// confidence, saturating at [kRfCoreCap] = 0.80 so corroboration always
/// has headroom below the 0.95 display ceiling.
///
/// HONESTY: this is a labeled display heuristic, not a measured
/// probability. linksUsed is the strongest honest signal the grid-search
/// tracker emits (one link = "somewhere along this line", six links =
/// a well-constrained fix). Shape: 1 link → 0.25, 3 → 0.54, 6 → 0.72.
double rfCoreConfidence({required int linksUsed}) {
  if (linksUsed <= 0) return 0.0;
  const perLink = 0.30;
  return kRfCoreCap * (1 - math.exp(-linksUsed * perLink / kRfCoreCap));
}
