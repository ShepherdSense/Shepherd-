# TinyML Boundary — what runs on-node (ESP32) vs on-phone

*2026-10-23, for Shepherd v0.24.0. Source research:
`~/memory/topics/shepherd_research/lane6_tinyml.md` (2026-10-23 section)
and `~/memory/topics/shepherd_research/BRIEF.md` (item 9 + lane-6
honorable mention). This doc records the MEASURED numbers behind the
boundary; it does not change any code.*

## The measured boundary

| Quantity | Measured value | Source |
|---|---|---|
| CSI-HAR **typing** on ESP32-S3 (5-activity, LSTM-embedded DenseNet, full INT8, TFLite Micro, ESP32-S3 N16R8 @ 240 MHz) | **232 ms** latency, **127 kB** memory, **external PSRAM required** ("having an external PSRAM is a must") | Armenta-Garcia et al., *Sensors* 2025, 25, 6220 — read in full |
| Same model, fp32 / full-subcarrier variant | 97.33% accuracy but **10,904 ms** latency — unusable at tripwire cadence; the 232 ms point cost ~5 accuracy points via single-subcarrier selection | same |
| INT8 quantization cost on the recurrent component | 97.33% → 93.32% (~4 points) — independently corroborates Saha & Samanta's LSTM/INT8 finding | same; lane-6 §2a |
| **Shepherd on-node inference budget** | **< 50 ms** per inference | Shepherd node budget (BRIEF lane-6 mention) |
| CSI collection-rate ceiling on stock ESP32 | **> 200 packets/s trips the task watchdog** (system overload); at 200 pps the full CSI estimation + processing pipeline must finish **within 5 ms/sample**; plan on **~180 pps sustained** | Armenta-Garcia et al. §7.1; BRIEF lane-6 mention |

Typing on ESP32-S3 therefore costs **~4.6× the entire on-node latency
budget** (232 ms vs <50 ms), needs more memory than the node's
envelope, and requires PSRAM the stock node does not guarantee. The
paper's own accuracy number (92.43%) is also demo-adjacent by our
honest-reporting standard (22 volunteers, 1,647 samples, single room,
per-activity split — no leave-one-volunteer-out, no cross-environment
test), so even the accuracy side of the trade is not field evidence.

## Conclusion — the boundary (standing constraint)

- **On-phone (Dart `TinyMlp`): all typing.** The 4-class disturbance
  classifier (`disturbance_clf`: PASSING / LINGERING / INTERFERENCE /
  FAULT, `lib/services/ai_classifier.dart`) and the track stitcher's
  same-mover scoring stay on the phone. A phone has orders of magnitude
  more RAM/CPU than an ESP32, and pure-Dart MLP inference on a
  10-feature vector is trivially cheap at this tier.
- **On-node (ESP32): detection / tripwire only.** Deterministic
  per-link MAD baselines, freshness-aware fusion, and at most an
  ultra-light learned anomaly score inside the demonstrated envelope
  (<100 KB flash / <50 KB RAM / <50 ms — cf. Antonini et al.'s
  on-device isolation forest, ~80–84 KB RAM, <16–20 ms, lane-6 §2a).
  The node emits disturbance descriptors and scores; it never emits
  final classifications.
- Deterministic gates stay **upstream** of every model, and **the AI
  never suppresses alerts** — unchanged by anything in this doc.
- This split is also the proven pattern in the literature: the closest
  published ESP32-CSI analog ran its classifier a tier up (ESP32
  senses, Raspberry Pi 4 classifies, 20 ms end-to-end), not on the MCU.

Revisit this boundary only with measured numbers on the actual node
hardware, reported MLPerf-style (accuracy + latency + memory together,
never accuracy alone).

## Model-card note

The standing standard is the **four-item model card** (lane-6
Recommendation 3): every ML claim carries (a) training domain,
(b) test domain + whether it matches deployment, (c) quantization
delta on the target hardware, (d) latency + RAM/flash on the named
target device. For `disturbance_clf` today that card reads:

- (a) Training domain: **synthetic** (v0.24.0 trajectory-diverse
  corpus, seed 7 — `tools/train_disturbance_clf.py`).
- (b) Test domain: **synthetic holdout + synthetic link-dropout bench
  only** (`docs/link_dropout_bench.md`). Deployment match: **no** —
  unvalidated on real field data. **Synthetic accuracy does NOT
  establish field accuracy.**
- (c) Quantization delta: none — the model runs float in Dart; no INT8
  build exists.
- (d) Latency/memory: phone-tier Dart inference on a 10-feature vector
  (10 → 24 → 12 → 4); no on-node deployment is attempted or claimed.

**Proposed 5th item — referenced, NOT adopted.** The 2026-10-20 lane-6
sweep (Gopalakrishnan & Hailes, arXiv:2511.20456, read in full)
proposed adding a fifth model-card item: *clean accuracy vs
constrained-perturbation (physics-guided) robust accuracy*, on the
grounds that only the constrained number reflects a physically
realizable attack. As of this writing that proposal is **unanswered
and not adopted**; the four-item card above remains the standard. It is
recorded here so the proposal is not lost, not so it can be cited as
policy.

*Tree check (2026-10-23): this repo has no separate model-card
standard document (searched `docs/`, `README.md`); the card above
lives here and in the research lane doc. If a model-card standard doc
is created later, it should point at the boundary numbers in this file
rather than restating them.*
