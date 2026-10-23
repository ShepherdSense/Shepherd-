#!/usr/bin/env python3
"""Link-dropout bench for the disturbance classifier.

Evaluates OLD (pre-v0.24.0 shipped) vs NEW (retrained) disturbance_clf
weights on the SAME synthetic bench set while 0..14 non-primary links
are masked out at feature level (see apply_link_dropout_features in
train_disturbance_clf.py and the runtime assumption in
docs/link_dropout_bench.md).

The bench set is generated with the NEW (trajectory-diverse)
generators at a FIXED mesh size of 15 links (a full 6-node mesh, the
largest reference geometry in docs/mesh_mode_spec.md), seed 999,
1,000 examples per class. It is a holdout-style synthetic set: neither
model was trained on seed 999. The OLD model is loaded from its saved
JSON (a pure-numpy forward pass replicating TinyMlp: standardize ->
relu -> relu -> softmax), so the comparison needs no retraining of
the old corpus.

Usage:
  python tools/bench_link_dropout.py \
      [--old /tmp/shepherd_old_clf/disturbance_clf.json.orig] \
      [--new assets/models/disturbance_clf.json] \
      [--out /tmp/link_dropout_bench.json]
"""
import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_disturbance_clf import (CLASSES, apply_link_dropout_features,
                                   make_dataset)

MESH_LINKS = 15
BENCH_SEED = 999
N_PER_CLASS = 1000
DROPS = [0, 1, 2, 3, 4, 6, 8, 10, 12, 14]


def load_json_model(path):
    with open(path) as f:
        return json.load(f)


def predict(model, X):
    """Numpy forward pass replicating lib/services/tiny_ml.dart."""
    mean = np.array(model["scaler_mean"])
    scale = np.array(model["scaler_scale"])
    a = (np.array(X, dtype=float) - mean) / scale
    layers = model["layers"]
    for li, layer in enumerate(layers):
        W = np.array(layer["W"])   # W[out][in]
        b = np.array(layer["b"])
        a = a @ W.T + b
        if li < len(layers) - 1:
            a = np.maximum(a, 0.0)
    # softmax
    a = a - a.max(axis=1, keepdims=True)
    e = np.exp(a)
    probs = e / e.sum(axis=1, keepdims=True)
    classes = model["classes"]
    return np.array([classes[i] for i in np.argmax(probs, axis=1)])


def accuracy(pred, y):
    return float(np.mean(pred == y))


def per_class(pred, y):
    return {c: (accuracy(pred[y == c], y[y == c]), int((y == c).sum()))
            for c in CLASSES}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", default="/tmp/shepherd_old_clf/disturbance_clf.json.orig")
    ap.add_argument("--new", default=None,
                    help="default: <repo>/assets/models/disturbance_clf.json")
    ap.add_argument("--out", default="/tmp/link_dropout_bench.json")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    new_path = args.new or os.path.join(root, "assets", "models",
                                        "disturbance_clf.json")
    old_model = load_json_model(args.old)
    new_model = load_json_model(new_path)

    X, y = make_dataset(n_per_class=N_PER_CLASS, seed=BENCH_SEED,
                        mesh_links=MESH_LINKS)
    print(f"bench set: n={len(X)} mesh_links={MESH_LINKS} seed={BENCH_SEED}")

    results = {}
    for k in DROPS:
        Xm = np.array([apply_link_dropout_features(x, k) for x in X])
        po = predict(old_model, Xm)
        pn = predict(new_model, Xm)
        results[k] = {
            "old_acc": accuracy(po, y),
            "new_acc": accuracy(pn, y),
            "old_per_class": {c: v[0] for c, v in per_class(po, y).items()},
            "new_per_class": {c: v[0] for c, v in per_class(pn, y).items()},
        }
        print(f"dropped={k:2d}  old={results[k]['old_acc']:.4f}  "
              f"new={results[k]['new_acc']:.4f}")

    with open(args.out, "w") as f:
        json.dump({"mesh_links": MESH_LINKS, "bench_seed": BENCH_SEED,
                   "n_per_class": N_PER_CLASS, "drops": DROPS,
                   "results": {str(k): v for k, v in results.items()}}, f,
                  indent=2)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
