#!/usr/bin/env python3
"""Train RF Sentry's track-stitching specialist.

A SMALL, task-oriented neural network — not an LLM. It answers one
question: given a disturbance detection that just went quiet on radio A
and a fresh disturbance detection on radio B, are they the SAME physical
mover traveling between meshes?

This is the learned follow-up to the deterministic cross-driver tracker
(grid search + time/space continuity). The deterministic layer runs
first; the stitcher scores ambiguous handoffs and the app shows its
verdict as an estimate with confidence, never as fact.

Training data is SYNTHETIC: two-mesh scenarios with movers on random
constant-velocity paths. Positive pairs = the same mover's detections
on both meshes. Negative pairs = unrelated detections (independent
movers / distractors).

Feature order MUST match lib/services/track_stitcher.dart.
Output: assets/models/track_stitcher.json + test/stitcher_golden.json
Requires: scikit-learn, numpy (see .mlvenv)
"""
import json
import math
import os
import random
from datetime import datetime, timezone

import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler

FEATURE_NAMES = [
    "gap_norm",        # (tB_first - tA_last) / 60  (can be negative)
    "log_dist",        # log10(centroid distance m + 1)
    "log_speed",       # log10(implied speed m/s + 0.1)
    "speed_plaus",      # exp(-(ln(implied/4))^2 / 2): mover-like speed?
    "dip_sim",         # 1 - |dipA-dipB|/(dipA+dipB)
    "overlap",         # 1 if detection windows overlap else 0
    "log_links",       # log10(nlinksA + nlinksB)
    "dir_cos",         # cos(angle) between A->B vector and A heading
]

# ---------------------------------------------------------------- scenarios

def _dist_pt_seg(px, py, ax, ay, bx, by):
    abx, aby = bx - ax, by - ay
    apx, apy = px - ax, py - ay
    l2 = abx * abx + aby * aby
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, (apx * abx + apy * aby) / l2))
    cx, cy = ax + abx * t - px, ay + aby * t - py
    return math.hypot(cx, cy)

def random_mesh(cx, cy):
    n = random.randint(2, 4)
    nodes = [(cx + random.uniform(-25, 25), cy + random.uniform(-25, 25))
             for _ in range(n)]
    links = []
    for i in range(n):
        for j in range(i + 1, n):
            links.append((nodes[i], nodes[j]))
    return nodes, links

def detect_on_mesh(mover, mesh, t0=0.0, dt=0.5, sigma=11.0, thr=6.0):
    """Simulate one mover crossing one mesh. Returns a detection dict or None."""
    nodes, links = mesh
    (sx, sy), (vx, vy), dur = mover
    hits = []  # (t, mx, my, dip)
    t = t0
    while t < t0 + dur:
        px, py = sx + vx * t, sy + vy * t
        for (ax, ay), (bx, by) in links:
            d = _dist_pt_seg(px, py, ax, ay, bx, by)
            dip = 30.0 * math.exp(-((d / sigma) ** 2))
            if dip >= thr:
                hits.append((t, (ax + bx) / 2, (ay + by) / 2, dip))
        t += dt
    if not hits:
        return None
    ts = [h[0] for h in hits]
    cx = sum(h[1] for h in hits) / len(hits)
    cy = sum(h[2] for h in hits) / len(hits)
    return {
        "t_first": min(ts), "t_last": max(ts),
        "x": cx, "y": cy,
        "peak": max(h[3] for h in hits),
        "nlinks": len({(round(h[1]), round(h[2])) for h in hits}),
        "heading": math.atan2(vy, vx),
    }

def pair_features(a, b):
    gap = b["t_first"] - a["t_last"]
    dist = math.hypot(b["x"] - a["x"], b["y"] - a["y"])
    dt_first = max(b["t_first"] - a["t_first"], 1.0)
    implied = dist / dt_first
    ab_ang = math.atan2(b["y"] - a["y"], b["x"] - a["x"])
    dcos = math.cos(ab_ang - a["heading"])
    overlap = 1.0 if (a["t_first"] < b["t_last"]
                      and b["t_first"] < a["t_last"]) else 0.0
    return [
        gap / 60.0,
        math.log10(dist + 1.0),
        math.log10(implied + 0.1),
        math.exp(-(math.log(implied / 4.0 + 1e-9) ** 2) / 2.0),
        1.0 - abs(a["peak"] - b["peak"]) / (a["peak"] + b["peak"] + 1e-9),
        overlap,
        math.log10(a["nlinks"] + b["nlinks"]),
        dcos,
    ]

