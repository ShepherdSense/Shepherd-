# RTI Imaging Weights — Multi-Scale Spatial Model Spec

**Status:** implemented in v0.17.0; field validation pending. **RX-only, defensive-only.** This
spec changes how received-signal disturbances are *weighted into an
image*; nothing transmits, jams, deauths, spoofs, or probes. The
output remains a disturbance heatmap — blobs and trails, never
imagery, never identity, never fire-control-quality tracks.

**Honesty contract (load-bearing):** the paper below was validated at
30–33 nodes, 2D, ground-plane, stationary humans. Shepherd runs
6 nodes / 15 links against airborne Group 2–3 UAS. What ports is the
**method** — fade-signed, direction-split, area-normalized weighting.
The paper's ellipse parameters and its ≤ 0.30 m accuracy figure do
**not** port; field validation re-measures from zero. Any UI text
from this feature says "estimated disturbance", never a located
object.

## Goal

Replace the heatmap's current implicit weighting with the
multi-scale spatial model of Kaltiokallio, Bocca & Patwari, so that
(1) RSS *rises* on deep-fade links and *dips* on anti-fade links are
modeled as separate evidence instead of being folded into
`|Δr|`, (2) links are weighted by inverse ellipse *area* so diffuse
deep-fade links stop smearing the image, and (3) every band/sub-band
is treated as an independent virtual link. This matters *more* at
6-node sparsity than in the paper's 30-node regime: with 15 links,
one smeared deep-fade ellipse can dominate the whole image.

## Background — Kaltiokallio, Bocca & Patwari, arXiv:1302.5914 (2013), READ IN FULL

**CONFIRMED** (full read, >26M RSS measurements, 30–33 nodes, all 2D
at node height; parameters held fixed across open / apartment /
through-wall environments):

- **"Multi-scale" means two things at once.** Per
  (channel, link, RSS-change-direction) **ellipse sizing**:
  `λ^δ_{c,l} = b^δ_λ · e^{F / k^δ_λ}`, where `F` is the link's fade
  level and `δ ∈ {−, +}` is the direction of RSS change. Table I:
  `δ=−: k = −5.7874, b = 0.2112`; `δ=+: k = 102.73, b = 0.5016`.
  **Plus area-normalized weights** `w = 1/(n_j · p²)` so that diffuse
  deep-fade links (large ellipses) don't smear the image.
- **The measurement vector is a probability, not Δr:**
  `p^δ_{c,l} = 1 − exp(−β·|Δr|)`, stacked to length `2LC`
  (L links, C channels, 2 directions). `β⁻ = 0.1172` fixed;
  `β⁺ = 0.1839·e^{F/13.0018}`. Direction of change is a
  **first-class model axis**, not a sign to be discarded.
- **Channel DIVERSITY beats channel SELECTION** — CONFIRMED: 2-channel
  multi-scale RTI outperformed 5-channel fade-level-selected RTI
  through-wall (0.30 m vs 0.70 m mean error). More independent
  measurements beat fewer "good" ones.
- **Critical implementation detail:** per-channel TX-power
  normalization `P_T(c) = 0.1452·c + 1.7332 dB` was *needed* on
  CC2531s to unbias fade levels (antenna impedance varies across the
  band). Without it, the fade-level term `F` in both `λ` and `β⁺`
  misfires.

**Explicitly absent from the paper:** no 3D / height term; nodes
static; online recalibration listed as future work (see
`adaptive_baseline_spec.md` — ARTI is our answer to that gap).

## Proposed design

Four changes to the imaging pipeline in `lib/screens/tracking.dart`
(heatmap) / `lib/services/tracker.dart`, fed by `tripwire.dart`.

### 1. Split the pipeline by RSS-change direction

Today the tripwire already computes fade-signed deviation (dip on
anti-fade links, rise on deep-fade links — `tripwire.dart`). The
imaging layer currently folds that into a single magnitude. New
pipeline: maintain **two measurement vectors**, `p⁻` (RSS decreased)
and `p⁺` (RSS increased), each with its own ellipse set and
probability mapping:

- `p^δ_{c,l} = 1 − exp(−β^δ·|Δr^δ|)` per direction, `δ ∈ {−, +}`.
- Ellipse excess-path parameter `λ^δ_{c,l}` computed per direction
  from the link's fade level — anti-fade links get tight ellipses
  on `δ=−`, deep-fade links get tight ellipses on `δ=+`, matching
  the physics the tripwire already assumes.
