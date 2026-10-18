#!/usr/bin/env python3
"""AERPAW replay harness: real-trajectory replay through the fusion machinery.

CAVEAT (load-bearing -- printed by every run, required in every report):
  This harness validates the FUSION MACHINERY (data association,
  NIS-gating + range-gate + coast-on-prediction, track stitching,
  consistency monitoring) against real trajectories -- NOT Shepherd's
  end-to-end detection of non-cooperative targets. The dataset's RF side
  tracked the UAV's own emission (cooperative in the RF sense);
  Shepherd's tripwire detects non-cooperative link disturbance.

Pipeline:
  aerpaw_adapter.py (dataset drop, or labeled synthetic stand-in)
    -> replay driver: emit link-disturbance-shaped detections derived
       from ground truth on a replay clock, using the same
       "link midpoint + noise" stand-in forward model synth_data.py uses
       (stated as a placeholder for the real geometric forward model)
    -> fusion loop under test: nearest-in-gate association with
       NIS-gating + range-gate + coast-on-prediction (the adopted
       track-management contract, tested here before app assertion)
    -> metrics vs RTK truth: true NEES (reused verbatim from
       bench_jpda.compute_true_nees), continuity/fragmentation,
       outlier-suppression rate, coverage, position error

Outlier/dropout schedule (mirrors the paper's observed behavior):
  * background bogus-dip injection: p=0.02/epoch on a random link
  * forced outlier window t in [18, 26) s: 1 bogus dip/epoch (analog of
    the paper's high-error "yellow regions" during sharp turns --
    the stand-in turns at 15-25 s and the radar bad window is 20-26 s)
  * dropout window t in [40, 44) s: no dips at all (fragmentation analog;
    the track must coast, per the paper's coverage-via-coasting result)
  Bogus dips are tagged truth_id="OUTLIER" so the scorer can count how
  many the NIS/range gates reject before update.

Modes:
  replay_aerpaw.py --emit-fixture [csv]     write the golden replay CSV
  replay_aerpaw.py --verify-fixture         regenerate with the recorded
                                            seed and diff against the
                                            checked-in golden CSV
  replay_aerpaw.py [csv]                    replay a CSV, print metrics
  replay_aerpaw.py --baseline-synth         same harness, constant-
                                            velocity synthetic trajectory,
                                            same outlier schedule (the A3
                                            synthetic-data baseline)

RX-only. Offline design tool; nothing here ships in the app.
"""

import csv
import json
import math
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aerpaw_adapter import (PROVENANCE_LABEL, STANDIN, load_standin,
                            make_standin)
from bench_jpda import compute_true_nees  # true-NEES reused verbatim

CAVEAT = ("CAVEAT: this replay validates the FUSION MACHINERY against real "
          "trajectories, NOT Shepherd's end-to-end detection of "
          "non-cooperative targets -- the dataset's RF side tracked the "
          "UAV's own emission (cooperative in the RF sense).")

# ---- replay forward-model stand-in (same family as synth_data.py) --------
DETECT_THRESH_DB = 2.5   # link dip that becomes a detection
BASE_SNR = 22.0
NOISE_DB = 0.4
CLUTTER_P = 0.02
CLUTTER_DB = (2.0, 4.0)
D0_DB = 8.0              # peak link dip for a close crossing

NIS_CHI2_099_2D = 9.2103  # chi-square 0.99 quantile, 2 dof (NIS gate)
MAX_COAST_S = 4.0         # track deleter: coast this long, then delete

OUTLIER_BG_P = 0.02       # background bogus-dip probability per epoch
OUTLIER_WINDOW = (18.0, 26.0)   # forced-outlier window (turn analog)
DROPOUT_WINDOW = (40.0, 44.0)   # no-dip window (coast test)


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def build_mesh(xs, ys, margin=0.10):
    """4-node mesh bracketing the trajectory bounding box (+ margin)."""
    x0, x1 = min(xs), max(xs)
    y0, y1 = min(ys), max(ys)
    dx, dy = (x1 - x0) * margin, (y1 - y0) * margin
    nodes = {"n0": (x0 - dx, y0 - dy), "n1": (x1 + dx, y0 - dy),
             "n2": (x1 + dx, y1 + dy), "n3": (x0 - dx, y1 + dy)}
    links = [("n0", "n1"), ("n1", "n2"), ("n2", "n3"),
             ("n3", "n0"), ("n0", "n2"), ("n1", "n3")]
    span = max(x1 - x0, y1 - y0)
    return nodes, links, span


