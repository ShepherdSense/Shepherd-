# BSense / MilaGro / size-aware tracker gating (v0.25.0)

Portable parts of three papers, fitted into Shepherd's existing tracker
architecture (gated confidence merger, tripwire). The tracker itself is
NOT rewritten: these are opt-in gating layers in
`lib/services/tracker_gating.dart` with thin hooks in
`lib/services/tracker.dart` (`Tracker` constructor options,
`Tracker.update` size plumbing, `Tracker.gateRtiCells`). Default
construction (`Tracker()`) behaves exactly as before — no behavior
change, no wire-format change (UDP formats and the 10-feature
classifier contract are untouched).

## 0. What is NEVER claimed here

- **Shepherd has no 5G-A base station.** BSense's 1 km range, F1 95.56%
  (precision 96.73%, recall 94.41%), and 4.9 m mean localization error
  belong to a live Huawei COTS 5G-A base station in Shanghai (4.9 GHz,
  100 MHz, 128 channels, 23 m height). They are benchmarks for what
  infrastructure sensing can do, NOT Shepherd numbers, and must never
  be quoted as Shepherd performance.
- **The 6-node / 15-link ~1–2 m imaging bound is NOT upgraded.** No
  paper in this scope supports that. Kim et al. (below) in fact
  *warns* in the other direction for few-node plain-RSS regimes.
- **No MilaGro accuracy numbers are claimed.** Their 100% fused lab
  presence / 94% corridor tracking are classification accuracies on
  trained labels (80/20 split, same-day collection), not meters of
  Shepherd localization.
- **No new detection range is claimed** by the size-aware thresholds.
  They rescale an existing threshold; range is a field measurement,
  not a parameter.
- Everything emitted is a disturbance / blob / trail / bearing /
  estimate — never imagery, silhouettes, confirmed identity, or
  fire-control-quality tracks. Confidence saturates below 1.0, as in
  the confidence merger.

## 1. BSense portable false-alarm recipe (Meng et al., arXiv:2603.29187)

BSense's problem, quantified: raw point clouds contain 168.05 noise
points per frame vs 1 UAV point, and noise features overlap the UAV's
so plain thresholds fail. Its layered filter (stage gains measured on
the 5G-A system): (1) per-cell Gaussian clutter fingerprint cuts noise
168.05 → 64.15/frame (−61.8%, 1.7% UAV loss); (2) decayed
spatial/velocity consistency cuts false objects 61.34 → 2.58/frame
(−95.79%, 87.64% recall); (3) TrajFormer transformer → 0.04
false/frame. **Only stages 1 and 2 port, and only in adapted form.
Stage 3 (TrajFormer) does NOT port — it is ML, and Shepherd's tracker
is deterministic by design.** Stage gains are BSense's, not Shepherd's;
Shepherd gains are unmeasured until field data exists.

### 1a. Per-spatial-cell Gaussian clutter fingerprint + Mahalanobis gating

Replaces global thresholds for link-shadow false alarms — for links
whose midpoint cell has a trusted fingerprint. Implementation:
`ClutterFingerprint` in `lib/services/tracker_gating.dart`, wired in
`Tracker._applyClutterGate`.

