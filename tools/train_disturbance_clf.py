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
confidence, never as identifications. Synthetic holdout accuracy does
NOT establish field accuracy; no real-data validation loop exists yet
(see docs/tinyml_boundary.md).

The feature function below is mirrored EXACTLY in
lib/services/ai_classifier.dart. A golden test vector is exported to
test/ai_golden.json so the Dart inference kernel is verified
numerically against this script.

Output: assets/models/disturbance_clf.json (weights + scaler + metadata)
Requires: scikit-learn, numpy  (see ~/workspace/.mlvenv)

------------------------------------------------------------------------
v0.24.0 corpus regeneration (2026-10-23) — TRAJECTORY-DYNAMICS DIVERSITY

Motivation: WiFi-JEPA (Kim et al., arXiv:2607.11064) found simulated
primitives with RANDOMIZED trajectories matched real-data pretraining,
while realistic meshes with FIXED trajectories caused NEGATIVE transfer.
The old generators drew each event from narrow, near-fixed parameter
ranges (e.g. PASSING duration ~ U(1,7) s, peak centred at 0.3–0.7 of the
window, one symmetric Gaussian shape). The generators below instead
randomize, per event:

  * speed (0.3–3.5 m/s for crossings; duration derives from
    speed x effective shadow-path length, not a fixed duration range),
  * heading (perpendicular vs grazing -> asymmetric rise/fall widths
    and shallower peaks for grazing crossings),
  * start point / peak position (0.1–0.9 of the window),
  * loiter duration (log-spread ~10–300 s) and loiter behaviour
    (wandering level, partial departures and re-entries),
  * interference pattern family (sine flicker / random bursts / chirp),
  * fault behaviour (drift rate, optional mid-event step).

Plus the two body-worn effects docs/mesh_mode_spec.md requires the
synthetic scenarios to include:

  * GAIT WOBBLE — a periodic amplitude modulation at a randomized
    step frequency (~1.4–2.4 Hz) on mover classes.
  * BODY-SHADOW DROPOUTS — short 1–4-sample winks where the dip
    collapses toward zero (2.4 GHz body shadowing), inserted at
    random positions in mover classes.

Everything stays SEEDED and deterministic: SEED = 7 (same seed as the
original script) drives the global `random` / `numpy` streams, and the
link-dropout augmentation uses its own dedicated Random(SEED + 12345)
stream, so re-running this script reproduces the shipped corpus,
split, and weights bit-for-bit (modulo sklearn/BLAS threading).

------------------------------------------------------------------------
LINK-DROPOUT AUGMENTATION + BENCH (docs/link_dropout_bench.md)

RUNTIME ASSUMPTION (explicit): the 10-feature input has NO per-link
vector, so a missing link cannot be represented directly. Reading
lib/state/app_state.dart `_classifyEvent`: the classifier is only ever
invoked for an event on a SURVIVING (primary) link, and other links
enter the feature vector only through three aggregate channels —
`log_simul_links` (links disturbed within the last 5 s), `cross_driver`
(>1 driver among those), and `log_mesh_links` (link count). A dropped
link therefore shows up at runtime ONLY as a smaller simultaneous-link
count, a possibly-cleared cross_driver flag, and a smaller mesh-link
count. (Nuance: mid-session, AppState's `history` map retains keys for
links seen earlier, so log_mesh_links can lag reality until a session
restart; the bench's mesh reduction is the conservative, post-restart
value.) Masking is therefore implemented at FEATURE level in
`apply_link_dropout_features`: dropped links are assumed to be
non-primary links; simul_links and mesh_links shrink by the drop
count (floored so the primary link remains), and cross_driver clears
when fewer than 2 simultaneous links survive. The dips series itself
is NOT touched — a dropped non-primary link never contributed samples
to the primary link's series, and a dropped primary link produces no
event to classify at all.

