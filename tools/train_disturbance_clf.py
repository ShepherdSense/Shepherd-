#!/usr/bin/env python3
"""Train RF Sentry's embedded disturbance classifier.

A SMALL, task-oriented neural network — not an LLM. It takes 10 numeric
features describing one closed radio disturbance event and classifies it:

    PASSING      brief transient crossing (seconds)
    LINGERING    sustained presence (tens of seconds to minutes)
    INTERFERENCE flickery/uncorrelated dip pattern (likely RF interference)
    FAULT        flatlined/pinned sensor pattern (likely hardware issue)

Training data is SYNTHETIC: generated from parameterized disturbance
models, so labels are heuristics — the app shows them as estimates with
confidence, never as identifications.

The feature function below is mirrored EXACTLY in
lib/services/ai_classifier.dart. A golden test vector is exported to
test/ai_golden.json so the Dart inference kernel is verified
numerically against this script.

Output: assets/models/disturbance_clf.json (weights + scaler + metadata)
Requires: scikit-learn, numpy  (see .mlvenv)
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
    "peak_over_threshold",   # max dip / threshold
    "log_duration",          # log10(duration_s + 1)
    "rise_fraction",         # index of peak / (n-1)
    "flicker_cv",            # std(dips) / mean(dips)
    "log_simul_links",       # log10(simultaneous disturbed links + 1)
    "cross_driver",          # 1 if >1 driver saw it, else 0
    "duty_cycle",            # fraction of samples above threshold
    "post_peak_decay",       # (peak - last) / peak
    "baseline_noise",        # std(pre-event) / threshold
    "log_mesh_links",        # log10(mesh link count + 1)
]

CLASSES = ["PASSING", "LINGERING", "INTERFERENCE", "FAULT"]

# ---------------------------------------------------------------- features

def extract_features(dips, threshold, duration_s, simul_links,
                     cross_driver, mesh_links):
    dips = [float(d) for d in dips]
    n = len(dips)
    peak = max(dips)
    mean = sum(dips) / n
    var = sum((d - mean) ** 2 for d in dips) / n
    std = math.sqrt(var)
    ipeak = dips.index(peak)
    pre = dips[:max(2, n // 5)]
    pre_mean = sum(pre) / len(pre)
    pre_var = sum((d - pre_mean) ** 2 for d in pre) / len(pre)
    return [
        peak / threshold,
        math.log10(duration_s + 1.0),
        ipeak / max(n - 1, 1),
        std / (mean + 1e-6),
        math.log10(simul_links + 1.0),
        1.0 if cross_driver else 0.0,
        sum(1.0 for d in dips if d >= threshold) / n,
        (peak - dips[-1]) / (peak + 1e-6),
        math.sqrt(pre_var) / threshold,
        math.log10(mesh_links + 1.0),
    ]

# ---------------------------------------------------------------- generator

def _noisy(series, thr, sigma=0.15):
    return [max(0.0, d + random.gauss(0, sigma * thr)) for d in series]

def gen_passing(thr):
    dur = random.uniform(1.0, 7.0)
    n = max(4, int(dur * 4))
    peak = random.uniform(1.5, 4.0) * thr
    t0 = random.uniform(0.3, 0.7) * n
    w = random.uniform(0.15, 0.4) * n
    series = [peak * math.exp(-((i - t0) / w) ** 2) for i in range(n)]
    return _noisy(series, thr), dur, random.randint(1, 3)

def gen_lingering(thr):
    dur = random.uniform(15.0, 120.0)
    n = max(8, int(dur * 4))
    peak = random.uniform(1.2, 3.0) * thr
    ramp = max(2, n // 10)
    series = []
    for i in range(n):
        if i < ramp:
            series.append(peak * i / ramp)
        elif i > n - ramp:
            series.append(peak * (n - i) / ramp)
        else:
            series.append(peak * random.uniform(0.85, 1.0))
    return _noisy(series, thr), dur, random.randint(1, 4)

def gen_interference(thr):
    dur = random.uniform(2.0, 25.0)
    n = max(8, int(dur * 4))
    peak = random.uniform(1.1, 2.5) * thr
    f = random.uniform(0.5, 3.0)
    ph = random.uniform(0, 6.28)
    series = [peak * abs(math.sin(ph + f * i / n * 6.28))
              * random.uniform(0.4, 1.0) for i in range(n)]
    return _noisy(series, thr, sigma=0.25), dur, 1 if random.random() < 0.8 else 2

def gen_fault(thr):
    dur = random.uniform(30.0, 300.0)
    n = max(8, int(dur * 4))
    pinned = random.uniform(4.0, 8.0) * thr
    # flatlined sensor: pinned value, near-zero variance, slow drift
    series = [pinned + 0.02 * thr * math.sin(i / 50.0) for i in range(n)]
    return series, dur, 1

GENERATORS = {
    "PASSING": gen_passing,
    "LINGERING": gen_lingering,
    "INTERFERENCE": gen_interference,
    "FAULT": gen_fault,
}

def make_dataset(n_per_class=5000, seed=7):
    random.seed(seed)
    np.random.seed(seed)
    X, y = [], []
    for label, gen in GENERATORS.items():
        for _ in range(n_per_class):
            thr = random.uniform(4.0, 10.0)
            dips, dur, simul = gen(thr)
            cross = simul > 1 and random.random() < 0.35
            mesh = random.randint(2, 40)
            X.append(extract_features(dips, thr, dur, simul, cross, mesh))
            y.append(label)
    return np.array(X), np.array(y)

# ---------------------------------------------------------------- main

def main():
    X, y = make_dataset()
    idx = np.random.permutation(len(X))
    cut = int(0.8 * len(X))
    Xtr, Xte, ytr, yte = X[idx[:cut]], X[idx[cut:]], y[idx[:cut]], y[idx[cut:]]

    scaler = StandardScaler().fit(Xtr)
    clf = MLPClassifier(hidden_layer_sizes=(24, 12), activation="relu",
                        max_iter=800, random_state=7)
    clf.fit(scaler.transform(Xtr), ytr)
    acc = clf.score(scaler.transform(Xte), yte)
    print(f"holdout accuracy: {acc:.3f}  (n_test={len(Xte)})")
    for c in CLASSES:
        m = yte == c
        a = clf.score(scaler.transform(Xte[m]), yte[m])
        print(f"  {c:12s} acc={a:.3f} n={m.sum()}")

    # golden vector: fixed features -> expected probabilities
    golden_x = [2.5, 0.7, 0.4, 0.25, 0.3, 0.0, 0.9, 0.8, 0.1, 0.7]
    golden_p = clf.predict_proba(scaler.transform([golden_x]))[0]
    print("golden:", [round(float(p), 4) for p in golden_p],
          "->", clf.classes_[int(np.argmax(golden_p))])

    model = {
        "name": "disturbance_clf",
        "version": 1,
        "trained_at": datetime.now(timezone.utc).isoformat(),
        "feature_names": FEATURE_NAMES,
        "classes": list(clf.classes_),
        "scaler_mean": [float(v) for v in scaler.mean_],
        "scaler_scale": [float(v) for v in scaler.scale_],
        "layers": [
            {"W": coefs.T.tolist(), "b": intercepts.tolist()}
            for coefs, intercepts in zip(clf.coefs_, clf.intercepts_)
        ],
        "activation": "relu",
        "holdout_accuracy": round(float(acc), 4),
        "n_train": int(len(Xtr)),
        "note": "Trained on SYNTHETIC disturbance models. "
                "Labels are heuristics shown as estimates with confidence; "
                "never identifications. Detection stays deterministic — "
                "this model only classifies what the tripwire found.",
    }

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "assets", "models", "disturbance_clf.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(model, f)
    print("wrote", out)

    golden = {"x": golden_x,
              "probs": [float(p) for p in golden_p],
              "classes": list(clf.classes_)}
    gout = os.path.join(root, "test", "ai_golden.json")
    os.makedirs(os.path.dirname(gout), exist_ok=True)
    with open(gout, "w") as f:
        json.dump(golden, f)
    print("wrote", gout)

if __name__ == "__main__":
    main()