def replay_rows(truth, seed, outlier_schedule=True):
    """Emit the synth_data.py record schema on the replay clock.

    truth: list of (t_iso, x, y). Returns (rows, nodes, links, meta).
    One row per link per epoch; dip from Gaussian proximity to truth +
    noise + clutter spikes; bogus OUTLIER dips per the outlier schedule;
    no dips at all inside the dropout window.
    """
    rng = np.random.default_rng(seed)
    xs = [p[1] for p in truth]
    ys = [p[2] for p in truth]
    nodes, links, span = build_mesh(xs, ys)
    sigma = 0.08 * span
    meas_noise = 0.05 * span
    rows = []
    for (t_iso, x, y) in truth:
        t = (datetime.fromisoformat(t_iso) -
             datetime.fromisoformat(truth[0][0])).total_seconds()
        in_dropout = DROPOUT_WINDOW[0] <= t < DROPOUT_WINDOW[1]
        in_outlier_win = OUTLIER_WINDOW[0] <= t < OUTLIER_WINDOW[1]
        # bogus-dip injection is decided ONCE PER EPOCH (one random link),
        # not per link: the paper's outlier behavior is occasional large
        # measurement errors, not a barrage of simultaneous false dips.
        inject_link = None
        if outlier_schedule and not in_dropout:
            if in_outlier_win or rng.random() < OUTLIER_BG_P:
                inject_link = links[rng.integers(0, len(links))]
        for (fa, fb) in links:
            ax, ay = nodes[fa]
            bx, by = nodes[fb]
            dip, tid, tx, ty = 0.0, "", "", ""
            if not in_dropout:
                d = seg_dist(x, y, ax, ay, bx, by)
                dip = D0_DB * math.exp(-(d * d) / (2 * sigma * sigma))
                dip += rng.normal(0.0, NOISE_DB)
                if rng.random() < CLUTTER_P:
                    dip += rng.uniform(*CLUTTER_DB)
                dip = max(0.0, dip)
                if dip >= 0.5:
                    tx, ty, tid = f"{x:.2f}", f"{y:.2f}", "UAV"
            if (fa, fb) == inject_link:
                dip = 6.0 + rng.random() * 4.0
                tx, ty, tid = "", "", "OUTLIER"
            snr = BASE_SNR - dip + rng.normal(0.0, 0.3)
            rows.append({"t_iso": t_iso,
                         "link_key": f"{fa}>{fb}",
                         "from_node": fa, "to_node": fb,
                         "snr_db": f"{snr:.2f}", "dip_db": f"{dip:.2f}",
                         "truth_x": tx, "truth_y": ty, "truth_id": tid})
    meta = {"nodes": nodes,
            "links": [f"{a}>{b}" for a, b in links],
            "span_m": span, "sigma_m": sigma,
            "meas_noise_m": meas_noise,
            "seed": seed, "provenance": PROVENANCE_LABEL}
    return rows, meta


# ---------------------------------------------------------------- fusion