- The two images are fused (summed) *after* weighting, never before
  — summing `|Δr|` first is what lets a rise and a dip on the same
  pixel cancel or double-count.

Shepherd's `β`/`λ` parameters are **not** the paper's Table I
values — those were fit to CC2530 2.4 GHz Zigbee channels in
rooms. Ours are fit per band (below) from our own calibration
data, starting from the paper's *functional forms*.

### 2. Weight by inverse ellipse area, not 1/√d

Replace the current distance-based falloff with area normalization:
each link-direction's contribution is scaled by the inverse of its
ellipse area (paper form `w = 1/(n_j · p²)`, adapted to our pixel
grid). Rationale, stated plainly: at 15 links, a deep-fade link's
diffuse ellipse covers a large fraction of the surveillance area —
without area normalization it contributes nearly uniform "maybe
everywhere" mass that washes out the tight ellipses of anti-fade
links. This is the single highest-leverage change for the sparse
regime.

### 3. Characterize per-band effective TX power on OUR radios — before anything else

The paper's `P_T(c)` correction exists because fade level `F` is only
meaningful if static RSS is comparable across channels. Our bands
are far more heterogeneous than 16 Zigbee channels:

| Band / radio | What we measure | Normalization needed |
|---|---|---|
| Silvus 2440 MHz | per-direction `$snr`, per-chain `$pcns` | SNR is already ratio-normalized; map to an effective-RSS scale per chain before fade-level computation |
| ESP32 2.4 GHz | WiFi RSSI / CSI | per-channel RSSI offset characterization |
| CC1101 433 MHz | RSSI @ 433.92 MHz | single-band offset |
| SX1276 915 MHz | LoRa RSSI/SNR | single-band offset |
| SDR bridge bands (433/915/1290/2437/5780 MHz) | dBFS energy per band | per-band, per-radio dBFS-to-dBm mapping |

**Pass criterion for this step:** with a known attenuator stepped in
the lab, per-band fade levels agree within 2 dB. Until that holds,
the `λ`/`β` model misfires exactly the way the paper warns about —
this characterization is a prerequisite, not a polish item.

### 4. Every band/sub-band is an independent virtual link

Consistent with the SDR-bridge convention (each band = one virtual
link feeding the tripwire): the imaging weight matrix stacks
`2·L·C` rows (L physical links, C bands/sub-bands, 2 directions).
Channel diversity is the CONFIRMED win — a 6-node mesh with 4 bands
is 15·4·2 = 120 measurement rows, which is the closest thing we
have to the paper's measurement richness. Computationally trivial
(tiny matrices; phone-class CPU is fine).

## Open research question — Fresnel-zone weighting for sparse RTI (MANDATORY, UNVALIDATED)

Carried as an open question, **never as a claim**:

Fresnel-zone-based link weighting for *sparse* RTI is **unvalidated
in the literature we have read**. Specifically: MFDL
(arXiv:1707.07514 — authors Wang, Zhang, Niu, Lv, Liu, Wu, Gao, Xie;
**not** "Seifeldin et al.", a misattribution found in secondary
discussion) is a **per-link close-range localizer**, not an RTI
link-weighting upgrade — it never compares against, and never
replaces, the RTI ellipsoid model. Citing MFDL as support for
Fresnel-weighted RTI would be a category error.

What remains genuinely open: whether replacing or augmenting the
ellipsoid spatial model with Fresnel-zone geometry improves
localization at 6-node sparsity, where the ellipsoid's far-field
assumptions are weakest. This needs its own experiment (synthetic
first, field second) before any claim is made. **Do not implement
Fresnel weighting on the strength of MFDL.**

## Integration points (actual files)

- **`lib/screens/tracking.dart`** — the heatmap. Consumes the two
  direction-split, area-normalized images; renders the fused result.
  No geometry changes; the pixel grid stays 2D ground-plane (see
  Limits).
- **`lib/services/tracker.dart`** — owns the weight matrix `W`
  construction (ellipses per link-band-direction, area
  normalization) and the probability measurement vector. The
  Kalman / data-association tracker itself is unchanged; it
  consumes the improved image.
- **`lib/services/tripwire.dart`** — supplies per-link-band
  fade-signed `Δr` split by direction (dip vs rise), per-link fade
  level `F_l`, and MAD thresholds. The direction split already
  exists in the deviation computation; this spec promotes it to a
  first-class output.
- **`lib/services/adaptive_baseline.dart`** (new, specified in
  `adaptive_baseline_spec.md`) — supplies drift-compensated `mu`
  so `Δr` and `F_l` stay honest on a moving mesh; ARTI's `phi` sign
  feeds the direction assignment.