| Paper value | Shepherd value | Why |
|---|---|---|
| Per-40 m cube, multivariate Gaussian over point-cloud features | Per-10 m cell, univariate Gaussian over link dip (radio units) | Field scale: BSense's cell is a 1,000 m 5G-A cell; Shepherd's mesh field is of order 100 m across with 30–60 m links and tracker sigma ≈ 11 m. A 40 m cell would be most of the field (2–3 cells, no locality). 10 m ≈ tracker sigma: local, yet large enough to accumulate samples. Feature vector: Shepherd's tracker input is link dips, not point clouds — there are no multivariate point features to fingerprint, so the *form* ports (per-cell Gaussian, percentile Mahalanobis gate, periodic refresh) and the feature does not. Stated, not hidden. |
| k = 80th percentile | \|z\| ≤ 1.2816 (two-sided 80% standard-normal interval) | Univariate analogue of the paper's percentile gate. BSense's multivariate version uses a chi-square percentile; the 1-D \|z\| form is the honest equivalent, not the same statistic. Only k = 0.80 is supported: constructing a fingerprint with any other `percentileK` throws `ArgumentError` rather than silently clamping to the 80% value. |
| ~10 min init | 20 quiet samples per cell (`minSamplesPerCell`) | BSense sees ~168 points/frame; Shepherd sees ~1 poll's link samples. Absolute frame counts do not port across a ~100× observation-density gap. 20 quiet samples is attainable in one quiet session while still being a distribution, not a single reading. Cells below this are untrusted and fail open (see below). |
| Refresh ~every 2 days / 700 frames | Refresh at 700 Tracker.update polls OR 2 days, whichever first — implemented as halving effective sample weight (count and M2 × 0.5, mean kept as prior), floored at `minSamplesPerCell` with M2 scaled by the same ratio as the count | A full reset would discard a session's clutter learning and fail open everywhere at once. Weight-halving re-anchors on new clutter without a blind re-init window. The 2-day bound ports verbatim; the 700-frame bound ports as tracker polls (counted by `ClutterFingerprint.notePoll`, one call per `Tracker.update` — counting observe calls would fire the refresh every ~50 polls, since one poll feeds ~15 pairs). The floor matters: without it, halving a 25-sample cell to 12 would drop it below the default trust bar of 20 and untrust a cell the refresh was supposed to keep live. |
| Noise fingerprint learned from background | Learned from QUIET link samples only (dip below the link's own threshold) — NEVER from disturbed samples, including disturbed samples the gate demoted as clutter-like | Feeding disturbed samples would teach the fingerprint that targets are clutter. The tracker wiring (`_applyClutterGate`) observes exactly the quiet pairs and never any disturbed pair. The demoted case is the sharp one: a real slow/loitering target demoted once would otherwise shift the cell mean toward its own dip on every poll and could never re-emerge. |
| Gate rejects clutter | `gate()` returns clutter-like when \|z\| ≤ threshold, target-like otherwise; untrusted cell → target-like (fail open) | A gate that blocks detections on cells it has never seen trades false alarms for blind spots. Fail-open is the safety direction for a defensive sensor: a false alarm is annoying, a blind cell is a hole. |
| Sigma from data | Sigma floored at 0.5 radio units (`sigmaFloor`) | Stops a perfectly flat (quantized) link from giving sigma ≈ 0, which would make any tiny wiggle an infinite Mahalanobis distance and pass everything as target-like. |

Wiring notes: a link contributes its quiet dip to the cell containing
its midpoint. A disturbed link is gated against its midpoint cell's
fingerprint; demoted links drop out of the tracker's disturbed set, so
if all disturbed links are demoted the poll yields no track (the
disturbance is still visible to the tripwire/banner path — the gate
lives in the tracker, not in detection). The fingerprint is NOT reset
by `Tracker.reset()`: clutter learning is long-lived, not per-track
state.

Known approximation for field calibration (midpoint-cell
attribution): a 30–60 m link is taught/gated only at its midpoint
cell, while the link itself spans 3–6 ten-metre cells. Clutter that
lives off-midpoint along the link is therefore attributed to the
wrong cell (and a target crossing the link's ends is gated against a
cell it never occupied). This is a deliberate simplification — the
tracker has no per-segment dip measurement to attribute with — but
calibration should check whether long-link cells need midpoint
smearing or per-segment attribution before trusting cell-level
clutter maps on long links. Non-finite positions or dips fail open
(target-like, never blind) and never reach cell keying, which would
otherwise throw on NaN/Inf coordinates.

### 1b. Decayed (0.9) spatial/velocity consistency confidence gate

Implementation: `DecayedConsistencyGate` in
`lib/services/tracker_gating.dart`, fed by `Tracker.update` when
attached. It runs over the tracker's own fix sequence (constant-
velocity prediction, same shape as `TrackConsistencyMonitor`).
`TrackConsistencyMonitor` stays the operator-visible inconsistency
flag; this gate is the *false-track verdict* the merger / strict
tracker mode can act on. By default the gate REPORTS (via
`Tracker.lastConsistencyGate`) and does not veto — mirroring the
monitor, which suspends corroboration upgrades, not detection.
`consistencyGateStrict: true` opts into veto (failing verdict → no
estimate). Default construction is unchanged either way. Strict mode
delays first reporting by one consistent fix: confidence starts at
0.5 and passes only when strictly above it, so the first fix is
always suppressed in strict mode and the second (consistent) fix is
the first one reported. A vetoed estimate leaves no tracker state
behind: the tracker snapshots fixes, velocity, and last-detection
time before the gate check and restores them on veto, so a vetoed
stream cannot drive velocity and cannot keep a dead track alive past
the 10 s idle reset.

