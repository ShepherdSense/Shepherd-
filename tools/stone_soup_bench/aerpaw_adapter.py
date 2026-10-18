#!/usr/bin/env python3
"""AERPAW dataset ingest adapter for the Shepherd replay harness.

Dataset: Dickerson et al., "Fusion of Cellular ISAC and Passive RF
Sensing for UAV Detection and Tracking", arXiv:2512.14608 (Dec 2025).
READ IN FULL (CONFIRMED). Public dataset: "Multi-Modal RF Sensor and
Radar Dataset for UAV Tracking", AERPAW Dataset Repository, Dataset-28,
https://aerpaw.org/dataset/multi-modal-rf-sensor-and-radar-dataset-for-uav-tracking/
DOI 10.5061/dryad.7d7wm3898 (Dryad).

DOCUMENTED SCHEMA (from the paper's full text -- what the adapter parses):
  * RTK ground-truth trajectory: timestamped (x, y, z) UAV positions.
  * Radar stream (Fortem TrueView R20 Ku-band, 16.3 GHz ISAC proxy):
    asynchronous 3D (x, y, z) measurements, ~0.25 s sampling, 100%
    temporal coverage pre-validation (3106 measurements in the analyzed
    flight), mean error 26.2 m / std 25.5 m before validation; the paper
    range-gates beyond 800 m and applies NIS testing, keeping the
    largest continuous track (2403 measurements, mean 21.0 m, std 17.1 m).
  * RF sensor network stream (passive Keysight N6841A TDOA): asynchronous
    2D (x, y) position estimates, ~3.88 s average sampling interval,
    206/216 successful estimates pre-validation (95.4% temporal coverage);
    after NIS validation 125 measurements at 57.9% coverage.
  * Fused result (paper): mean error 21.9 m at 100% coverage (2528 KF
    updates + 127 coasted steps).

DOWNLOAD STATUS (honest, do not fake provenance):
  The Dryad file-stream endpoints (/downloads/file_stream/4651889,
  /downloads/file_stream/4651901) return HTTP 403 behind a bot-validation
  wall as of 2026-10-18. The dataset files were NOT obtained. The adapter
  below is therefore built against the DOCUMENTED schema above, and
  replay runs use a clearly-labeled SYNTHETIC STAND-IN whose dynamics
  (sampling rates, coverage, outlier behavior, range-gate) mirror the
  paper's reported numbers. Every stand-in artifact carries the label;
  nothing is presented as AERPAW data.

CAVEAT (travels with every replay result):
  This harness validates the FUSION MACHINERY (association, NIS/range
  gating, track stitching, consistency monitoring) against real
  trajectories -- NOT Shepherd's end-to-end detection of non-cooperative
  targets. The dataset's RF side tracked the UAV's own emission
  (cooperative in the RF sense); Shepherd's tripwire detects
  non-cooperative link disturbance.

RX-only. Offline design tool; nothing here ships in the app.
"""

import csv
import math
import os
import sys
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------- constants

# Stand-in dynamics mirror the paper's reported numbers (CONFIRMED):
STANDIN = {
    "duration_s": 60.0,
    "truth_hz": 4.0,          # RTK truth cadence in the stand-in
    "radar_hz": 4.0,          # paper: 0.25 s sampling (use 4 Hz here)
    "radar_err_m": 26.2,      # paper: raw mean error 26.2 m, std 25.5 m
    "radar_err_std": 25.5,
    "radar_range_gate_m": 800.0,   # paper: discard detections beyond 800 m
    "rf_interval_s": 3.88,    # paper: 3.88 s average RF sampling
    "rf_success": 0.954,      # paper: 206/216 = 95.4% temporal coverage
    "rf_err_m": 25.8,         # paper: post-validation RF mean 25.8 m
    "rf_outlier_p": 0.05,     # RF standalone "more vulnerable to outliers"
    "rf_outlier_m": 120.0,    # large standalone RF errors (paper's claim)
    "radar_bad_window": (20.0, 26.0),  # high-error yellow region analog
    "radar_bad_err_m": 150.0, # ">>150 m" yellow regions (paper Fig. 6)
    "dropout_window": (40.0, 44.0),    # fragmentation analog: no fixes
}

