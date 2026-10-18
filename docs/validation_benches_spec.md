# Validation Benches — Real-Data Replay Harness & ESP32 CSI Frame-Rate Bench

**Status:** implemented in v0.17.0; field validation pending. **RX-only.** Both benches listen,
record, and score — neither transmits, jams, deauths, or spoofs. The
harness is an offline design tool; nothing in it ships in the app.

**Goal:** close the validation loop the program is missing. Shepherd's
fusion pipeline (gated confidence merger, innovation monitor, track
stitcher) and its CSI feature work are currently validated against
synthetic data only. This spec adds two benches: (A) a public real-data
dataset replayed through the fusion machinery, and (B) a one-measurement
go/no-go bench for ESP32 CSI frame-rate feasibility.

## Honesty contract (load-bearing)

- **The AERPAW replay validates the fusion machinery, not Shepherd's
  end-to-end detection of non-cooperative targets.** The dataset's RF
  side tracked the UAV's own emission (cooperative in the RF sense);
  Shepherd's tripwire detects non-cooperative link disturbance. Say this
  in the UI evidence copy, in the README, and in any test report: the
  harness scores what Shepherd's tracker *does with* real trajectories,
  not whether Shepherd's sensors would have seen this target.
- **The CSI bench measures raw CSI frame-rate feasibility on ESP32,
  nothing more.** It does not validate Fresnel-zone weighting for sparse
  RTI — that remains an unvalidated research lead (see § Fresnel lead).
  A passing frame-rate number must never be quoted as a localization
  result.
- Every claim in this spec is labeled **CONFIRMED / WIDELY REPORTED /
  CLAIMED**. Nothing in it is presented from a partial read — both
  source papers were read in full; anything not fully read is marked
  UNREAD and never enters the docs as established.

## Background: what the two papers actually showed

### Dickerson et al., AERPAW field trial, arXiv:2512.14608 (Dec 2025) — READ IN FULL, CONFIRMED

A public field trial fusing RF time-difference-of-arrival (TDOA) with a
Fortem TrueView Ku-band radar for drone tracking, with the dataset
released publicly **including RTK ground truth**. The paper's central
finding, confirmed in the results section: **fusion's win is outlier
suppression plus coverage, not mean-error reduction.** Fused mean error
was 21.9 m at 100% coverage. The measured radar cross-section of the
hexacopter test target was 0.0066–0.549 m² with a mean of 0.12 m² at
Ku-band (CONFIRMED).

What this validates for Shepherd — and what it does not:
- **CONFIRMED from the paper:** the public dataset exists with RTK
  ground truth and is suitable for offline replay scoring.
- **CLAIMED (adopted as a design pattern, not a paper result):** the
  fusion build pattern the trial's track management implies —
  NIS-gating + range-gate + coast-on-prediction. This is a sound
  engineering pattern to adopt; the paper is evidence it works in a
  comparable fusion setting, not a proof it ports to Shepherd's
  tripwire geometry.
- **Explicit non-transfer:** the RF side tracked the UAV's own emission
  (cooperative in the RF sense). This caveat travels with every replay
  result.

### Wang, Zhang, Niu, Lv, Liu, Wu, Gao & Xie, "MFDL", arXiv:1707.07514 — READ IN FULL, CONFIRMED

**Authorship correction, carrying forward:** the citation that surfaced
in the research sweep as "Seifeldin et al." is wrong. M. Youssef is a
cited author, not a paper author. The authors are Wang/Zhang/Niu/Lv/
Liu/Wu/Gao/Xie (Peking University / UC Boulder). The file records this
so the mis-citation does not propagate.

What MFDL actually is — and is not — CONFIRMED:
- **It is a per-link close-range localizer**, not a knife-edge-diffraction
  replacement for RTI's ellipsoid link weighting, and not an RTI
  weighting upgrade at all. Each OFDM subcarrier forms its own Fresnel
  zones; the "Fresnel phase difference" between subcarrier pairs is
  linear in zone number, so measuring it via amplitude time-series
  correlation + DFT locates the mover on a Fresnel zone ring; two links'
  rings intersect for 2-D position.
- **Requirements (CONFIRMED):** per-subcarrier CSI *amplitude* at
  **500 frames/sec**, per-link phase-offset calibration (walk a reflector
  along the bisector), known geometry, and a mover producing periodic
  zone-crossing signatures.
- **Results (CONFIRMED):** 0.75 m vs 1.1 m median error against LiFS,
  with 4 vs 11 transceivers, in ~70 m² areas, human walkers, 45–75 cm
  median.
