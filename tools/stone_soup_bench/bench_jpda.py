#!/usr/bin/env python3
"""Stone Soup multi-target tracker bench on synthetic Shepherd record data.

Pipeline:
    sample_run.csv  (synth_data.py)
      -> position detections: each link whose dip >= threshold becomes a
         detection at the link midpoint + noise (a stand-in for the real
         geometric forward model, which would weight along the link)
      -> Stone Soup GNN tracker (2D constant-velocity)
      -> metrics vs truth + plot

Tracker choice: nearest-neighbour 2D assignment (GNN). JPDA was tried
first -- it is the better algorithm for the crossing in this scenario --
but with the mixture tracker every tentative track receives a mixture
update each step, so the time-since-update deleter never fires and
tentative tracks accumulate until JPDA's joint enumeration stalls
(17+ live tracks by step 115 of 240). GNN + missed-detection updates
lets the deleter work, which is what a modest bench needs. A future
iteration could pair JPDA with an M/N-logic initiator
(MultiMeasurementInitiator).

Metrics printed:
    - tracks initiated, tracks matched to a truth target
    - per-track purity: fraction of associated detections belonging to
      the track's majority truth target ("?" = clutter / no truth)
    - per-track mean position error vs the matched truth trajectory
    - truth targets covered

Usage:
    python3 synth_data.py                      # -> sample_run.csv
    python3 bench_jpda.py [csv] [plot.png]
"""
import csv
import math
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from stonesoup.base import Property
from stonesoup.buffered_generator import BufferedGenerator
from stonesoup.dataassociator.neighbour import GNNWith2DAssignment
from stonesoup.deleter.time import UpdateTimeDeleter
from stonesoup.hypothesiser.distance import DistanceHypothesiser
from stonesoup.initiator.simple import SimpleMeasurementInitiator
from stonesoup.measures import Euclidean
from stonesoup.models.measurement.base import MeasurementModel
from stonesoup.models.measurement.linear import LinearGaussian
from stonesoup.models.transition.linear import (
    CombinedLinearGaussianTransitionModel, ConstantVelocity)
from stonesoup.predictor.kalman import KalmanPredictor
from stonesoup.reader.base import DetectionReader
from stonesoup.tracker.simple import MultiTargetTracker
from stonesoup.types.array import CovarianceMatrix, StateVector
from stonesoup.types.detection import Detection
from stonesoup.types.state import GaussianState
from stonesoup.updater.kalman import KalmanUpdater

# --- scenario (must match synth_data.py) ---------------------------------
NODES = {
    "n0": (0.0, 0.0),
    "n1": (40.0, 0.0),
    "n2": (40.0, 40.0),
    "n3": (0.0, 40.0),
}
DETECT_THRESH_DB = 2.5   # link dip that becomes a detection
MEAS_NOISE_M = 3.0       # midpoint+noise stand-in for the forward model
RNG_SEED = 11


def link_midpoint(fa, fb):
    ax, ay = NODES[fa]
    bx, by = NODES[fb]
    return (ax + bx) / 2.0, (ay + by) / 2.0


def load_rows(csv_path):
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


def build_truth(rows):
    """truth_id -> {t_iso: (x, y)} from the record's truth columns."""
    truth = defaultdict(dict)
    for row in rows:
        if row["truth_id"]:
            truth[row["truth_id"]][row["t_iso"]] = (
                float(row["truth_x"]), float(row["truth_y"]))
    return truth


class CsvDetectionReader(DetectionReader):
    """Yields one detection set per CSV timestep.

    Stone Soup components declare their constructor via Properties;
    loading happens lazily in detections_gen.
    """

    csv_path: str = Property()
    measurement_model: MeasurementModel = Property()

    @BufferedGenerator.generator_method
    def detections_gen(self):
        rows = load_rows(self.csv_path)
        per_t = defaultdict(list)
        for row in rows:
            per_t[row["t_iso"]].append(row)
        rng = np.random.default_rng(RNG_SEED)
        for t_iso in sorted(per_t):
            t = datetime.fromisoformat(t_iso)
            dets = set()
            for row in per_t[t_iso]:
                if float(row["dip_db"]) >= DETECT_THRESH_DB:
                    mx, my = link_midpoint(row["from_node"], row["to_node"])
                    x = mx + rng.normal(0.0, MEAS_NOISE_M)
                    y = my + rng.normal(0.0, MEAS_NOISE_M)
                    dets.add(Detection(
                        StateVector([[x], [y]]),
                        timestamp=t,
                        measurement_model=self.measurement_model,
                        metadata={"truth_id": row["truth_id"] or "?",
                                  "link_key": row["link_key"]}))
            yield t, dets


def build_tracker(reader, measurement_model):
    transition_model = CombinedLinearGaussianTransitionModel(
        [ConstantVelocity(1.0), ConstantVelocity(1.0)])
    predictor = KalmanPredictor(transition_model)
    updater = KalmanUpdater(measurement_model)
    hypothesiser = DistanceHypothesiser(
        predictor, updater,
        measure=Euclidean(),
        missed_distance=8.0)   # gate: detections within 8 m associate
    data_associator = GNNWith2DAssignment(hypothesiser)
    prior = GaussianState(
        StateVector([[20.0], [0.0], [20.0], [0.0]]),
        CovarianceMatrix(np.diag([100.0, 25.0, 100.0, 25.0])))
    initiator = SimpleMeasurementInitiator(prior, measurement_model)
    deleter = UpdateTimeDeleter(timedelta(seconds=4))
    return MultiTargetTracker(
        initiator, deleter, reader, data_associator, updater)