PROVENANCE_LABEL = ("SYNTHETIC STAND-IN -- NOT AERPAW DATA. Schema mirrors "
                    "Dickerson et al. arXiv:2512.14608 as documented in "
                    "aerpaw_adapter.py. Deterministic seed recorded in the "
                    "companion .meta.json.")

EXPECTED_FILES = {
    # what a real dataset drop would look like (documented schema)
    "ground_truth.csv": ["t_iso", "x", "y", "z"],
    "radar.csv": ["t_iso", "x", "y", "z"],
    "rf.csv": ["t_iso", "x", "y"],
}


# ---------------------------------------------------------------- dataset

def try_load_dataset(data_dir):
    """Load a real AERPAW dataset drop. Returns dict or None if absent.

    Expected layout (documented schema):
      <data_dir>/ground_truth.csv  t_iso,x,y,z        (RTK truth)
      <data_dir>/radar.csv         t_iso,x,y,z        (3D radar fixes)
      <data_dir>/rf.csv            t_iso,x,y          (2D RF fixes)
    Returns None when the files are not present -- the caller then falls
    back to the labeled synthetic stand-in.
    """
    paths = {k: os.path.join(data_dir, k) for k in EXPECTED_FILES}
    if not all(os.path.isfile(p) for p in paths.values()):
        return None
    out = {"provenance": "real", "dir": data_dir}
    for name, path in paths.items():
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
        cols = EXPECTED_FILES[name]
        if any(c not in (rows[0].keys() if rows else []) for c in cols):
            raise ValueError(f"{path}: expected columns {cols}")
        out[name] = rows
    return out


# ---------------------------------------------------------------- stand-in

def _trajectory(t):
    """One UAV trajectory with real (non-CV) dynamics: cruise, a coordinated
    turn, and a deceleration -- the point is dynamics the constant-velocity
    tracker was NOT tuned on."""
    # piecewise: cruise east, banked turn, cruise north-east, decelerate
    if t < 15.0:
        x, y = -250.0 + 18.0 * t, -120.0 + 2.0 * t
    elif t < 25.0:
        a = (t - 15.0) / 10.0 * math.pi / 2.0   # 90-deg coordinated turn
        x, y = 20.0 + 130.0 * math.sin(a), -90.0 + 130.0 * (1 - math.cos(a))
    elif t < 45.0:
        x, y = 150.0 + 6.0 * (t - 25.0), 40.0 + 12.0 * (t - 25.0)
    else:
        dt = t - 45.0
        x, y = 270.0 + 6.0 * dt - 0.35 * dt * dt, 280.0 + 12.0 * dt - 0.5 * dt * dt
    return x, y, 60.0 + 8.0 * math.sin(t / 9.0)