class CvTrack:
    """Single 2D constant-velocity track, numpy Kalman filter."""

    def __init__(self, tid, x, y, r, vmax=25.0):
        self.id = tid
        self.x = np.array([[x], [0.0], [y], [0.0]])   # [x, vx, y, vy]
        self.P = np.diag([r ** 2, vmax ** 2, r ** 2, vmax ** 2])
        self.r = r
        self.last_update_t = None
        self.states = []   # (t_iso, sv, cov, vote, updated)

    def predict(self, dt, q=3.0):
        F = np.array([[1, dt, 0, 0], [0, 1, 0, 0],
                      [0, 0, 1, dt], [0, 0, 0, 1]])
        Q = q * np.array([[dt**3/3, dt**2/2, 0, 0],
                          [dt**2/2, dt, 0, 0],
                          [0, 0, dt**3/3, dt**2/2],
                          [0, 0, dt**2/2, dt]])
        self.x = F @ self.x
        self.P = F @ self.P @ F.T + Q

    def gate(self, zx, zy):
        """NIS gate + range gate. Returns (ok, nis, dist)."""
        H = np.array([[1, 0, 0, 0], [0, 0, 1, 0]])
        R = np.diag([self.r ** 2] * 2)
        z = np.array([[zx], [zy]])
        y = z - H @ self.x
        S = H @ self.P @ H.T + R
        try:
            nis = (y.T @ np.linalg.inv(S) @ y).item()  # (1,1) -> scalar
        except np.linalg.LinAlgError:
            return False, float("inf"), float("inf")
        # range gate: 4-sigma of the predicted MEASUREMENT covariance
        # (position covariance + measurement noise), so it never binds
        # tighter than the NIS gate's own uncertainty model
        ppos = self.P[np.ix_([0, 2], [0, 2])] + np.diag([self.r ** 2] * 2)
        try:
            gate_r = 4.0 * math.sqrt(max(np.linalg.eigvalsh(ppos)))
        except np.linalg.LinAlgError:
            gate_r = float("inf")
        dist = float(np.hypot(y[0, 0], y[1, 0]))
        return (nis <= NIS_CHI2_099_2D and dist <= gate_r), nis, dist

    def update(self, zx, zy, t_iso, vote):
        H = np.array([[1, 0, 0, 0], [0, 0, 1, 0]])
        R = np.diag([self.r ** 2] * 2)
        z = np.array([[zx], [zy]])
        y = z - H @ self.x
        S = H @ self.P @ H.T + R
        K = self.P @ H.T @ np.linalg.inv(S)
        self.x = self.x + K @ y
        self.P = (np.eye(4) - K @ H) @ self.P
        self.states.append((t_iso, self.x.copy(), self.P.copy(), vote, True))

    def coast(self, t_iso):
        self.states.append((t_iso, self.x.copy(), self.P.copy(), None, False))


def run_fusion(rows, meta):
    """Nearest-in-gate association; NIS-gating + range-gate +
    coast-on-prediction. Returns (tracks, counters)."""
    nodes = meta["nodes"]
    r = meta["meas_noise_m"]
    per_t = defaultdict(list)
    for row in rows:
        per_t[row["t_iso"]].append(row)
    epochs = sorted(per_t)

    def midpoint(fa, fb):
        ax, ay = nodes[fa]
        bx, by = nodes[fb]
        return (ax + bx) / 2.0, (ay + by) / 2.0

    rng = np.random.default_rng(meta["seed"] + 1)
    tracks, counters = [], defaultdict(int)
    live = None
    next_id = 0
    prev_t = None

    for t_iso in epochs:
        t = datetime.fromisoformat(t_iso)
        dt = (t - prev_t).total_seconds() if prev_t else 0.25
        prev_t = t
        # detections: link midpoint + noise (same stand-in as bench_jpda)
        dets = []
        for row in per_t[t_iso]:
            if float(row["dip_db"]) >= DETECT_THRESH_DB:
                mx, my = midpoint(row["from_node"], row["to_node"])
                dets.append((mx + rng.normal(0, r), my + rng.normal(0, r),
                             row["truth_id"] or "?"))
                if row["truth_id"] == "OUTLIER":
                    counters["outliers_injected"] += 1
        if live is not None:
            live.predict(dt)
        # gate every detection; count outlier rejections
        gated = []
        for (zx, zy, tag) in dets:
            if live is None:
                gated.append((zx, zy, tag, 0.0))
                continue
            ok, nis, dist = live.gate(zx, zy)
            if tag == "OUTLIER" and not ok:
                counters["outliers_rejected"] += 1
            if ok:
                gated.append((zx, zy, tag, dist))
            elif tag == "OUTLIER":
                pass  # rejected: counted above
        if live is None:
            if gated:
                # initiate on the nearest detection to the field centre
                zx, zy, tag, _ = min(
                    gated, key=lambda g: math.hypot(g[0], g[1]))
                live = CvTrack(f"T{next_id}", zx, zy, r)
                next_id += 1
                tracks.append(live)
                live.last_update_t = t
                live.update(zx, zy, t_iso,
                            tag if tag == "UAV" else None)
            continue
        if gated:
            # GNN: nearest gated detection associates
            zx, zy, tag, _ = min(gated, key=lambda g: g[3])
            live.last_update_t = t
            live.update(zx, zy, t_iso, tag if tag == "UAV" else None)
            if tag == "OUTLIER":
                counters["outliers_associated"] += 1
        else:
            # coast on prediction; delete after MAX_COAST_S
            live.coast(t_iso)
            if (t - live.last_update_t).total_seconds() > MAX_COAST_S:
                live = None  # next initiation fragments the track
    return tracks, counters


