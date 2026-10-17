# Confidence math — the upgrade-only rule, formalized

Research finding #2 (BRIEF.md). The literature gives Shepherd's
upgrade-only architecture rule its exact mathematical shape; this
document states the formula, the basis, and — load-bearing — what the
numbers do and do not claim.

## The formula

```
C_display = clamp(C_RF + U, C_RF, C_max)
U  = U_max · (1 − exp(−Σ_s (w_s · e_s) / U_max))     (saturating upgrade)
w_s = freshness_s · health_s · quality_s              (reliability gate, ∈ [0,1])
```

Constants: `U_max = +0.35` (max total upgrade), `C_max = 0.95`
(confidence, never identity), RF-core cap 0.80.

- `C_RF = rfCoreConfidence(linksUsed)`: saturating heuristic in the
  number of independently disturbed links (1 → 0.25, 3 → 0.54,
  6 → 0.72, asymptote 0.80). **A labeled display heuristic, not a
  measured probability.** linksUsed is the strongest honest signal the
  grid-search tracker emits.
- `e_s ≥ 0`: per-observation boost from
  `SensorObservation.corroborationFor` (RANGE ≤ 0.25, BEARING ≤ 0.20,
  BINARY 0.10, MOTION 0.15; SPECTRUM/ENERGY 0 — see
  sensor_protocol_spec.md §5). Asserted non-negative at construction.
- `w_s`: measured information content — observation freshness vs the
  per-type staleness horizon, source health (driver alive / recent
  data), and the geometry-alignment quality channel. Multiplicative:
  any single zero collapses the weight.
- `U`: exponential approach to the cap — one strong corroboration
  counts ~linearly, N weak triggers asymptote. Ten weak PIR triggers
  reach +0.33 and can never pass +0.35.
- Upgrades are **suspended** (`U = 0`) while the track is internally
  inconsistent (see below).

## Literature basis

- **AV-FDTI (P5, lane3 §2.1):** asymmetric, entropy-gated fusion —
  F̃ = h·F_visual + (1−h)·F_audio, the always-available modality
  (their audio, our RF mesh) carries the track; the conditional
  modality contributes only when its predicted information content h
  is high. Their decisive ablation: the *ungated* network (ASDNet)
  got the **worst** localization of all methods tested — worse than
  the best single sensor — because it leaned on a degraded modality.
  Our `w_s` is the h-gate; "stale sensor ⇒ w = 0" is "h → 0 ⇒ ~100%
  weight on the always-available modality." The gated-vs-ungated
  ablation in `test/confidence_merger_test.dart` is the regression
  test for this result.
- **NEES consistency (P8, lane3 §2.5):** overconfident covariances
  shrink gates → missed associations and track fragmentation; RMSE
  alone is "insufficient" (their overconfident variant had similar
  RMSE but diverging NEES). The app tracker has no covariance, so we
  run the honest analogue: fix-to-fix innovation normalized by the
  tracker's expected fix-error scale (see below). The Stone Soup
  bench (`tools/stone_soup_bench/`) runs the *true* NEES on its
  Kalman filters — and immediately caught the bench's own
  overconfidence (mean NEES ≈ 66 vs ideal 4: the link-midpoint
  detection stand-in carries unmodeled bias).

## Honesty boundaries — what w_s measures vs what it doesn't claim

**Measures:**
- Whether the observation is *fresh enough to be about the current
  track* (age vs per-type staleness horizon: 10 s for fast frames,
  30 s for energy/camera, 2 min for PIR events).
- Whether the *source* is alive with recent data (sensor-bus
  last-poll ≤ 90 s; camera integration enabled with recent motion).
- Whether the observation *geometrically lined up* with the track
  (the quality channel — closeness for RANGE, angular alignment for
  BEARING).

**Does NOT claim:**
- `w_s` is not a sensor accuracy rating, a calibration certificate,
  or a probability. It is a recency × liveness × alignment weight —
  "is this evidence fresh, live, and on-target," nothing more.
- `C_RF` is not P(exists). It is a saturating function of how many
  independent links the deterministic tracker disturbed — a display
  heuristic that keeps the RF core as the detection authority.
- `C_display` is not P(target is real). It is the displayed
  confidence of a track the RF tripwire already supports, upgraded
  only by corroboration, never downgraded by anything.
- Silence is never evidence of absence: a missing sensor, a stale
  observation, or a geometry miss contributes exactly 0 — never a
  penalty, never a veto. (Camera MOTION silence is the canonical
  case: occlusion, night, facing-away all produce silence.)

## The consistency monitor (honest NEES analogue)

`lib/services/track_consistency.dart`. Per fused-track fix: predict
from the last two fixes (constant-velocity extrapolation), compare
against the actual fix, normalize by the expected fix-error scale
(1.0 m — coarse grid step 2.5 m ⇒ quantization σ ≈ 0.72 m/axis, plus
model noise, rounded honestly), with √-growth in extrapolation
distance. Flag after 3 consecutive >3σ innovations; clear after 5
consecutive <1.5σ; a long gap resets rather than flags (stale
velocity state is not inconsistency).

Feeds two consumers: (1) the tracking screen's `TRACK STATE:
INCONSISTENT` operator flag; (2) the merger gate — no upgrades while
inconsistent, because upgrading a misassociated track is exactly the
failure P8 warns about.

What it is not: it is not a covariance, not a NEES, not a
probabilistic data-association score. It cannot see a *smoothly
wrong* track (consistent misassociation) — only jumps the motion
model can't explain. The true NEES lives in the Stone Soup bench,
where filters have covariances to check.