def truth_vote(state):
    """truth_id of the detection most strongly behind this state update."""
    hyp = getattr(state, "hypothesis", None)
    if hyp is None:
        return None
    singles, stack = [], [hyp]
    while stack:                       # unwrap Multiple/Joint hypotheses
        h = stack.pop()
        inner = getattr(h, "hypotheses", None)
        if inner:
            stack.extend(inner)
        else:
            singles.append(h)
    best, best_p = None, -1.0
    for h in singles:
        m = getattr(h, "measurement", None)
        if isinstance(m, Detection):
            p = float(getattr(h, "probability", 0.0) or 0.0)
            if p > best_p:
                best_p = p
                best = (m.metadata or {}).get("truth_id")
    return best


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    csv_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        here, "sample_run.csv")
    plot_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        here, "bench_plot.png")

    measurement_model = LinearGaussian(
        ndim_state=4, mapping=[0, 2],
        noise_covar=CovarianceMatrix(np.diag([MEAS_NOISE_M ** 2] * 2)))
    rows = load_rows(csv_path)
    truth = build_truth(rows)
    n_timesteps = len({r["t_iso"] for r in rows})
    reader = CsvDetectionReader(csv_path, measurement_model)
    print(f"loaded {n_timesteps} timesteps, {len(rows)} link rows "
          f"from {csv_path}")

    tracker = build_tracker(reader, measurement_model)
    all_tracks = {}
    n_steps = 0
    for _timestamp, tracks in tracker:
        n_steps += 1
        for tr in tracks:
            all_tracks[tr.id] = tr
    print(f"tracker finished: {n_steps} steps, "
          f"{len(all_tracks)} tracks initiated")

    # ---- metrics ------------------------------------------------------
    per_track, covered = [], set()
    for tid, tr in sorted(all_tracks.items(), key=lambda kv: str(kv[0])):
        votes = [v for s in tr.states for v in [truth_vote(s)] if v]
        purity = None
        matched = None
        if votes:
            top, n_top = Counter(votes).most_common(1)[0]
            purity = n_top / len(votes)
            matched = top if top != "?" else None
        errs = []
        if matched and matched in truth:
            traj = truth[matched]
            for s in tr.states:
                key = s.timestamp.isoformat()
                if key in traj:
                    tx, ty = traj[key]
                    sv = s.state_vector
                    errs.append(math.hypot(sv[0, 0] - tx, sv[2, 0] - ty))
        mean_err = sum(errs) / len(errs) if errs else None
        if matched:
            covered.add(matched)
        per_track.append({"id": str(tid)[:8], "states": len(tr.states),
                          "purity": purity, "matched": matched,
                          "mean_err": mean_err, "n_votes": len(votes)})

    print("\nper-track results (purity = share of associated detections "
          "from the majority truth target):")
    for r in per_track:
        p = f"{r['purity']:.2f}" if r["purity"] is not None else "n/a"
        e = f"{r['mean_err']:.2f} m" if r["mean_err"] is not None else "n/a"
        print(f"  track {r['id']}: states={r['states']:3d} "
              f"votes={r['n_votes']:3d} purity={p} "
              f"matched={r['matched']} mean_err={e}")

    matched_tracks = [r for r in per_track if r["matched"]]
    purities = [r["purity"] for r in matched_tracks if r["purity"] is not None]
    errs = [r["mean_err"] for r in matched_tracks if r["mean_err"] is not None]
    print(f"\ntracks matched to truth: {len(matched_tracks)}/{len(per_track)}")
    print(f"truth targets covered: {sorted(covered)} "
          f"(of {sorted(truth)})")
    if purities:
        print(f"mean track purity: {sum(purities)/len(purities):.3f}")
    if errs:
        print(f"mean position error vs truth: {sum(errs)/len(errs):.2f} m")

    # ---- plot ---------------------------------------------------------
    fig, ax = plt.subplots(figsize=(9, 9))
    # truth trajectories
    for ttid, traj in sorted(truth.items()):
        pts = [traj[k] for k in sorted(traj)]
        xs, ys = zip(*pts)
        ax.plot(xs, ys, "o-", ms=3, lw=1.5, label=f"truth {ttid}")
    # detections (re-derive from rows with the same rule as the reader)
    dx, dy = [], []
    for row in rows:
        if float(row["dip_db"]) >= DETECT_THRESH_DB:
            mx, my = link_midpoint(row["from_node"], row["to_node"])
            dx.append(mx)
            dy.append(my)
    ax.scatter(dx, dy, s=8, c="gray", alpha=0.35, label="detections")
    # tracks
    for r, (tid, tr) in zip(per_track,
                            sorted(all_tracks.items(), key=lambda kv: str(kv[0]))):
        xs = [s.state_vector[0, 0] for s in tr.states]
        ys = [s.state_vector[2, 0] for s in tr.states]
        ax.plot(xs, ys, "--", lw=1.2,
                label=f"track {r['id']} -> {r['matched']}")
    # nodes
    for nid, (nx, ny) in NODES.items():
        ax.plot(nx, ny, "ks", ms=8)
        ax.text(nx + 0.8, ny + 0.8, nid, fontsize=9)
    ax.set_aspect("equal", adjustable="box")
    ax.set_xlabel("x (m)")
    ax.set_ylabel("y (m)")
    ax.set_title("Stone Soup GNN bench: truth vs detections vs tracks")
    ax.legend(fontsize=8, loc="best")
    fig.tight_layout()
    fig.savefig(plot_path, dpi=110)
    print(f"\nplot saved -> {plot_path}")


if __name__ == "__main__":
    main()