def make_dataset(n_scenarios=6000, seed=11):
    random.seed(seed)
    np.random.seed(seed)
    X, y = [], []
    for _ in range(n_scenarios):
        # Two meshes, 40-250 m apart.
        ang = random.uniform(0, 2 * math.pi)
        sep = random.uniform(40, 250)
        bcx, bcy = sep * math.cos(ang), sep * math.sin(ang)
        mesh_a = random_mesh(0, 0)
        mesh_b = random_mesh(bcx, bcy)
        # Through-mover: starts near mesh A, aimed at mesh B (+noise),
        # long enough to reach it. This reliably yields positive pairs.
        spd = random.uniform(1, 20)
        hdg = ang + random.uniform(-0.5, 0.5)
        sx = random.uniform(-30, 30)
        sy = random.uniform(-30, 30)
        dur = sep / spd + random.uniform(20, 80)
        mover = ((sx, sy), (spd * math.cos(hdg), spd * math.sin(hdg)), dur)
        da = detect_on_mesh(mover, mesh_a)
        db = detect_on_mesh(mover, mesh_b)
        dets_a = [da] if da else []
        dets_b = [db] if db else []
        # Distractor events on each mesh (independent movers).
        for _ in range(random.randint(0, 2)):
            spd2 = random.uniform(1, 20)
            hdg2 = random.uniform(0, 2 * math.pi)
            m2 = ((random.uniform(-60, 60), random.uniform(-60, 60)),
                  (spd2 * math.cos(hdg2), spd2 * math.sin(hdg2)),
                  random.uniform(20, 120))
            d = detect_on_mesh(m2, mesh_a, t0=random.uniform(0, 200))
            if d:
                dets_a.append(d)
        for _ in range(random.randint(0, 2)):
            spd2 = random.uniform(1, 20)
            hdg2 = random.uniform(0, 2 * math.pi)
            m2 = ((random.uniform(-60, 60), random.uniform(-60, 60)),
                  (spd2 * math.cos(hdg2), spd2 * math.sin(hdg2)),
                  random.uniform(20, 120))
            d = detect_on_mesh(m2, mesh_b, t0=random.uniform(0, 200))
            if d:
                dets_b.append(d)
        if not dets_a or not dets_b:
            continue
        # Positive: the through-mover's own pair.
        if da and db:
            X.append(pair_features(da, db))
            y.append(1)
            # Hard negatives: da paired with unrelated B-side activity
            # (decoy detections at random times/places).
            for _ in range(3):
                decoy = {
                    "t_first": db["t_first"] + random.uniform(-300, 300),
                    "t_last": db["t_first"] + random.uniform(-300, 300)
                              + random.uniform(5, 120),
                    "x": bcx + random.uniform(-150, 150),
                    "y": bcy + random.uniform(-150, 150),
                    "peak": random.uniform(6, 40),
                    "nlinks": random.randint(1, 6),
                    "heading": random.uniform(0, 2 * math.pi),
                }
                if decoy["t_last"] < decoy["t_first"]:
                    decoy["t_first"], decoy["t_last"] = \
                        decoy["t_last"], decoy["t_first"]
                X.append(pair_features(da, decoy))
                y.append(0)
        # Negatives: every cross pairing that is NOT the true pair.
        for a in dets_a:
            for b in dets_b:
                if da and db and a is da and b is db:
                    continue
                if random.random() < 0.6:
                    X.append(pair_features(a, b))
                    y.append(0)
    return np.array(X), np.array(y)

# ---------------------------------------------------------------- main

def main():
    X, y = make_dataset()
    print(f"pairs: {len(X)}  positive rate: {y.mean():.3f}")
    idx = np.random.permutation(len(X))
    cut = int(0.8 * len(X))
    Xtr, Xte, ytr, yte = X[idx[:cut]], X[idx[cut:]], y[idx[:cut]], y[idx[cut:]]

    scaler = StandardScaler().fit(Xtr)
    clf = MLPClassifier(hidden_layer_sizes=(16, 8), activation="relu",
                        max_iter=800, random_state=11)
    clf.fit(scaler.transform(Xtr), ytr)
    acc = clf.score(scaler.transform(Xte), yte)
    print(f"holdout accuracy: {acc:.3f}  (n_test={len(Xte)})")

    golden_x = [0.5, 1.7, 0.7, 0.9, 0.85, 0.0, 0.6, 0.95]
    golden_p = clf.predict_proba(scaler.transform([golden_x]))[0]
    print("golden:", [round(float(p), 4) for p in golden_p])

    model = {
        "name": "track_stitcher",
        "version": 1,
        "trained_at": datetime.now(timezone.utc).isoformat(),
        "feature_names": FEATURE_NAMES,
        "classes": [str(c) for c in clf.classes_],
        "scaler_mean": [float(v) for v in scaler.mean_],
        "scaler_scale": [float(v) for v in scaler.scale_],
        "layers": [
            {"W": coefs.T.tolist(), "b": intercepts.tolist()}
            for coefs, intercepts in zip(clf.coefs_, clf.intercepts_)
        ],
        "activation": "relu",
        "holdout_accuracy": round(float(acc), 4),
        "n_train": int(len(Xtr)),
        "note": "Trained on SYNTHETIC two-mesh crossing scenarios. "
                "Scores P(same mover) for a detection handoff between "
                "radios. Shown as an estimate with confidence; the "
                "deterministic tracker remains the primary associator.",
    }
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "assets", "models", "track_stitcher.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(model, f)
    print("wrote", out)

    golden = {"x": golden_x,
              "probs": [float(p) for p in golden_p],
              "classes": [str(c) for c in clf.classes_]}
    gout = os.path.join(root, "test", "stitcher_golden.json")
    os.makedirs(os.path.dirname(gout), exist_ok=True)
    with open(gout, "w") as f:
        json.dump(golden, f)
    print("wrote", gout)

if __name__ == "__main__":
    main()