Training augmentation: a fraction of TRAINING examples (never holdout)
get a masked copy appended, so the model learns the masked region of
feature space instead of extrapolating into it.
"""
import json
import math
import os
import random
from datetime import datetime, timezone

import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler

SEED = 7  # deterministic corpus/split seed (unchanged from original)

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

# indices into the feature vector (order contract — do not reorder)
F_SIMUL = 4
F_CROSS = 5
F_MESH = 9

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

# ------------------------------------------------------- link dropout

def apply_link_dropout_features(features, dropped):
    """Return a copy of a raw 10-feature vector as the runtime would
    see it after `dropped` non-primary links are lost.

    See the module docstring for the runtime assumption this encodes:
    only log_simul_links / cross_driver / log_mesh_links change; the
    primary link's own dip-derived features are untouched.
    """
    x = [float(v) for v in features]
    if dropped <= 0:
        return x
    simul = int(round(10 ** x[F_SIMUL] - 1))
    mesh = int(round(10 ** x[F_MESH] - 1))
    # The primary (event) link survives by definition; other
    # simultaneous links are lost first.
    simul_new = max(1, simul - dropped) if simul >= 1 else 0
    mesh_new = max(simul_new, mesh - dropped)
    x[F_SIMUL] = math.log10(simul_new + 1.0)
    x[F_MESH] = math.log10(mesh_new + 1.0)
    if simul_new < 2:
        x[F_CROSS] = 0.0
    return x


def augment_with_link_dropout(X, y, frac=0.40, max_drop=10, seed=SEED + 12345):
    """Append masked copies of a `frac` fraction of rows. Training
    split ONLY — applying this to holdout would leak and would also
    stop the holdout from being the clean reference number."""
    rng = random.Random(seed)
    extra_X, extra_y = [], []
    for i in range(len(X)):
        if rng.random() < frac:
            k = rng.randint(1, max_drop)
            extra_X.append(apply_link_dropout_features(X[i], k))
            extra_y.append(y[i])
    if not extra_X:
        return X, y
    return (np.vstack([X, np.array(extra_X)]),
            np.concatenate([y, np.array(extra_y)]))

# ---------------------------------------------------------------- generator

def _noisy(series, thr, sigma=0.15):
    return [max(0.0, d + random.gauss(0, sigma * thr)) for d in series]


def _gait_wobble(series, sample_rate=4.0):
    """Periodic amplitude modulation from walking gait (mesh_mode_spec
    §7: gait puts a rhythmic wobble on every link). Randomized step
    frequency and depth; skipped for some events (standing / vehicle).
    """
    if random.random() < 0.25:
        return series
    freq = random.uniform(1.4, 2.4)          # steps per second
    amp = random.uniform(0.04, 0.18)         # fractional depth
    phase = random.uniform(0, 6.283)
    return [max(0.0, d * (1.0 + amp * math.sin(phase + 6.283 * freq * i / sample_rate)))
            for i, d in enumerate(series)]


def _body_shadow_dropouts(series):
    """Short winks where the dip collapses (2.4 GHz body shadowing as
    people turn — mesh_mode_spec §7: expected, not a fault). 1–3
    segments of 1–4 samples scaled down to 0–30%."""
    if random.random() < 0.30:
        return series
    out = list(series)
    n = len(out)
    for _ in range(random.randint(1, 3)):
        start = random.randint(0, max(0, n - 2))
        length = random.randint(1, 4)
        scale = random.uniform(0.0, 0.3)
        for j in range(start, min(n, start + length)):
            out[j] *= scale
    return out


def gen_passing(thr):
    # Trajectory: random speed x random shadow-path length -> duration.
    speed = random.uniform(0.3, 3.5)             # m/s: slow walk .. run
    path = random.uniform(2.0, 9.0)              # effective shadow width, m
    dur = min(14.0, max(0.8, path / speed))
    n = max(4, int(dur * 4))
    # Heading: grazing crossings are longer, shallower, asymmetric.
    grazing = random.random()                  # 0 = perpendicular, 1 = grazing
    peak = random.uniform(1.5, 4.0) * thr * (1.0 - 0.3 * grazing)
    t0 = random.uniform(0.1, 0.9) * n            # randomized start/peak point
    w = random.uniform(0.15, 0.4) * n * (1.0 + 0.8 * grazing)
    asym = random.uniform(0.5, 2.0)              # fall width / rise width
    series = []
    for i in range(n):
        ww = w if i <= t0 else w * asym
        series.append(peak * math.exp(-((i - t0) / ww) ** 2))
    series = _body_shadow_dropouts(_gait_wobble(series))
    return _noisy(series, thr), dur, random.randint(1, 3)


def gen_lingering(thr):
    # Loiter duration: log-spread so short and long stays both appear.
    dur = min(300.0, 10.0 * (10 ** random.uniform(0.0, 1.3)))
    n = max(8, int(dur * 4))
    peak = random.uniform(1.2, 3.0) * thr
    ramp = max(2, int(n * random.uniform(0.05, 0.25)))
    # Wandering presence level (the mover shifts, turns, sits).
    wander_f = random.uniform(0.5, 3.0)
    wander_ph = random.uniform(0, 6.283)
    # Partial departures: 0–2 intervals where the level sags.
    sags = []
    for _ in range(random.randint(0, 2)):
        s0 = random.randint(ramp, max(ramp, n - ramp - 2))
        sags.append((s0, s0 + random.randint(2, max(3, n // 6)),
                     random.uniform(0.2, 0.6)))
    series = []
    for i in range(n):
        if i < ramp:
            level = peak * i / ramp
        elif i > n - ramp:
            level = peak * (n - i) / ramp
        else:
            level = peak * random.uniform(0.85, 1.0)
            level *= 0.9 + 0.1 * math.sin(wander_ph + wander_f * i / n * 6.283)
            for s0, s1, sc in sags:
                if s0 <= i < s1:
                    level *= sc
        series.append(level)
    series = _body_shadow_dropouts(_gait_wobble(series))
    return _noisy(series, thr), dur, random.randint(1, 4)


def gen_interference(thr):
    dur = random.uniform(1.0, 40.0)
    n = max(8, int(dur * 4))
    peak = random.uniform(1.05, 3.0) * thr
    pattern = random.choice(["sine", "bursts", "chirp"])
    if pattern == "sine":
        f = random.uniform(0.5, 3.0)
        ph = random.uniform(0, 6.28)
        series = [peak * abs(math.sin(ph + f * i / n * 6.28))
                  * random.uniform(0.4, 1.0) for i in range(n)]
    elif pattern == "bursts":
        # Random telegraph bursts: on/off blocks of random length.
        series = []
        on = random.random() < 0.5
        left = random.randint(1, 8)
        for _ in range(n):
            if left == 0:
                on = not on
                left = random.randint(1, 8)
            left -= 1
            series.append(peak * random.uniform(0.7, 1.0) if on
                          else peak * random.uniform(0.0, 0.25))
    else:  # chirp: flicker frequency sweeps across the event
        f0, f1 = random.uniform(0.3, 1.0), random.uniform(2.0, 4.0)
        ph = random.uniform(0, 6.28)
        series = []
        phase = ph
        for i in range(n):
            f = f0 + (f1 - f0) * i / n
            phase += f / n * 6.283
            series.append(peak * abs(math.sin(phase)) * random.uniform(0.4, 1.0))
    return _noisy(series, thr, sigma=0.25), dur, 1 if random.random() < 0.7 else 2


def gen_fault(thr):
    dur = min(600.0, 20.0 * (10 ** random.uniform(0.0, 1.5)))
    n = max(8, int(dur * 4))
    pinned = random.uniform(3.5, 9.0) * thr
    drift = random.uniform(-0.05, 0.05) * thr    # slow drift rate
    # Optional mid-event step (sensor re-seats / connector shifts).
    step_at = random.randint(0, n - 1) if random.random() < 0.3 else None
    step = random.uniform(-0.3, 0.3) * pinned
    series = []
    for i in range(n):
        v = pinned + drift * math.sin(i / 50.0) + 0.01 * thr * random.gauss(0, 1)
        if step_at is not None and i >= step_at:
            v += step
        series.append(max(0.0, v))
    return series, dur, 1

GENERATORS = {
    "PASSING": gen_passing,
    "LINGERING": gen_lingering,
    "INTERFERENCE": gen_interference,
    "FAULT": gen_fault,
}

def make_dataset(n_per_class=5000, seed=SEED, mesh_links=None):
    """Generate the synthetic corpus.

    mesh_links: None -> per-event mesh size ~ U[2, 40] links (original
    behaviour); an int fixes every event's mesh size (used by the
    link-dropout bench, which needs a known starting mesh).
    """
    random.seed(seed)
    np.random.seed(seed)
    X, y = [], []
    for label, gen in GENERATORS.items():
        for _ in range(n_per_class):
            thr = random.uniform(4.0, 10.0)
            dips, dur, simul = gen(thr)
            cross = simul > 1 and random.random() < 0.35
            mesh = mesh_links if mesh_links is not None else random.randint(2, 40)
            X.append(extract_features(dips, thr, dur, simul, cross, mesh))
            y.append(label)
    return np.array(X), np.array(y)

# ---------------------------------------------------------------- main

def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-aug", action="store_true",
                    help="train WITHOUT link-dropout augmentation "
                         "(the ablation column of docs/link_dropout_bench.md)")
    ap.add_argument("--out", default=None,
                    help="model output path (default: the shipped asset); "
                         "the golden file is only written with the default "
                         "output, so ablation runs never touch it")
    args = ap.parse_args(argv)

    X, y = make_dataset()
    idx = np.random.permutation(len(X))
    cut = int(0.8 * len(X))
    Xtr, Xte, ytr, yte = X[idx[:cut]], X[idx[cut:]], y[idx[:cut]], y[idx[cut:]]

    # Link-dropout augmentation: TRAIN split only (see docstring).
    n_base_train = len(Xtr)
    if args.no_aug:
        print(f"train: {n_base_train} base + 0 link-dropout-augmented "
              f"(--no-aug ablation)")
    else:
        Xtr, ytr = augment_with_link_dropout(Xtr, ytr)
        print(f"train: {n_base_train} base + {len(Xtr) - n_base_train} "
              f"link-dropout-augmented = {len(Xtr)}")

    scaler = StandardScaler().fit(Xtr)
    clf = MLPClassifier(hidden_layer_sizes=(24, 12), activation="relu",
                        max_iter=800, random_state=SEED)
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
        "note": "Trained on SYNTHETIC disturbance models (v0.24.0 corpus: "
                "trajectory-dynamics diversity — randomized speeds, "
                "headings, start points, loiter durations — plus gait "
                "wobble, body-shadow dropouts, and feature-level "
                "link-dropout augmentation; seed 7, deterministic). "
                "Labels are heuristics shown as estimates with "
                "confidence; never identifications. SYNTHETIC HOLDOUT "
                "ACCURACY DOES NOT ESTABLISH FIELD ACCURACY — no "
                "real-data validation has been performed yet. Detection "
                "stays deterministic — this model only classifies what "
                "the tripwire found.",
    }

    if args.no_aug:
        model["note"] += " ABLATION BUILD (--no-aug): trained WITHOUT " \
                         "link-dropout augmentation; not the shipped model."

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(root, "assets", "models",
                                   "disturbance_clf.json")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w") as f:
        json.dump(model, f)
    print("wrote", out)

    if args.out:
        print("custom --out: golden file NOT written (shipped golden "
              "belongs to the shipped weights)")
    else:
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
