# Stone Soup tracker R&D bench

**OFFLINE design tool — not a runtime dependency.** Nothing here ships in
the app.

Purpose: prototype tracker / data-association designs in Python against
Shepherd-recorded (or synthetic) link-disturbance data, compare them on
hard metrics, then port the winner to Dart (`lib/services/tracker.dart`).

## Layout

- `requirements.txt` — `stonesoup`, `numpy`, `scipy`, `matplotlib`.
  Install once: `pip install -r requirements.txt` (user site is fine).
  Note: the PyPI package is `stonesoup` (no hyphen).
- `synth_data.py` — generates `sample_run.csv`: 60 s at 4 Hz, four mesh
  nodes / six links, two crossing targets + one distractor walker.
  Schema: `t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id`
  (the `truth_*` columns are the dominant contributor per link — scoring
  aids, not something the real recorder knows).
- `bench_jpda.py` — loads the CSV, turns disturbed links into position
  detections (link midpoint + noise — a stand-in for the real geometric
  forward model), runs a Stone Soup **GNN** (nearest-neighbour 2D
  assignment) tracker (2D constant-velocity; JPDA was tried first but its
  mixture updates defeated the track deleter — see the script docstring),
  prints track purity / mean position error vs truth, saves
  `bench_plot.png`.

## Run

```bash
pip install -r requirements.txt
python3 synth_data.py
python3 bench_jpda.py            # -> metrics on stdout, bench_plot.png
python3 bench_jpda.py other.csv out.png   # any record-schema CSV
```

## What to try next

- Swap the detector: weight detections along the link by dip instead of
  midpoint+noise; compare mean error.
- Tune `PDAHypothesiser` (`clutter_spatial_density`, `prob_detect`) and
  the CV process noise; watch purity at the crossing.
- Feed a real recorded CSV (same schema) instead of synthetic data.
- Port the winning configuration's parameters (gates, covariances,
  deletion age) into the Dart tracker.

## NEES consistency (added 2026-10-17, lane3 P8)

`bench_jpda.py` now reports mean NEES over the 4-D constant-velocity
state (eᵀP⁻¹e per update, truth velocity from central finite
differences of the truth trajectory). A consistent filter averages near
the state dimension d = 4; NEES >> d flags an overconfident covariance
— the failure RMSE alone cannot see.

**Honest result on the current config:** mean NEES ≈ 66 (ideal ≈ 4),
flagged OVERCONFIDENT. This is not a bug in the NEES code — it is the
instrument working: the detection stand-in (link midpoint + 3 m noise)
carries unmodeled bias (the midpoint is not where the target is; the
target can be anywhere along the link), and the filter's 3 m
measurement covariance does not cover it. RMSE (12.1 m) alone would
never have said the covariance was dishonest. Before porting any
covariance to the app, either swap the detector for the dip-weighted
forward model or inflate the measurement noise until NEES ≈ d.

`--shrink-covar 0.01` demonstrates the flag's sensitivity: mean NEES
2865 on the deliberately overconfident config.

## AERPAW replay harness (added 2026-10-18)

Replays real-trajectory data through the fusion machinery to break the
synthetic-training circularity: the bench's tracker was tuned on the same
family of motion models `synth_data.py` generates. Real trajectories bring
real accelerations, real outliers, real dropouts.

**CAVEAT (load-bearing — every run prints it, every report must carry
it):** this harness validates the FUSION MACHINERY (data association,
NIS-gating + range-gate + coast-on-prediction, track stitching,
consistency monitoring) against real trajectories — NOT Shepherd's
end-to-end detection of non-cooperative targets. The dataset's RF side
tracked the UAV's own emission (cooperative in the RF sense); Shepherd's
tripwire detects non-cooperative link disturbance. A report without this
caveat is not releasable.

### Dataset provenance

- Paper: Dickerson et al., "Fusion of Cellular ISAC and Passive RF
  Sensing for UAV Detection and Tracking", arXiv:2512.14608 (Dec 2025) —
  READ IN FULL (CONFIRMED). Field trial fusing RF TDOA (passive Keysight
  N6841A sensors) with a Fortem TrueView R20 Ku-band radar (16.3 GHz ISAC
  proxy) at the NSF AERPAW testbed, with RTK ground truth.
- Paper's central finding (CONFIRMED): fusion's win is outlier
  suppression plus coverage, not mean-error reduction — fused mean error
  21.9 m at 100% coverage (2528 KF updates + 127 coasted steps). Radar
  pre-validation: 3106 measurements at 0.25 s, 100% coverage, mean error
  26.2 m / std 25.5 m. RF network: 206/216 position estimates, 3.88 s
  average interval, 95.4% temporal coverage. Validation pattern adopted
  here: NIS testing + range gating (800 m) + largest-track selection.
