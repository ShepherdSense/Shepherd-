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

------------------------------------------------------------------------
KIM TUNING DISCIPLINE (v0.25.0; Kim et al., arXiv:2505.04085v2, §6.12.1
of the lane-1 research notes) — SPARSE-RTI RECONSTRUCTION PARAMETERS,
NOT the MLP classifier above. The classifier above is untouched by
this section; what is added here is the discipline Kim et al. used
for their multipath-RTI reconstruction, ported to Shepherd's sparse
link-shadow imaging as a Python-side tuning tool:

  * Elastic Net (l1 + l2) reconstruction of a disturbance image from
    a link-disturbance vector, instead of hand-picked weights;
  * path thickness gamma: the ellipse/thickness scale of the
    link-pixel weight model, tuned alongside alpha;
  * DBSCAN clustering on the BINARIZED image as the blob extractor;
  * alpha and gamma tuned by OPTIMIZATION ON RECORDED DATA (grid
    search over a candidate set, scored against known target
    positions -- Kim et al. used Bayesian optimization against
    ground truth; grid search is the deterministic, dependency-free
    equivalent used here, and the distinction is stated, not hidden);
  * the tuned values are LOGGED PER DEPLOYMENT (JSONL, one record
    per tuning run, with data provenance attached -- a deployment
    must never silently reuse another site's tuned values).

WHAT THIS PAPER DOES *NOT* SUPPORT (do not upgrade on it): Kim et
al. ran multipath-RTI with ray-traced paths and 8-element arrays;
their few-node results do NOT rescue plain single-antenna RSS RTI,
and their paper explicitly leaves the 6-node plain-RSS question
unanswered. Shepherd's standing 6-node / 15-link imaging bound of
~1-2 m is UNCHANGED by this work. This section tunes parameters
for the imaging we already do; it does not claim better imaging.

SIZE-AWARE DETECTION-THRESHOLD CAVEAT (load-bearing): Kim et al.
measured that a LARGER subject moderately increases error while a
SLIMMER subject SIGNIFICANTLY DEGRADES performance across the
distribution -- body size directly scales shadowing. A single global
detection threshold is therefore wrong for mixed-size targets: slim
targets (including small UAS) shadow less and need a lower
binarization fraction to appear at all, at the cost of more false
pixels, and their blobs must carry lower confidence. The
size-aware fractions below are STARTING POINTS to be re-tuned on
recorded data per deployment, NOT validated values.

DEMONSTRATION DATA HONESTY: no recorded link-shadow image dataset
exists in this repo (the bench fixtures are tracker replays, not
RTI scenes), so the demonstration tuning run below uses scenes
generated by this file's own forward-model harness
(make_harness_scenes) -- HARNESS-GENERATED, NOT FIELD DATA. The
tuning machinery itself is data-agnostic: point tune_kim_params at
recorded scenes (same dict format, provenance="field-recorded")
and the same code tunes on real data. Never present a
harness-tuned (alpha, gamma) as field-validated.
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

# ------------------------------------------------------- Kim tuning discipline
# (Kim et al., arXiv:2505.04085v2. See the module docstring for the
# honesty bounds: 6-node/15-link ~1-2 m bound UNCHANGED; size-aware
# thresholds; harness demo data is NOT field data. No ML/CNN here --
# Elastic Net is a regularized linear reconstruction, DBSCAN is a
# density clustering rule, both dependency-light and auditable.)

# Binarization fraction of the image maximum, per target size class.
# Slim targets shadow less, so they need a lower fraction to appear;
# that also admits more false pixels, so slim-target blobs carry
# lower confidence downstream. STARTING POINTS ONLY -- re-tune per
# deployment on recorded data (see tune_kim_params); do not quote
# these fractions as validated.
SIZE_BINARIZE_FRAC = {
    "large": 0.50,
    "medium": 0.40,
    "small": 0.30,
}

# Dart-side size vocabulary (the app's S/M/L) maps onto the Python
# size classes: "S" -> "small", "M" -> "medium", "L" -> "large".
# NOTE the quantities differ (see the spec cross-reference in
# docs/kim_lte_nr_v0250_spec.md §1): Dart scales a dip threshold
# by 0.7 / 1.0 / 1.3, Python takes a fraction 0.30 / 0.40 / 0.50 of
# the image peak -- same direction (larger target -> higher bar),
# different scales. Only the direction is shared, never the numbers.
SIZE_CLASS_ALIASES = {
    "s": "small", "small": "small",
    "m": "medium", "medium": "medium",
    "l": "large", "large": "large",
}


def normalize_size_class(size_class):
    """Normalize a size class to "small"/"medium"/"large".

    Accepts both vocabularies: Python "small"/"medium"/"large"
    and Dart "S"/"M"/"L" (any case). Anything else raises
    ValueError naming the accepted values -- never a bare
    KeyError from a dict lookup."""
    if not isinstance(size_class, str):
        raise ValueError(
            "size_class must be one of "
            f"{sorted(SIZE_BINARIZE_FRAC)} or one of S/M/L, "
            f"got {size_class!r}")
    norm = SIZE_CLASS_ALIASES.get(size_class.strip().lower())
    if norm is None:
        raise ValueError(
            "unknown size_class "
            f"{size_class!r}: accepted values are "
            f"{sorted(SIZE_BINARIZE_FRAC)} (or Dart aliases S/M/L)")
    return norm

KIM_DEFAULT_ALPHAS = [0.001, 0.01, 0.05, 0.1, 0.5]
KIM_DEFAULT_GAMMAS = [0.3, 0.6, 1.0, 1.5]


def build_link_pixel_weights(nodes, pixels, gamma):
    """Link-pixel weight matrix W (n_links x n_pixels) for a given
    path-thickness gamma (metres).

    nodes: [(x, y), ...] node positions; pixels: [(x, y), ...] pixel
    centres. For link (a, b) and pixel p, the excess path is
    |a-p| + |p-b| - |a-b| (0 on the link line, growing off it).
    Weight w = 1 / (1 + excess / gamma): gamma is the thickness
    scale -- small gamma makes thin, link-hugging ellipses; large
    gamma makes diffuse ones. Links are ordered pairs i < j, so a
    6-node deployment yields 15 links, matching Shepherd's sparse
    regime. Area normalization is deliberately NOT applied here:
    gamma tuning must see the raw thickness effect, and the
    area-normalized weighting already lives app-side (see
    docs/rti_imaging_weights_spec.md).
    """
    if gamma <= 0:
        raise ValueError("gamma must be positive")
    nodes = [(float(x), float(y)) for x, y in nodes]
    pixels = np.asarray(pixels, dtype=float)
    rows = []
    for i in range(len(nodes)):
        for j in range(i + 1, len(nodes)):
            ax, ay = nodes[i]
            bx, by = nodes[j]
            d = math.hypot(bx - ax, by - ay)
            excess = (np.hypot(pixels[:, 0] - ax, pixels[:, 1] - ay)
                      + np.hypot(pixels[:, 0] - bx, pixels[:, 1] - by)
                      - d)
            rows.append(1.0 / (1.0 + np.maximum(excess, 0.0) / gamma))
    return np.asarray(rows, dtype=float)


def elastic_net_reconstruct(W, y, alpha, l1_ratio=0.5):
    """Elastic Net (l1 + l2) reconstruction: solve y ~= W x for a
    non-negative disturbance image x. l1_ratio is held at 0.5 (the
    Elastic Net balance); alpha is the tuned sparsity/regularization
    strength. Returns the image vector (n_pixels,)."""
    from sklearn.linear_model import ElasticNet
    model = ElasticNet(alpha=float(alpha), l1_ratio=float(l1_ratio),
                       positive=True, max_iter=5000, tol=1e-4,
                       random_state=SEED)
    model.fit(W, np.asarray(y, dtype=float))
    return np.asarray(model.coef_, dtype=float)


def binarize_image(img, size_class="medium", frac=None):
    """Binarize a reconstructed image: pixels at or above
    frac * max(img) are True. frac defaults to the size-aware
    fraction for size_class (see SIZE_BINARIZE_FRAC and the
    size-caveat in the module docstring); size_class accepts
    "small"/"medium"/"large" and the Dart aliases S/M/L (see
    normalize_size_class). An explicit frac must satisfy
    0 < frac <= 1 -- frac <= 0 would make the whole grid True.
    An all-zero image binarizes to all-False -- no blob from
    nothing."""
    img = np.asarray(img, dtype=float)
    if frac is None:
        frac = SIZE_BINARIZE_FRAC[normalize_size_class(size_class)]
    else:
        try:
            frac = float(frac)
        except (TypeError, ValueError):
            raise ValueError("frac must be a number with 0 < frac <= 1")
        if not (0.0 < frac <= 1.0):
            raise ValueError(
                f"frac must satisfy 0 < frac <= 1, got {frac!r}")
    peak = float(np.max(img)) if img.size else 0.0
    if peak <= 0:
        return np.zeros(img.shape, dtype=bool)
    return img >= frac * peak


def dbscan_blobs(binary_img, grid_shape, pixel_xy, eps=1.5,
                 min_samples=3):
    """DBSCAN clustering on the binarized image -> blob list.

    binary_img: flat boolean array over the pixel grid; grid_shape:
    (ny, nx); pixel_xy: [(x, y), ...] in metres, same order as the
    flat image. eps is in PIXEL units (1.5 = 8-neighbourhood on the
    grid); min_samples counts neighbours including the point itself.
    Pure-numpy implementation (no sklearn DBSCAN dependency, so the
    extractor runs anywhere the rest of this file runs and its
    behaviour is fully auditable). Each blob: {centroid_xy (m),
    pixel_count, bbox_rows / bbox_cols (min/max pixel indices)}.
    No mean_value is returned (an earlier docstring promised one
    filled by the caller via `values`, but the function takes no
    values parameter -- a caller that wants one can average its
    own image over the blob's pixels). Isolated pixels below
    min_samples are noise, not blobs -- a lone hot pixel is never a
    detection on its own. binary_img and pixel_xy must each have
    exactly ny*nx entries, else ValueError -- a short list used to
    raise an opaque reshape/IndexError instead.
    """
    try:
        ny, nx = grid_shape
    except (TypeError, ValueError):
        raise ValueError(
            f"grid_shape must be (ny, nx) with positive ints, "
            f"got {grid_shape!r}")
    if not (isinstance(ny, (int, np.integer))
            and isinstance(nx, (int, np.integer)) and ny > 0 and nx > 0):
        raise ValueError(
            f"grid_shape must be (ny, nx) with positive ints, "
            f"got {grid_shape!r}")
    binary_img = np.asarray(binary_img, dtype=bool).ravel()
    if binary_img.size != ny * nx:
        raise ValueError(
            f"binary_img has {binary_img.size} entries but grid_shape "
            f"{grid_shape} needs {ny * nx}")
    if len(pixel_xy) != ny * nx:
        raise ValueError(
            f"pixel_xy has {len(pixel_xy)} entries but grid_shape "
            f"{grid_shape} needs {ny * nx}")
    pts = np.argwhere(binary_img.reshape(grid_shape)).astype(float)
    # argwhere gives (row, col); keep pixel-index coordinates for
    # neighbourhood, and map to metres only for the centroid.
    if len(pts) == 0:
        return []
    # Neighbour lists in pixel-index space (Euclidean on the grid).
    diff = pts[:, None, :] - pts[None, :, :]
    dist = np.sqrt((diff ** 2).sum(axis=2))
    neighbours = [set(np.flatnonzero(dist[i] <= eps).tolist())
                  for i in range(len(pts))]
    labels = [-1] * len(pts)  # -1 = unvisited/noise
    cluster = 0
    for i in range(len(pts)):
        if labels[i] != -1:
            continue
        if len(neighbours[i]) < min_samples:
            labels[i] = -2  # noise (stays noise unless reached)
            continue
        labels[i] = cluster
        stack = list(neighbours[i])
        while stack:
            j = stack.pop()
            if labels[j] == -2:
                labels[j] = cluster
            if labels[j] != -1:
                continue
            labels[j] = cluster
            if len(neighbours[j]) >= min_samples:
                stack.extend(neighbours[j])
        cluster += 1
    flat_idx = np.flatnonzero(binary_img)
    blobs = []
    for c in range(cluster):
        members = [k for k in range(len(pts)) if labels[k] == c]
        if not members:
            continue
        pix = flat_idx[members]
        coords = np.asarray([pixel_xy[int(p)] for p in pix], dtype=float)
        rows = pts[members][:, 0]
        cols = pts[members][:, 1]
        blobs.append({
            "centroid_xy": [float(coords[:, 0].mean()),
                            float(coords[:, 1].mean())],
            "pixel_count": int(len(members)),
            "bbox_rows": [int(rows.min()), int(rows.max())],
            "bbox_cols": [int(cols.min()), int(cols.max())],
        })
    return blobs


def score_blobs(blobs, truth_xy, blob_count_penalty=1.0):
    """Score a blob extraction against known target positions (m).

    score = -(mean nearest-blob centroid error + penalty *
    |n_blobs - n_truth|). Higher is better; a run with no blobs
    scores -(20 + penalty * n_truth): worse than any plausible
    centroid error on a ~10 m site (so a miss still loses to any
    hit), but bounded, so one missed scene cannot swamp the mean
    of a whole tuning grid the way an unbounded penalty would.
    Wrong blob counts are penalised because a second phantom blob
    is a false detection, not a bonus. The empty-scene case is
    the exception: no blobs AND no truth is a correct empty
    answer and scores 0.0 -- the old formula scored it -20,
    worse than one phantom blob (-1), which inverted the case
    the scorer exists to reward."""
    if not blobs and not truth_xy:
        return 0.0
    if not blobs:
        return -(20.0 + blob_count_penalty * len(truth_xy))
    if not truth_xy:
        return -float(len(blobs))
    errs = []
    for tx, ty in truth_xy:
        errs.append(min(math.hypot(b["centroid_xy"][0] - tx,
                                   b["centroid_xy"][1] - ty)
                        for b in blobs))
    return -(sum(errs) / len(errs)
             + blob_count_penalty * abs(len(blobs) - len(truth_xy)))


def tune_kim_params(scenes, alphas=KIM_DEFAULT_ALPHAS,
                    gammas=KIM_DEFAULT_GAMMAS, l1_ratio=0.5):
    """Tune (alpha, gamma) by optimization on RECORDED data.

    scenes: list of dicts, each with:
      nodes: [(x, y), ...], pixels: [(x, y), ...] (pixel centres),
      grid_shape: (ny, nx), y: link-disturbance vector,
      truth_xy: [[x, y], ...] known target positions (metres),
      size_class: "large"/"medium"/"small" (default "medium").
    Every (alpha, gamma) pair is tried (grid search -- the
    deterministic equivalent of Kim et al.'s Bayesian optimization;
    see the module docstring); W is rebuilt per gamma and cached
    across scenes that share nodes/pixels/gamma. Returns
    {"alpha", "gamma", "score", "per_scene_scores", "grid"} where
    grid lists every tried pair with its mean score, so the tuning
    surface itself is auditable -- a flat grid means the data cannot
    distinguish parameters, and that must be visible, not hidden
    behind a single "best" pair.
    """
    if not scenes:
        raise ValueError("tune_kim_params needs at least one scene")
    grid = []
    best = None
    w_cache = {}
    for gamma in gammas:
        for alpha in alphas:
            per_scene = []
            for sc in scenes:
                # Cache on content, not identity: scenes from one
                # deployment share nodes/pixels lists, but a copied
                # list must not silently reuse a stale matrix.
                ckey = (tuple(map(tuple, sc["nodes"])),
                        tuple(map(tuple, sc["pixels"])), float(gamma))
                if ckey not in w_cache:
                    w_cache[ckey] = build_link_pixel_weights(
                        sc["nodes"], sc["pixels"], gamma)
                W = w_cache[ckey]
                img = elastic_net_reconstruct(W, sc["y"], alpha,
                                              l1_ratio=l1_ratio)
                binary = binarize_image(
                    img, size_class=sc.get("size_class", "medium"))
                blobs = dbscan_blobs(binary, sc["grid_shape"],
                                     sc["pixels"])
                per_scene.append(score_blobs(blobs, sc["truth_xy"]))
            mean_score = float(sum(per_scene) / len(per_scene))
            grid.append({"alpha": float(alpha), "gamma": float(gamma),
                         "score": mean_score})
            if best is None or mean_score > best["score"]:
                best = {"alpha": float(alpha), "gamma": float(gamma),
                        "score": mean_score,
                        "per_scene_scores": list(per_scene)}
    best = dict(best)
    best["grid"] = grid
    return best


def log_tuned_values(path, deployment, alpha, gamma, score, n_scenes,
                     data_provenance, notes=""):
    """Append one JSONL record of tuned values for a deployment.

    data_provenance is REQUIRED and free-text by design -- but it
    must say what the data actually was (e.g. "field-recorded,
    site X, 2026-10-24" or "harness-generated, NOT field data").
    There is no default: a tuning record that does not say where
    its data came from is a record that will be misquoted later.
    Returns the record dict."""
    if not data_provenance:
        raise ValueError("data_provenance is required (see docstring)")
    record = {
        "deployment": deployment,
        "alpha": float(alpha),
        "gamma": float(gamma),
        "score": float(score),
        "n_scenes": int(n_scenes),
        "data_provenance": data_provenance,
        "tuned_at": datetime.now(timezone.utc).isoformat(),
        "notes": notes,
    }
    with open(path, "a") as f:
        f.write(json.dumps(record) + "\n")
    return record


def make_harness_scenes(n_scenes=12, seed=SEED, noise_std=0.05,
                        target_radius=0.5, strength=1.0):
    """HARNESS-GENERATED demonstration scenes -- NOT field data.

    A 6-node / 15-link deployment over a 10 x 8 m area, pixel grid
    20 x 16 (0.5 m pixels), one target per scene at a seeded random
    position. The link vector is the forward model itself
    (W(gamma=0.6) @ true-image * strength + Gaussian noise): this
    exercises the tuning machinery end to end (grid search finds a
    sensible (alpha, gamma), DBSCAN extracts one blob near truth),
    but it CANNOT validate field performance -- the forward model
    and the reconstruction share the same physics, so good harness
    scores are a machinery check, not an accuracy claim. The
    6-node/15-link ~1-2 m imaging bound stands unchanged.
    """
    rng = random.Random(seed)
    np_rng = np.random.default_rng(seed)
    nodes = [(0.0, 0.0), (5.0, 0.0), (10.0, 0.0),
             (0.0, 8.0), (5.0, 8.0), (10.0, 8.0)]
    nx, ny = 20, 16
    pixels = []
    for row in range(ny):
        for col in range(nx):
            pixels.append(((col + 0.5) * 10.0 / nx,
                           (row + 0.5) * 8.0 / ny))
    W_true = build_link_pixel_weights(nodes, pixels, 0.6)
    scenes = []
    for _ in range(n_scenes):
        tx = rng.uniform(1.5, 8.5)
        ty = rng.uniform(1.5, 6.5)
        true_img = np.array([
            1.0 if math.hypot(px - tx, py - ty) <= target_radius else 0.0
            for px, py in pixels])
        y = W_true @ true_img * strength
        y = y + np_rng.normal(0.0, noise_std, size=y.shape)
        y = np.maximum(y, 0.0)
        scenes.append({"nodes": nodes, "pixels": pixels,
                       "grid_shape": (ny, nx), "y": y.tolist(),
                       "truth_xy": [[tx, ty]],
                       "size_class": "medium"})
    return scenes


def demo_kim_tuning(log_path=None, deployment="harness-demo"):
    """Run the Kim tuning discipline on harness-generated scenes
    and print the tuned values. Demonstration ONLY -- see
    make_harness_scenes. When log_path is given, the tuned values
    are logged per deployment with provenance
    "harness-generated, NOT field data"."""
    scenes = make_harness_scenes()
    best = tune_kim_params(scenes)
    print(f"kim tuning demo: {len(scenes)} harness scenes "
          f"(NOT field data), 6 nodes / 15 links")
    print(f"  tuned alpha={best['alpha']} gamma={best['gamma']} "
          f"score={best['score']:.3f}")
    for g in best["grid"]:
        print(f"    alpha={g['alpha']:<6} gamma={g['gamma']:<4} "
              f"score={g['score']:.3f}")
    if log_path:
        rec = log_tuned_values(
            log_path, deployment, best["alpha"], best["gamma"],
            best["score"], len(scenes),
            "harness-generated, NOT field data",
            notes="Demonstration run of the Kim tuning discipline; "
                  "do not quote as field-validated.")
        print("  logged:", json.dumps(rec))
    return best


def load_recorded_scenes(path):
    """Load recorded tuning scenes from JSON: {"nodes": [...],
    "pixels": [...], "grid_shape": [ny, nx], "scenes": [{"y": [...],
    "truth_xy": [[x, y], ...], "size_class": "..."}]}. The file's
    own "provenance" field, if present, is returned alongside so
    the caller can pass it verbatim to log_tuned_values."""
    with open(path) as f:
        data = json.load(f)
    nodes, pixels = data["nodes"], data["pixels"]
    grid_shape = tuple(data["grid_shape"])
    scenes = []
    for s in data["scenes"]:
        scenes.append({"nodes": nodes, "pixels": pixels,
                       "grid_shape": grid_shape, "y": s["y"],
                       "truth_xy": s["truth_xy"],
                       "size_class": s.get("size_class", "medium")})
    return scenes, data.get("provenance", "")


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
    ap.add_argument("--kim-tune-demo", action="store_true",
                    help="run ONLY the Kim tuning demonstration on "
                         "harness-generated scenes (NOT field data) "
                         "and exit -- no MLP training, no model write; "
                         "takes precedence over --kim-tune when both "
                         "are passed")
    ap.add_argument("--kim-tune", default=None,
                    help="tune (alpha, gamma) on RECORDED scenes from "
                         "a JSON file (see load_recorded_scenes) and "
                         "exit -- no MLP training, no model write")
    ap.add_argument("--kim-deployment", default="unnamed-deployment",
                    help="deployment name for the Kim tuning log record")
    ap.add_argument("--kim-log", default=None,
                    help="JSONL path for the Kim per-deployment tuning "
                         "log (required with --kim-tune; optional with "
                         "--kim-tune-demo)")
    args = ap.parse_args(argv)

    # Precedence (documented, not silent): --kim-tune-demo wins over
    # --kim-tune when both are passed -- the demo runs and the
    # recorded-scenes path is skipped entirely.
    if args.kim_tune_demo:
        demo_kim_tuning(log_path=args.kim_log,
                        deployment=args.kim_deployment)
        return
    if args.kim_tune:
        scenes, provenance = load_recorded_scenes(args.kim_tune)
        if not args.kim_log:
            raise SystemExit("--kim-tune needs --kim-log (tuned values "
                             "must be logged per deployment)")
        if not provenance:
            raise SystemExit("recorded scenes file has no "
                             "'provenance' field -- refusing to tune "
                             "without knowing what the data was")
        best = tune_kim_params(scenes)
        print(f"kim tuning: {len(scenes)} recorded scenes, "
              f"alpha={best['alpha']} gamma={best['gamma']} "
              f"score={best['score']:.3f}")
        log_tuned_values(args.kim_log, args.kim_deployment,
                         best["alpha"], best["gamma"], best["score"],
                         len(scenes), provenance)
        return

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