- **Limits (CONFIRMED):** the monotonic zone-gap regime extends only
  ~5 m off a 6 m link axis — drones at hundreds of meters are outside
  the model; the LOS + stable-static-multipath assumptions break on a
  moving mesh; single human-scale object only.
- **No comparison against RTI's ellipsoid weighting exists in the
  paper** (CONFIRMED); its baseline was LiFS, not RTI.

## Part A — AERPAW replay harness

### Architecture

```
AERPAW public dataset (CSV/JSON, RTK ground truth)
  → dataset ingest adapter: parse trajectories + sensor timestamps,
    normalize to replay-clock time
  → replay driver: emit link-disturbance-shaped detections derived
    from ground truth + the Stone Soup forward model (same
    "link midpoint + noise" stand-in synth_data.py uses today)
  → fusion pipeline under test (Stone Soup equivalents of the app's):
    JPDA/GNN association → NIS-gating + range-gate + coast-on-prediction
    → track management
  → metrics: true NEES, track continuity / fragmentation,
    outlier-suppression rate, coverage — scored against RTK truth
```

The replay driver's detection forward model starts as the same
stand-in the bench already uses (link midpoint + noise — a placeholder
for the real geometric forward model, stated as such). This is
deliberate: the first replay run scores the *fusion machinery* (does
the association survive real, non-synthetic trajectories with real
outliers?), not the sensor model. Swapping in dip-weighted detection
positions is the follow-up run the bench README already proposes.

### Why this is the missing loop (CLAIMED, program-judgment)

The research sweep's standing finding: synthetic training is only
conditionally sound. The current bench scores the tracker against
trajectories Shepherd's own `synth_data.py` invented — the same family
of motion models the tracker was tuned on. The AERPAW dataset breaks
that circularity with real trajectories: real accelerations, real
outliers, real dropouts. If the track-stitching and consistency
monitoring hold up under real-trajectory replay, the synthetic-trained
components earn their confidence honestly; if they don't, the bench
has found the gap before the field does.

### NEES precedent to cite

`bench_jpda.py` already computes **true NEES** and already caught the
bench's own overconfidence: mean NEES **66.4 vs ideal 4**. That is the
machinery this harness reuses, and the precedent for why it matters:
an untested-consistency tracker that *looks* right in position error
can be wildly overconfident. The replay harness scores NEES against
RTK truth on every run, and a run is not passing unless the NEES
report is included alongside the error metrics.

### Ku-band RCS note for detection-range math (CONFIRMED data, CLAIMED application)

Document the measured distribution — hexacopter RCS 0.0066–0.549 m²,
mean 0.12 m² at Ku-band — in the bench README as the reference range
for back-of-the-envelope detection-range math. Label the application
CLAIMED: this is a radar-RCS measurement on one hexacopter at Ku, not
a statement about link-shadowing depth at 2.4 GHz or about
Shahed-class targets. It bounds expectations; it does not set them.

### Metrics scored per run

| Metric | Definition | Why it's here |
|---|---|---|
| True NEES | filter-reported covariance vs RTK truth, mean over track life | Consistency: catches overconfidence (precedent: 66.4 vs 4) |
| Track continuity / fragmentation | number of track IDs per ground-truth target, per run | Stitching quality: does one target stay one track? |
| Outlier-suppression rate | fraction of RTK-outlier detections the NIS/range gate rejects before update | The paper's central claim: fusion's win is outlier suppression |
| Coverage | fraction of ground-truth trajectory with an active associated track | The paper's other central claim: 100% coverage |
| Position error vs truth | mean error conditioned on associated track | Context only — per the paper, this is *not* where fusion wins |

### Integration points (actual files)

- `~/workspace/rf_sentry/tools/stone_soup_bench/bench_jpda.py` — add the
  replay driver (dataset ingest → replay-clock detection stream); reuse
  the existing true-NEES computation verbatim.
- `~/workspace/rf_sentry/tools/stone_soup_bench/synth_data.py` — the
  record-schema contract the replay CSVs must satisfy; the RTK adapter
  emits this schema (`t_iso,link_key,from_node,to_node,snr_db,dip_db,
  truth_x,truth_y,truth_id`) so the rest of the bench is untouched.
- `~/workspace/rf_sentry/tools/stone_soup_bench/sample_run.csv` —
  reference format for replay outputs; keep one replay CSV checked in
  as the golden fixture.
- `~/workspace/rf_sentry/tools/stone_soup_bench/README.md` — document
  the dataset provenance (arXiv:2512.14608, RTK ground truth), the Ku
  RCS distribution, the caveat (cooperative RF side), and the NEES
  precedent.
