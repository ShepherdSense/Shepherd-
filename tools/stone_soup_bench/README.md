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