# ---------------------------------------------------------------- metrics

def score(tracks, truth_rows, counters):
    """All five metrics. truth_rows: list of (t_iso, x, y)."""
    truth = {"UAV": {t: (x, y) for (t, x, y) in truth_rows}}
    truth_epochs = {t for (t, _x, _y) in truth_rows}
    traj = truth["UAV"]

    # continuity / fragmentation: distinct track IDs over the run
    n_ids = len(tracks)

    # coverage: fraction of truth epochs with a live track
    live_epochs = set()
    for tr in tracks:
        for (t_iso, _sv, _cov, _vote, _upd) in tr.states:
            live_epochs.add(t_iso)
    coverage = len(live_epochs & truth_epochs) / max(1, len(truth_epochs))

    # position error vs truth, conditioned on a live track
    errs = []
    for tr in tracks:
        for (t_iso, sv, _cov, _vote, _upd) in tr.states:
            if t_iso in traj:
                tx, ty = traj[t_iso]
                errs.append(math.hypot(sv[0, 0] - tx, sv[2, 0] - ty))
    pos_err = sum(errs) / len(errs) if errs else None

    # outlier suppression
    inj = counters["outliers_injected"]
    rej = counters["outliers_rejected"]
    suppression = rej / inj if inj else None

    # true NEES, reused verbatim from bench_jpda
    neutral = [{"id": tr.id, "matched": "UAV",
                "states": [(t_iso, sv, cov, vote)
                           for (t_iso, sv, cov, vote, _upd) in tr.states]}
               for tr in tracks]
    mean_nees, _by_track, n_nees = compute_true_nees(
        neutral, truth, state_dim=4, verbose=False)

    return {"continuity_track_ids": n_ids,
            "coverage": coverage,
            "position_error_m": pos_err,
            "outliers_injected": inj,
            "outliers_rejected": rej,
            "outlier_suppression_rate": suppression,
            "mean_nees": mean_nees, "nees_updates": n_nees}


def print_report(metrics, label, provenance):
    print(f"\n===== AERPAW REPLAY REPORT: {label} =====")
    print(f"provenance: {provenance}")
    print(CAVEAT)
    print(f"  continuity/fragmentation: {metrics['continuity_track_ids']} "
          f"track ID(s) for the truth target (1 = perfect continuity)")
    print(f"  coverage: {metrics['coverage']:.3f} (fraction of truth "
          f"trajectory with an active track)")
    pe = metrics["position_error_m"]
    print(f"  position error vs truth: "
          f"{f'{pe:.2f} m' if pe is not None else 'n/a'} (conditioned on "
          f"live track)")
    s = metrics["outlier_suppression_rate"]
    print(f"  outlier suppression: "
          f"{f'{s:.3f}' if s is not None else 'n/a'} "
          f"({metrics['outliers_rejected']}/{metrics['outliers_injected']} "
          f"bogus dips rejected by NIS/range gates before update)")
    n = metrics["mean_nees"]
    print(f"  true NEES: {f'{n:.2f}' if n is not None else 'n/a'} "
          f"(ideal ~= 4; n={metrics['nees_updates']} updates)")
    print("===== END REPORT =====")
    print(CAVEAT)


# ---------------------------------------------------------------- modes

SCHEMA = ["t_iso", "link_key", "from_node", "to_node", "snr_db", "dip_db",
          "truth_x", "truth_y", "truth_id"]


def write_csv(rows, path):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=SCHEMA)
        w.writeheader()
        w.writerows(rows)