def make_standin(seed, out_dir):
    """Generate the labeled synthetic stand-in. Deterministic in `seed`.

    Writes aerpaw_standin_{truth,radar,rf}.csv + .meta.json into out_dir.
    Every file carries PROVENANCE_LABEL; nothing here is AERPAW data.
    """
    import random
    rng = random.Random(seed)
    gauss = rng.gauss
    os.makedirs(out_dir, exist_ok=True)
    P = STANDIN
    t0 = datetime(2026, 10, 18, 12, 0, 0, tzinfo=timezone.utc)

    truth_rows, radar_rows, rf_rows = [], [], []
    n_truth = int(P["duration_s"] * P["truth_hz"])
    # RF cadence: deterministic 3.88 s grid (the paper's reported average
    # RF sampling interval), quantized to the 0.25 s truth grid. The
    # accumulator advances one interval per tick even through the dropout
    # window and missed fixes, so the grid never drifts. (The old
    # abs(t % 3.88) < 0.125 test fired irregularly -- ~7.3 s average,
    # 9 fixes in 60 s -- on this grid; the accumulator yields 16 fixes
    # at 3.88 s average cadence.)
    next_rf_time = 0.0
    for i in range(n_truth):
        t = i / P["truth_hz"]
        x, y, z = _trajectory(t)
        t_iso = (t0 + timedelta(seconds=t)).isoformat()
        truth_rows.append({"t_iso": t_iso, "x": f"{x:.2f}", "y": f"{y:.2f}",
                           "z": f"{z:.2f}"})
        # radar fix: raw error per the paper's pre-validation numbers
        bad0, bad1 = P["radar_bad_window"]
        d0, d1 = P["dropout_window"]
        in_dropout = d0 <= t < d1
        in_bad = bad0 <= t < bad1
        if not in_dropout and i % max(1, int(P["truth_hz"] / P["radar_hz"])) == 0:
            err = P["radar_bad_err_m"] if in_bad else P["radar_err_m"]
            std = P["radar_bad_err_m"] * 0.5 if in_bad else P["radar_err_std"]
            ex = gauss(0.0, std) + (err if rng.random() < 0.5 else -err) * 0.3
            ey = gauss(0.0, std)
            rng_range = math.hypot(x, y)
            if rng_range <= P["radar_range_gate_m"]:
                radar_rows.append({"t_iso": t_iso,
                                   "x": f"{x + ex:.2f}", "y": f"{y + ey:.2f}",
                                   "z": f"{z + gauss(0, 5.0):.2f}"})
        # RF fix: 3.88 s cadence grid, high coverage, occasional large
        # outlier. One grid tick per interval; the success coin and the
        # dropout window decide emission, not timing.
        if t >= next_rf_time:
            next_rf_time += P["rf_interval_s"]
            if rng.random() < P["rf_success"] and not in_dropout:
                if rng.random() < P["rf_outlier_p"]:
                    ex = gauss(0.0, P["rf_outlier_m"])
                    ey = gauss(0.0, P["rf_outlier_m"])
                else:
                    ex, ey = gauss(0.0, P["rf_err_m"]), gauss(0.0, P["rf_err_m"])
                rf_rows.append({"t_iso": t_iso, "x": f"{x + ex:.2f}",
                                "y": f"{y + ey:.2f}"})

    paths = {}
    for name, rows, cols in (("aerpaw_standin_truth.csv", truth_rows,
                              ["t_iso", "x", "y", "z"]),
                             ("aerpaw_standin_radar.csv", radar_rows,
                              ["t_iso", "x", "y", "z"]),
                             ("aerpaw_standin_rf.csv", rf_rows,
                              ["t_iso", "x", "y"])):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="") as f:
            f.write(f"# {PROVENANCE_LABEL} seed={seed}\n")
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(rows)
        paths[name] = path
    meta = {"provenance": "synthetic-standin",
            "label": PROVENANCE_LABEL,
            "seed": seed,
            "paper": "Dickerson et al., arXiv:2512.14608",
            "dataset_doi": "10.5061/dryad.7d7wm3898",
            "dataset_download": "NOT OBTAINED (Dryad file streams HTTP 403, "
                                "2026-10-18)",
            "files": {k: os.path.basename(v) for k, v in paths.items()},
            "n_truth": len(truth_rows), "n_radar": len(radar_rows),
            "n_rf": len(rf_rows)}
    import json
    meta_path = os.path.join(out_dir, "aerpaw_standin.meta.json")
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=1)
    paths["meta"] = meta_path
    print(f"[adapter] stand-in seed={seed}: {len(truth_rows)} truth, "
          f"{len(radar_rows)} radar, {len(rf_rows)} rf rows -> {out_dir}")
    print(f"[adapter] {PROVENANCE_LABEL}")
    return paths


def load_standin(out_dir):
    """Load a previously generated stand-in (skips '#' comment lines)."""
    def read(name):
        rows = []
        with open(os.path.join(out_dir, name)) as f:
            for line in f:
                if line.startswith("#"):
                    continue
                rows.append(line)
        return list(csv.DictReader(rows))
    return {"provenance": "synthetic-standin",
            "aerpaw_standin_truth.csv": read("aerpaw_standin_truth.csv"),
            "aerpaw_standin_radar.csv": read("aerpaw_standin_radar.csv"),
            "aerpaw_standin_rf.csv": read("aerpaw_standin_rf.csv")}


def main():
    ap = __import__("argparse").ArgumentParser(
        description="AERPAW dataset ingest adapter")
    ap.add_argument("--standin", action="store_true",
                    help="generate the labeled synthetic stand-in")
    ap.add_argument("--seed", type=int, default=20261018)
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "aerpaw_standin"))
    ap.add_argument("--check", default="",
                    help="check a directory for a real dataset drop")
    args = ap.parse_args()
    if args.check:
        ds = try_load_dataset(args.check)
        print("real dataset found" if ds else
              "no dataset drop in " + args.check + " (stand-in would be used)")
        sys.exit(0 if ds else 1)
    if args.standin:
        make_standin(args.seed, args.out_dir)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