- `~/workspace/rf_sentry/tools/train_disturbance_clf.py`,
  `~/workspace/rf_sentry/tools/train_stitcher.py` — upstream of the
  modules under test; replay results feed back into retraining
  decisions (a fusion failure on real trajectories is retraining
  evidence, not just a bench number).
- App modules under test (ported behavior, scored in the bench, not
  duplicated code):
  - `lib/services/confidence_merger.dart` — gated merger; replay
    scores whether real-trajectory evidence streams move the merger
    sensibly under the honest-score semantics of
    `docs/confidence_math.md`.
  - `lib/services/track_consistency.dart` — innovation monitor; replay
    scores whether fix-to-fix innovation consistency flags the same
    segments the RTK truth marks as diverging.
  - `lib/services/track_stitcher.dart` — continuity/fragmentation is
    this module's report card.

### NIS-gating + range-gate + coast-on-prediction (adopted pattern)

Adopt as the fusion layer's track-management contract, tested in the
bench before it is asserted in the app:
1. **NIS gate:** measurement updates apply only inside the
   chi-square gate of the predicted covariance (the NEES machinery
   already present in `bench_jpda.py` is the scoring half of this).
2. **Range gate:** a measurement must fall inside the plausible
   disturbance geometry of a claimed link before it can associate.
3. **Coast-on-prediction:** missed updates do not kill the track —
   the track coasts on its prediction with growing covariance until the
   NIS gate re-admits measurements or the track deleter fires. This is
   the coverage mechanism (the paper's 100% coverage came from not
   dropping tracks on dropouts).

### Pass criteria (Part A)

1. The harness loads the AERPAW dataset and replays it end to end with
   no manual intervention; the golden replay CSV reproduces within
   tolerance (deterministic seed recorded).
2. Every replay run reports all five metrics (NEES included — a run
   without a NEES report is not a result).
3. **Baseline bar:** replay metrics meet or beat the synthetic-data
   baseline on continuity and outlier-suppression rate — the point is
   real trajectories, not easier numbers. If replay is *worse*, that is
   a finding, recorded in the README with the RTK-ground-truth
   evidence, and fed to the retraining decision.
4. The caveat (validates fusion machinery, not end-to-end
   non-cooperative detection) appears in the README, the harness
   output header, and any test report. A report without the caveat is
   not releasable.

## Part B — ESP32 CSI 500 frames/sec bench

### The one measurement

**Question:** can the ESP32 sustain ~500 frames/sec per-subcarrier CSI
amplitude reporting per link over UDP, without drops, for 60 seconds?

This bench answers that and **nothing else**. It is framed, in the
procedure and in every report, as a raw CSI frame-rate feasibility
measurement — not as a Fresnel-zone validation, not as a localization
result. If it fails, Fresnel-zone work is parked pending hardware with
a faster CSI path (stated in the spec, not revisited in chat).

### Why 500 (CONFIRMED)

MFDL requires per-subcarrier CSI amplitude at 500 frames/sec
(arXiv:1707.07514, §3, read in full). Below that, the zone-crossing
time-series correlation + DFT at the heart of the method has nothing to
work with. 500 is the method's floor, not a nice-to-have.

### Procedure

1. **Firmware-side frame-rate sweep** in
   `~/workspace/shepherd_field_kit/esp32/shepherd_node/shepherd_node.ino`:
   add a bench mode (compile flag, off by default — never in the
   shipping build) that pushes CSI amplitude reports at the highest
   rate the Wi-Fi task will sustain, stepping the offered rate
   100 → 250 → 500 → 1000 frames/sec.
2. **Transport under test:** UDP to the existing beacon port 49160 —
   the same path the production node uses, so the measurement includes
   real serialization and queueing costs, not just callback speed.
3. **Measurements per step (60 s each):** offered rate vs sustained
   receive rate (drop count via sequence numbers), CPU headroom on both
   cores, heap low-water mark, Wi-Fi task watchdog events.
4. **Record everything:** raw per-step logs kept with the bench run;
   summary table (offered / sustained / drop % / CPU % / heap) in the
   bench report.

### Pass criterion (Part B)

**Sustained ≥ 500 frames/sec amplitude reports per link, zero
unexplained drops, for ≥ 60 s, with headroom** (both cores < 80%
utilization, heap low-water mark above the existing steady-state
floor). One measurement. Pass = Fresnel-zone work may proceed to a
*separate, later* bench; fail = parked, documented, moved on from.

### What this does not touch