| Paper value | Shepherd value | Why |
|---|---|---|
| Decay 0.9 | 0.9, verbatim: c ← 0.9·c + 0.1·instant, instant = 1 on match else 0 | Dimensionless recurrence; ports exactly. Missed polls also decay (c ← 0.9·c), floored at 0.4 and never raised by missed polls: without the floor, a sub-10 s quiet spell at 4 Hz (~36 missed polls) drives confidence to ~0.01 and re-appearance needs ~7 consecutive passing fixes to re-exceed 0.5; floored at 0.4, re-confirmation takes exactly 2 passing fixes (0.4 → 0.46 → 0.514). |
| Prediction timing | Evaluated whenever both time steps are positive (dt1 > 0 and dt0 > 0), with the extrapolation clamped to 4× | Drivers poll at ~0.25 s, so a ≥ 0.5 s guard would mean the prediction is never tested at app cadence and strict mode could never veto. A genuinely uncomputable prediction (zero time step, duplicate timestamps) leaves confidence unchanged and says so in the reason — it is never scored as a pass (instant = 1.0 on a skipped prediction would let an untested track through) and never as a fail. |
| Match < 15 m | `spatialMatchM` = 6.0 m | BSense localization error is 4.9 m mean, so 15 m ≈ 3× its error. Same 3×-error rule at Shepherd's ~1–2 m imaging bound gives ≈ 6 m. 6 m also exceeds the tracker grid step (2.5 m) plus fix error (~1 m), so grid quantization alone cannot fail a match. |
| τ_s = 1.7 | 1.7, verbatim, as the dimensionless threshold on residual / spatialMatchM | A fix passes spatially when residual ≤ 1.7 × 6 m = 10.2 m. Loose on purpose: this is a false-track gate (prune wild jumps), not a localization test, and the 0.9 decay requires sustained passing. |
| τ_v = 1.1 | 1.1, verbatim, as the dimensionless threshold on \|Δspeed\| / 1 m/s | The 1 m/s scale is the Shepherd fix scale (fix error ~1 m over ~1 s fixes). Starting estimate to field-calibrate, NOT a paper result — the paper's τ_v is dimensionless and its internal normalization is not reproduced in the lane notes, so the scale choice is documented as ours. |
| (no paper gate level) | Gate passes only when confidence is STRICTLY above 0.5 | Shepherd's threshold, labeled as such. A single fix starts at 0.5 and therefore never passes alone — the gate needs ≥ 2 consistent fixes. In strict mode this means strict mode delays first reporting by one consistent fix: the first fix is always suppressed and the second (consistent) fix is the first reported. |
| Gap handling (paper: trajectory gaps, see §4) | Gap > 10 s resets the gate (`gapReset`, matching the tracker idle reset and the monitor's gap reset); `noteGap()` reports gated-out until re-acquisition | The gate does NOT bridge gaps; it reports the break and re-confirms with ≥ 2 consistent fixes. |
| Velocity missing | Velocity check skipped, never failed | Missing velocity info is uninformative (tangential motion, RF-quiet geometry), not evidence against the track — same null-is-uninformative rule as the merger's Doppler handling. |

## 2. MilaGro gate pattern (Picazo-Martinez et al., arXiv:2507.22591v2)

MilaGro's portable pattern — NOT its CNN: mmWave beam-training data
pre-classifies as a coarse LOS gate, then 5 GHz beacon CSI
disambiguates within the gated space. Implementation: `MilagroGate`
in `lib/services/tracker_gating.dart`, exposed on the tracker as
`Tracker.gateRtiCells`. NO ML, NO CNN, no import of their model, no
accuracy numbers carried over.

| MilaGro element | Shepherd gate element | Why |
|---|---|---|
| Sharp channel: mmWave beam-training (sharpest, shortest-range) | Disturbed anti-fade links (tight λ ellipses) and/or shortest links — caller supplies support points (`SharpSupport`, e.g. disturbed anti-fade link midpoints) | Same shape as Shepherd's existing anti-fade-link gating: the tightest spatial evidence prunes the search space. The class does not decide what "sharp" is, so either definition feeds it without code change. |
| Broad channel: 5 GHz CSI disambiguation | RTI image cells / grid candidates (`Tracker.gateRtiCells`) | The broad-coverage channel resolves within the gated space. |
| Fusion tolerates 100 ms inter-band skew, no tight sync | `skewTolerance` = 2 s | Shepherd polls at ~0.25–1.5 s, not 100 ms frames. A 100 ms window would expire every sharp support before the broad channel saw it. 2 s ≈ one tracker cycle scale. Timestamped supports older than this are dropped; untimestamped supports count as fresh. |
| mmWave alone: 100% at LOS, 52% at NLOS | Fail-open: empty live sharp set → ALL broad candidates pass unchanged | The paper's own lesson: sharp silence proves nothing (NLOS). The sharp channel prunes only when it speaks; it never vetoes by silence. |
| Gate radius | `radiusM` = 10 m (≈ tracker sigma / one RTI neighbourhood) | MilaGro's gate is a LOS/beam sector, not a meter radius, so the radius is a Shepherd starting estimate, not a paper number. |

## 3. Size-aware detection thresholds (Kim et al., arXiv:2505.04085v2)

Kim et al. (lane1 §6.12.1, CONFIRMED measurement on a 4-node SDR
distributed-antenna network): a larger human subject moderately
increases error, a slimmer subject significantly degrades detection
across the distribution — body size directly scales MPC shadowing.
Shepherd implication, adopted here: thresholds must be size-aware,
not one global threshold. Implementation: `SizeAwareThresholds` in
`lib/services/tracker_gating.dart`, plumbed into `Tracker.update` via
`sizeThresholds` + `expectedSizeClass` (the fallback threshold for
samples carrying no per-link threshold of their own).

| Size class | Factor (× base threshold) | Why |
|---|---|---|
| S (slim / small UAS) | 0.7 | Weaker dips need a lower bar, or a threshold tuned for M/L systematically misses S. |
| M | 1.0 | The global threshold, unchanged. |
| L | 1.3 | Strong dips tolerate a higher bar, which admits less clutter. |
| Unknown | 1.0 | The global threshold, unchanged. |

The factors are starting estimates to field-calibrate, NOT paper
numbers — Kim et al. report a qualitative degradation, no threshold
factors. This is plumbing, not a detection-range claim, and it does
NOT upgrade the 6-node/15-link ~1–2 m imaging bound: Kim et al.
rescues few-node regimes with MPC/array multiplication, not plain
RSS, and their plain single-antenna result (4–8 nodes degrade, ~12
acceptable) is a second independent confirmation that the bound
stands.

**Circularity warning (misuse to avoid):** the tracker's own size
class is derived from dip depth, so `expectedSizeClass` must be an
EXPECTED size (operator setting, classifier prior, mission profile),
never the size class of the very dip being thresholded. Feeding the
track's own size class back in would be circular.

## 4. KNOWN LIMITS (BSense failure modes, inherited)

These are documented in code comments and here, and must survive into
any operator-facing text that mentions these gates:

1. **Tangential-flight blindness.** BSense: on ∞/M/☆ paths the drone
   produces no return at all (building occlusion + tangential flight)
   — a sensor miss, not a filter miss. Shepherd analogue: a target
   moving so it produces no new link disturbance yields no fixes, and
   a gate over fixes cannot confirm what the sensor never saw.
   Absence of fixes is NOT confirmation of absence. Separately, an
   abrupt direction change (including a tangential geometry change)
   decays consistency confidence exactly like misassociation does —
   the gate cannot tell a maneuver from a misassociated track.
2. **Occlusion gaps (BSense: 50–100 m trajectory gaps).** A long gap
   breaks continuity. This gate resets on gaps (> 10 s) instead of
   bridging them; the track must re-confirm. Do not present a
   re-acquired track as a continuous one.
3. **Doppler/continuity assumptions are exploitable by a knowledgeable
   operator** (BSense authors' own caveat, CONFIRMED from the paper,
   untested by them): an operator who understands the
   spatial-continuity + velocity-consistency assumptions can fly to
   defeat them. This gate is a false-alarm reducer, not a guarantee,
   and must never be described as defeating evasive flight.
4. **BSense stage gains do not transfer.** The −61.8% / −95.79%
   figures are 5G-A point-cloud measurements. Shepherd's gains from
   these gates are unmeasured until field data exists; the parameters
   above are starting estimates, and the 80th-percentile / τ values
   are the only numbers ported verbatim (plus the 0.9 decay and the
   2-day refresh bound).
5. **Single-target tracker, as before.** If two objects cross at once,
   the estimate is their blend. These gates do not add multi-target
   tracking, and the MilaGro gate does not add classification.

## 5. Integration notes for the coordinator

- Wiring still open (not in this change, to keep default behavior
  identical): `app_state.dart` attaching a `ClutterFingerprint` /
  `DecayedConsistencyGate` to its `Tracker`, feeding
  `lastConsistencyGate` into the merger the way `trackConsistency`
  already suspends upgrades, and building `SharpSupport` points from
  disturbed anti-fade links for `gateRtiCells`. The hooks exist; the
  policy choice (strict vs report-only, expected size source) belongs
  to the coordinator, not to this builder.
- Field calibration TODO (do not skip before quoting performance):
  refit cell size, `minSamplesPerCell`, τ scales, gate radius, and
  size factors on recorded Shepherd data; log tuned values per
  deployment (Kim et al.'s parameter-tuning discipline).
- Tests: `test/tracker_gating_test.dart` — fingerprint init/update,
  Mahalanobis accept/reject (including fail-open and sigma floor),
  decayed consistency (including the tangential-motion and
  occlusion-gap cases, both labeled as limits), MilaGro pruning
  (including fail-open on sharp silence / stale support),
  size-aware thresholds (unit + tracker plumbing), and tracker
  wiring (fingerprint demotion, strict vs non-strict consistency).
  Review-fix tests added: 0.25 s-cadence wild jumps fail the gate,
  zero-step predictions leave confidence unchanged, strict veto +
  >10 s idle resets, refresh floors at `minSamplesPerCell` (25 stays
  trusted at the default 20) and counts polls not observes, non-0.80
  percentileK throws, non-finite inputs fail open, demoted dips never
  feed the fingerprint, the 36-missed-poll re-appearance re-confirms
  in 2 fixes, and the geometry-starved poll counts as a missed poll
  without refreshing last-detect.