- **`lib/services/health.dart`** — links whose fade level sits in
  deep fade *and* whose TX characterization is missing are flagged,
  so the imager never silently trusts an uncalibrated band.

## Honest-scope limits

- **Node-count regime:** 6 nodes / 15 links is far below the
  validated 30–33-node regime. The method ports; no accuracy number
  ports. The ≤ 0.30 m through-wall figure is cited as a paper
  result only — it is not a Shepherd claim, target, or requirement.
- **2D model, 3D targets:** the paper is 2D at node height;
  Group 2–3 UAS are airborne. We import the *method*
  (fade-signed, direction-split, area-normalized), not the
  geometry. The heatmap remains a ground-plane projection: a
  target at altitude projects its link-shadow onto the plane, and
  the image peak is the *shadow centroid estimate*, not the
  target's position. Say this in the UI ("estimated disturbance
  location (ground projection)").
- **Parameter refit required:** Table I `k`/`b` and `β` values are
  CC2530-in-rooms fits. Ours must be refit per band from our own
  calibration data (§3 table). Shipping with the paper's numbers
  would be cargo-culting.
- **No identity, no imagery, no fire-control tracks:** the image
  is a probability mass over pixels. It supports "something
  disturbed these links here" — nothing more.
- **MFDL is not an upgrade path** (see Open question). Fresnel
  weighting stays out of the build until its own experiment
  validates it.

## Test / validation plan

Synthetic-first; every test asserts *relative* improvement or a
behavioral property, never an absolute accuracy number.

1. **Direction split, no cancellation.** Synthetic: one anti-fade
   link dipping + one deep-fade link rising, same ground-truth
   pixel. **Pass:** both contribute positive mass at the true
   pixel; the fused peak is within 1 pixel of truth; a control run
   folding into `|Δr|` first shows measurably lower peak mass
   (proving the split preserves evidence).
2. **Area normalization vs 1/√d.** Synthetic: one deep-fade link
   (large ellipse) + one anti-fade link (small ellipse), same
   truth. **Pass:** peak-to-sidelobe ratio with area normalization
   ≥ 2× the 1/√d control; the peak sits inside the small ellipse,
   not smeared across the large one.
3. **Channel diversity.** Synthetic track, C = 1..4 bands as
   independent virtual links vs best-single-band selection.
   **Pass:** diversity localization error ≤ selection error on
   ≥ 80% of track points (relative win only — mirrors the paper's
   CONFIRMED diversity result without claiming its numbers).
4. **TX-power characterization gate.** Lab attenuator steps, all
   bands in the §3 table. **Pass:** per-band fade levels agree
   within 2 dB. **This gates implementation of §1–2** — no
   characterization, no model.
5. **Parameter refit sanity.** Fit `k`/`b`/`β` functional forms to
   our own calibration crossings. **Pass:** fitted curves are
   monotonic in the physical direction (deeper fade → larger
   `λ⁻`-style ellipses for the diffuse direction); refit completes
   offline; values logged, not hardcoded.
6. **Sparsity stress.** 6-node / 15-link synthetic mesh, crossing
   target. **Pass:** image peak tracks the crossing (peak within
   3 m of truth on ≥ 70% of fixes) *without* any single link
   dominating — ablation removing the strongest link must not move
   the peak more than 3 m (robustness, not accuracy).
7. **Honesty contract (UI strings).** Mirror the ELRS honesty tests:
   heatmap/track labels assert "estimated"/"possible" language and
   never "located"/"identified"/"confirmed". **Pass:** test suite
   green.
8. **Fresnel question stays a question.** **Pass:** no Fresnel
   weighting code in the tree; the open-question section of this
   spec is still accurate at release. (A test that fails if
   someone "helpfully" implements it from MFDL.)

## Files (to be created/modified on implementation)

- `lib/services/tracker.dart` — weight-matrix `W` construction
  (per-link-band-direction ellipses, area normalization),
  probability measurement vector, per-band parameter tables
- `lib/screens/tracking.dart` — render direction-split/fused
  image; ground-projection labeling
- `lib/services/tripwire.dart` — direction-split `Δr` and `F_l` as
  first-class outputs
- `lib/services/adaptive_baseline.dart` — drift-compensated `mu`,
  `phi` sign for direction assignment (specified in
  `adaptive_baseline_spec.md`)
- `lib/services/health.dart` — uncalibrated-band flagging
- `test/` — direction-split, area-normalization, diversity,
  honesty-contract tests