- The production tripwire path (`docs/esp32_csi_pipeline_spec.md`'s
  1 s aggregation cadence) is not modified by this bench; the bench
  mode is a compile flag, off by default.
- No Fresnel weighting enters the app on the back of this bench. The
  MFDL line is filed as a research lead only (next section).

## Fresnel lead (research lead, unvalidated — NOT a bench result)

The FPM linear-zone-phase relationship from MFDL (Fresnel phase
difference between subcarrier pairs linear in zone number) is filed as
a research lead, nothing more. What would be required to promote it
beyond a lead: (1) Part B passes; (2) per-link phase-offset calibration
proven on ESP32 hardware (the bisector-walk the paper requires);
(3) a head-to-head test against the existing ellipsoid link weighting in
`docs/rti_imaging_weights_spec.md` on recorded link data — the paper
contains no such comparison (CONFIRMED gap); (4) validation outside the
5 m monotonic zone-gap regime before any claim about drones. Until all
four hold, no Fresnel weighting enters Shepherd's imaging path.

## Honest-scope limits

- **AERPAW replay:** validates fusion machinery (association, gating,
  stitching, consistency monitoring) against real trajectories. It does
  **not** validate Shepherd's end-to-end detection of non-cooperative
  targets — the dataset's RF side tracked the UAV's own emission. Any
  report that omits this sentence is not releasable.
- **CSI bench:** measures frame-rate feasibility only. A passing number
  is not a localization result and must never be quoted as one.
- **RCS data:** the 0.0066–0.549 m² (mean 0.12 m²) Ku-band hexacopter
  RCS is a documented reference for range math, not a claim about
  Shepherd's link-shadowing sensitivity or about Shahed-class targets.
- **MFDL transfer:** everything about MFDL's applicability to Shepherd
  (moving mesh, drone ranges, RTI weighting) is an open research
  question until the four conditions in the Fresnel-lead section hold.
  The paper's regime is 4 transceivers, ~70 m², human walkers, 5 m off
  a 6 m link axis — none of that is a drone at hundreds of meters.
- **RX-only:** the replay harness reads public datasets; the CSI bench
  reads the node's own CSI. Nothing in either bench transmits.

## Test / validation plan summary

| # | Bench | Pass criterion |
|---|---|---|
| A1 | AERPAW replay end-to-end | Loads dataset, replays deterministically, golden CSV reproduces |
| A2 | Metrics completeness | Every run reports NEES + continuity/fragmentation + outlier-suppression + coverage + position error; runs without NEES don't count |
| A3 | Real-trajectory bar | Replay continuity and outlier-suppression meet or beat synthetic baseline; a worse result is recorded as a finding, not hidden |
| A4 | Caveat presence | Caveat sentence in README, harness output header, and every test report |
| B1 | CSI frame-rate sweep | Sustained ≥ 500 frames/sec/link, ≥ 60 s, no unexplained drops, CPU < 80%, heap above floor |
| B2 | Bench isolation | Bench mode is a compile flag, off by default; production tripwire cadence untouched |

**Open follow-ups (not hidden):**
- Swap the replay forward model from link-midpoint+noise to
  dip-weighted detection positions and compare (already proposed in
  the bench README).
- Replay-driven retraining decision for `train_disturbance_clf.py` /
  `train_stitcher.py` after the first real-trajectory results land.
- Carrying MFDL's per-link calibration (bisector-walk) to hardware is
  gated behind B1 passing and is a separate bench with its own spec.

## Files

- `~/workspace/rf_sentry/tools/stone_soup_bench/` — replay harness home:
  `bench_jpda.py` (replay driver + existing true-NEES scoring),
  `synth_data.py` (record-schema contract), `sample_run.csv`
  (reference format), `README.md` (provenance, Ku RCS, caveat, NEES
  precedent: mean NEES 66.4 vs ideal 4), golden replay CSV fixture.
- `~/workspace/rf_sentry/tools/train_disturbance_clf.py`,
  `~/workspace/rf_sentry/tools/train_stitcher.py` — upstream training;
  replay results feed retraining decisions.
- `~/workspace/shepherd_field_kit/esp32/shepherd_node/shepherd_node.ino`
  — bench mode (compile flag, off by default); UDP 49160 is the path
  under test.
- App modules scored in the bench (behavior ported, not duplicated):
  `lib/services/confidence_merger.dart` (gated merger),
  `lib/services/track_consistency.dart` (innovation monitor),
  `lib/services/track_stitcher.dart` (track continuity/fragmentation).
- Source papers: Dickerson et al., arXiv:2512.14608 (read in full);
  Wang et al., arXiv:1707.07514 (read in full).