- Public dataset: "Multi-Modal RF Sensor and Radar Dataset for UAV
  Tracking", AERPAW Dataset Repository Dataset-28
  (https://aerpaw.org/dataset/multi-modal-rf-sensor-and-radar-dataset-for-uav-tracking/),
  DOI 10.5061/dryad.7d7wm3898 (Dryad).
- **Download status (honest): NOT OBTAINED.** The Dryad file-stream
  endpoints returned HTTP 403 behind a bot-validation wall on
  2026-10-18; the dataset files were not downloaded. `aerpaw_adapter.py`
  is therefore built against the DOCUMENTED schema (RTK truth +
  asynchronous 3D radar fixes + asynchronous 2D RF fixes, per the paper's
  full text), and replay runs use a clearly-labeled SYNTHETIC STAND-IN
  whose dynamics mirror the paper's reported numbers (0.25 s radar, 3.88 s
  average RF cadence on a deterministic grid, 95.4% RF coverage, 800 m
  range gate, high-error window
  during the turn). Every stand-in artifact carries the
  "SYNTHETIC STAND-IN — NOT AERPAW DATA" label; nothing is presented as
  AERPAW data. If the dataset is obtained later, `try_load_dataset()`
  ingests a real drop with no harness changes.

### Ku-band RCS reference (CONFIRMED data, CLAIMED application)

Measured hexacopter RCS at Ku-band: **0.0066–0.549 m², mean 0.12 m²**
(Dickerson et al., full read). Documented here as a radar-RCS reference
for back-of-the-envelope detection-range math — NOT a claim about
Shepherd's link-shadowing depth at 2.4 GHz and NOT about Shahed-class
targets. It bounds expectations; it does not set them.

### Layout

- `aerpaw_adapter.py` — dataset ingest (`try_load_dataset()`, expected
  schema documented) + labeled synthetic stand-in generator
  (`make_standin()`, deterministic seed).
- `replay_aerpaw.py` — replay driver: emits the `synth_data.py` record
  schema on a replay clock from ground truth via the same
  link-midpoint+noise stand-in the bench uses (stated placeholder),
  with a paper-mirroring outlier/dropout schedule (background bogus dips,
  forced-outlier window during the turn, no-dip dropout window to test
  coasting). Fusion loop under test: nearest-in-gate association with
  **NIS-gating (χ² 0.99, 2 dof) + range-gate + coast-on-prediction**
  (numpy reference implementation — the contract to port to Dart).
  True NEES is reused **verbatim** from `bench_jpda.compute_true_nees`.
- `aerpaw_replay_golden.csv` (+ `.meta.json`) — golden replay fixture,
  deterministic seed 20261018. `--verify-fixture` regenerates and diffs
  byte-identically.

### Run

```bash
python3 replay_aerpaw.py --emit-fixture     # (re)build golden fixture
python3 replay_aerpaw.py --verify-fixture   # determinism check -> PASS
python3 replay_aerpaw.py                    # replay golden CSV, print report
python3 replay_aerpaw.py --baseline-synth   # A3 synthetic-CV baseline
```

Every run reports all five metrics: true NEES, continuity/fragmentation,
outlier-suppression rate, coverage, position error vs truth.

### First results (2026-10-18, stand-in — recorded, not hidden)

| metric | replay (stand-in trajectory) | synthetic CV baseline |
|---|---|---|
| continuity / fragmentation | 4 track IDs | 2 track IDs |
| coverage | 0.963 | 1.000 |
| outlier suppression | **0.853** (29/34) | 0.600 (21/35) |
| position error vs truth | 240 m | 191 m |
| true NEES (ideal ≈ 4) | 1744 (n=108) | 397 (n=175) |

Reading, honestly: the replay **beats** the synthetic baseline on
outlier-suppression rate (0.853 vs 0.600) — the NIS/range gates do their
job against the injected bogus dips. Continuity is **worse** (4 vs 2
track IDs): the coordinated turn + outlier window + dropout window
fragment the CV tracker's single track, which is the real-dynamics
finding this harness exists to surface. Position error and NEES are
dominated by the link-midpoint+noise stand-in at AERPAW scale (links
~600 m long; the midpoint can sit hundreds of meters from truth) — the
same unmodeled-bias phenomenon as the bench's NEES=66 finding, scaled
up. Those two metrics score the stand-in, not the tracker; the
machinery metrics (suppression, continuity, coverage) are the valid
replay signal. Follow-up, already planned: swap the forward model for
dip-weighted detection positions and compare (spec §Open follow-ups).