def synth_cv_truth(seed):
    """Constant-velocity straight-line trajectory: the A3 synthetic baseline
    (same outlier/dropout schedule, dynamics the CV tracker was tuned on)."""
    rng = np.random.default_rng(seed)
    n = int(STANDIN["duration_s"] * STANDIN["truth_hz"])
    t0 = datetime(2026, 10, 18, 12, 0, 0, tzinfo=timezone.utc)
    ang = rng.uniform(0, 2 * math.pi)
    vx, vy = 15.0 * math.cos(ang), 15.0 * math.sin(ang)
    x0, y0 = -250.0, -250.0
    return [((t0 + timedelta(seconds=i / STANDIN["truth_hz"])).isoformat(),
             x0 + vx * i / STANDIN["truth_hz"],
             y0 + vy * i / STANDIN["truth_hz"]) for i in range(n)]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    args = sys.argv[1:]
    print("AERPAW replay harness -- offline fusion-machinery validation")
    print(CAVEAT)
    print(f"provenance: {PROVENANCE_LABEL}\n")

    if "--emit-fixture" in args:
        seed = 20261018
        paths = make_standin(seed, os.path.join(here, "aerpaw_standin"))
        data = load_standin(os.path.join(here, "aerpaw_standin"))
        truth = [(r["t_iso"], float(r["x"]), float(r["y"]))
                 for r in data["aerpaw_standin_truth.csv"]]
        rows, meta = replay_rows(truth, seed)
        out = args[args.index("--emit-fixture") + 1] \
            if len(args) > args.index("--emit-fixture") + 1 \
            and not args[args.index("--emit-fixture") + 1].startswith("-") \
            else os.path.join(here, "aerpaw_replay_golden.csv")
        write_csv(rows, out)
        with open(out + ".meta.json", "w") as f:
            json.dump({"seed": seed, "provenance": PROVENANCE_LABEL,
                       "generator": "replay_aerpaw.py --emit-fixture",
                       "n_rows": len(rows), "meta": meta}, f, indent=1,
                      default=str)
        print(f"[replay] golden fixture: {len(rows)} rows -> {out}")
        print(f"[replay] meta (seed, provenance) -> {out}.meta.json")
        return

    if "--verify-fixture" in args:
        golden = os.path.join(here, "aerpaw_replay_golden.csv")
        meta = json.load(open(golden + ".meta.json"))
        seed = meta["seed"]
        data = load_standin(os.path.join(here, "aerpaw_standin"))
        truth = [(r["t_iso"], float(r["x"]), float(r["y"]))
                 for r in data["aerpaw_standin_truth.csv"]]
        rows, _ = replay_rows(truth, seed)
        with open(golden, newline="") as f:
            golden_rows = list(csv.DictReader(f))
        ok = (len(rows) == len(golden_rows) and all(
            all(str(r[k]) == str(g[k]) for k in SCHEMA)
            for r, g in zip(rows, golden_rows)))
        print(f"[replay] fixture verification: "
              f"{'PASS -- golden CSV reproduces byte-identically '
                if ok else 'FAIL -- MISMATCH '} (seed {seed})")
        sys.exit(0 if ok else 1)

    if "--baseline-synth" in args:
        seed = 4242
        truth = synth_cv_truth(seed)
        rows, meta = replay_rows(truth, seed)
        tracks, counters = run_fusion(rows, meta)
        m = score(tracks, truth, counters)
        print_report(m, "synthetic CV baseline (A3 comparison)",
                     "synthetic constant-velocity trajectory; same outlier "
                     "schedule; " + PROVENANCE_LABEL)
        return

    csv_path = args[0] if args and not args[0].startswith("-") else \
        os.path.join(here, "aerpaw_replay_golden.csv")
    if not os.path.isfile(csv_path):
        sys.exit(f"[replay] no CSV at {csv_path}; run with "
                 f"--emit-fixture first")
    rows = list(csv.DictReader(open(csv_path, newline="")))
    # rebuild the mesh deterministically from the CSV's truth span
    truth_pts = [(r["t_iso"], float(r["truth_x"]), float(r["truth_y"]))
                 for r in rows if r["truth_id"] == "UAV"]
    if not truth_pts:
        sys.exit("[replay] CSV has no UAV truth rows; cannot score")
    _nodes, _links, _span = build_mesh([p[1] for p in truth_pts],
                                      [p[2] for p in truth_pts])
    meta_path = csv_path + ".meta.json"
    if os.path.isfile(meta_path):
        meta = json.load(open(meta_path))["meta"]
        # meta stores nodes as lists; convert back to tuples
        meta["nodes"] = {k: tuple(v) for k, v in meta["nodes"].items()}
    else:
        _rows, meta = replay_rows(truth_pts, seed=0)
        meta["nodes"] = _nodes
    tracks, counters = run_fusion(rows, meta)
    m = score(tracks, truth_pts, counters)
    print_report(m, os.path.basename(csv_path),
                 "labeled synthetic stand-in" if "standin" in PROVENANCE_LABEL
                 else PROVENANCE_LABEL)


if __name__ == "__main__":
    main()
