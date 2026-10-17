# Shepherd Mesh Mode — automatic tripwire/mesh switching with embedded-AI arbitration

Status: SPEC (accepted 2026-10-16). Not yet implemented.
Owner: Draco. Implements: his "automatic function for three or more nodes" decision.

## 1. Goal

Shepherd detects which regime it is in and switches itself, with no user
action:

- **TRIPWIRE mode** (1–2 positioned nodes): today's behavior — per-link
  adaptive baselines, DIP alerts, disturbance classification.
- **MESH mode** (3+ positioned nodes): multi-link fusion — cross-link
  correlation, ego-motion compensation, tomographic position estimates,
  confidence that scales with link count.

The embedded tiny AI manages the switching and the fusion scoring.
That is its job: it is a multi-node fusion specialist, not a chatbot,
not an agent. (Conversational LLM stays out — Draco's call, unchanged.)

## 2. What already exists (integration points — real files)

- `lib/services/tripwire.dart` — `Tripwire.process()` / `drainEvents()`.
  Deterministic per-link MAD baselines. Stays the detector in both modes.
- `lib/services/tiny_ml.dart` — `TinyMlp`: the one shared pure-Dart
  inference kernel (standardize → relu → softmax/logistic). New models
  MUST run on this kernel. No native plugins.
- `lib/services/ai_classifier.dart` — `DisturbanceClassifier`
  (10 features → PASSING / LINGERING / INTERFERENCE / FAULT), trained on
  synthetic data via `tools/train_disturbance_clf.py`, shipped as
  `assets/models/disturbance_clf.json`.
- `lib/services/track_stitcher.dart` — `TrackStitcher`: binary MLP
  scoring cross-driver handoffs ("same mover?"), `assets/models/track_stitcher.json`.
- `lib/services/tracker.dart`, `lib/services/gps_positioning.dart`,
  `lib/state/app_state.dart` — deterministic tracker, GPS projection,
  central polling loop where the mode controller will live.
- `tools/train_*.py` — the training pipeline pattern: synthetic
  scenarios → sklearn MLP → JSON export → golden tests.

## 3. Honest-scope rules (non-negotiable, carried over from the existing AI)

1. **Detection stays deterministic.** The tripwire finds things. Models
   classify, score, and arbitrate — they never suppress an alert and
   never delete a deterministic detection.
2. **Hard physical gates beat the model.** Fewer than 3 positioned nodes
   is not a mesh, no matter what any model says. The AI never overrides
   a hard gate; it only manages the ambiguous cases between them.
3. **Synthetic-trained = heuristic.** All models train on synthetic
   scenarios, so every AI verdict surfaces as an estimate with
   confidence, never as fact. Real-world walk/drive validation is
   required before trusting the confidence numbers (Phase 3).
4. **Defensive only.** Mesh mode changes sensing and fusion. Nothing
   here touches transmit, jamming, or any EA path.

## 4. Mode definitions

### TRIPWIRE (1–2 positioned nodes)
Unchanged current behavior: per-link rolling baselines, DIP alerts,
disturbance classification on closed events. Works stationary or moving
(rate-of-change detection when GPS shows motion — see §7).

### MESH (3+ positioned nodes)
Everything in TRIPWIRE, plus:

- **Cross-link correlation**: a disturbance is scored by how many links
  see it and how their residuals correlate. Localized + correlated
  across adjacent links = contact. Common-mode across one node's links
  = that node's own motion.
- **Ego-motion compensation** (§7): predicted link level from GPS range
  vs measured; the residual is the detection signal.
- **Position estimates**: disturbed-link centroid / tomographic solve
  (the deterministic tracker already does the geometry; mesh mode feeds
  it correlated multi-link events instead of single-link dips).
- **Confidence scales with the mesh**: 3 nodes = basic fusion,
  4–5 = standard, 6 (full fire team, 15 links) = full. The UI shows mesh
  health, not just a mode flag — same pattern as the v0.14.4
  ok/degraded/blind dashboard banner.

## 5. The switching architecture — what the AI actually manages

Two layers. The division is deliberate: cheap certain things stay
deterministic; the model earns its keep on the fuzzy boundary.

### Layer 1 — deterministic hard gates (no AI, always first)

Evaluated every polling tick in `AppState`:

- `positionedNodes < 3` → TRIPWIRE. Always. (3 nodes / 3 links is the
  minimum mesh; 2 nodes is one link, no correlation possible.)
- Link-freshness watchdog: links silent past the freshness horizon
  don't count toward the node/link totals.
- GPS quality gate for ego-motion compensation: no usable fix →
  compensation degrades to IMU/rate-based, mesh confidence capped,
  banner shows DEGRADED (never silently).

### Layer 2 — the Mesh Arbitrator (new tiny model)

New model: `assets/models/mesh_arbitrator.json`, same `TinyMlp`
kernel, same `tools/train_mesh_arbitrator.py` pipeline.

**Job 1 — engage / hold / disengage.** Inputs are mesh-health features
over a rolling ~30 s window: positioned-node count and its stability,
link flap rate (links winking from body shadowing at 2.4 GHz is
*normal*, not failure), cross-link residual correlation, GPS quality,
team speed. Output: P(mesh_reliable). Hysteresis: engage above 0.75,
disengage below 0.40, hold between. This is the call a fixed threshold
gets wrong — e.g. 3 nodes with heavy body-shadow flapping: the model
learns "flapping but correlated = ride it out in MESH" vs "nodes
actually gone = drop to TRIPWIRE."

**Job 2 — intruder vs ego-motion.** For ambiguous disturbance patterns
in MESH mode: features are per-link residual magnitudes, their
cross-correlation matrix summary, and GPS velocity. Output:
P(intruder) vs P(egomotion). Shown as an estimate with confidence on
the contact; never suppresses the underlying deterministic detection.

**Job 3 — fusion confidence.** Scales the mesh-health/confidence shown
in the UI from the same feature set (3-node basic → 6-node full).

The arbitrator runs at most once per second (not per sample) — it is
cheap, but there is no reason to burn battery re-deciding modes at
link rate.

### Why this division

You don't need a neural net to know 2 nodes isn't a mesh — that's a
gate. You *do* want a learned model for "is this flapping 3-node mesh
still trustworthy" and "is this pattern us moving or something
crossing," because those are statistical judgments over noisy,
correlated signals. That is the whole point of the embedded AI for
multi-node fusion.

## 6. Graceful degradation (no flapping, no silent blindness)

- Mode changes are hysteresis-guarded (§5) AND time-guarded: minimum
  10 s in a mode before switching back, so a single bad second can't
  oscillate the UI.
- Every mode change is logged with the reason (gate or arbitrator
  probabilities) — auditable in the event log.
- If the arbitrator model asset is missing/corrupt at load, mesh mode
  still works on Layer-1 gates alone with confidence capped and a
  banner note. The app never hard-requires the model file.
- GPS-denied: ego-motion compensation falls back to IMU + link-rate
  heuristics, mesh confidence capped at "standard," banner DEGRADED
  with the reason listed (same v0.14.4 pattern: the app only vouches
  CLEAR when it can).

## 7. On-the-move detection (the reason this exists)

Fire-team reality: 4–6 nodes, dismounted, moving. Stationary-baseline
thinking does not survive motion, so:

- **Subtract motion, don't chase it.** Each tick: predicted link level
  from GPS inter-node range via the link budget vs measured level.
  Residual = detection signal. Works while the absolute level swings
  with range and antenna orientation.
- **Speed-adaptive detector.** GPS velocity picks the regime:
  stationary → absolute baseline against quiet history (today's
  tripwire); moving → residual + rate-of-change. Automatic, no setting.
- **Body-worn realities, designed in — not filtered out:** 2.4 GHz
  body shadowing makes links wink as people turn (expected, not a
  fault); walking gait puts a rhythmic wobble on every link
  (filterable — it's periodic). The synthetic training scenarios MUST
  include both, or the arbitrator will learn a lab-only world.
- Two nodes on the move is the worst geometry (one link, no
  cross-check) — mesh mode's value starts at 3 and compounds to 6.

## 8. Training plan (follows the existing pipeline exactly)

`tools/train_mesh_arbitrator.py`:

1. **Synthetic scenario generator**: N-node meshes (N = 2..6) with
   scripted ego-motion (stand / walk with gait modulation / vehicle),
   scripted body-shadow dropouts, scripted intruder crossings
   (passing / lingering), GPS noise + GPS-denied segments,
   interference bursts.
2. Feature extraction mirroring the Dart `extractMeshFeatures()` —
   feature order MUST match, same as the two existing models.
3. sklearn MLPClassifier (small: e.g. 12 → 16 → 8 → outputs),
   holdout accuracy recorded into the JSON.
4. Export `assets/models/mesh_arbitrator.json`; add
   `test/mesh_arbitrator_golden.json` verifying the Dart kernel
   against the Python model numerically (same pattern as
   `ai_golden.json` / `stitcher_golden.json`).

## 9. Phased build

- **Phase 1 — deterministic mesh mode.** Layer-1 gates, cross-link
  correlation, ego-motion compensation, speed-adaptive detector,
  UI mesh-health banner. No new model; arbitrator hooks stubbed
  (confidence capped, banner notes "AI arbitration pending").
- **Phase 2 — arbitrator model.** Trainer, JSON asset, golden tests,
  integration into `AppState` at 1 Hz. Full §5 behavior.
- **Phase 3 — field validation.** Walk and drive tests with known
  crossings, GPS-denied drill. Tunes thresholds/hysteresis against
  reality; only then do the confidence numbers get trusted.

## 10. What this does NOT do

- Does not make 2-node mobile geometry good (one link, no
  cross-check) — honest limit, stated in-app.
- Does not eliminate body shadowing — rides it out as expected
  behavior.
- Does not identify anything — blobs, bearings, estimates, confidence.
  Never silhouettes, never "confirmed."
- Synthetic training is a starting point, not proof. Phase 3 is part
  of the spec, not optional polish.

## 11. Hermes one-shot implementation prompt

> In ~/workspace/rf_sentry (Shepherd repo), implement Phase 1 of
> docs/mesh_mode_spec.md: the deterministic mesh-mode layer. Add a
> MeshModeController evaluated in AppState's polling loop implementing
> the Layer-1 hard gates (§5), cross-link residual correlation, GPS
> ego-motion compensation with speed-adaptive detector selection (§7),
> hysteresis + 10 s minimum-mode-time (§6), mesh-health banner states
> following the v0.14.4 ok/degraded/blind pattern, and stubbed
> arbitrator hooks (confidence capped, banner notes "AI arbitration
> pending"). New models MUST run on the existing TinyMlp kernel
> (lib/services/tiny_ml.dart) — no native plugins. Then: flutter
> analyze clean, add unit tests for the gates/hysteresis/degradation,
> run the full test suite green, commit on a feature branch
> (mesh-mode-phase1), and report the commit hash. Do not touch any
> transmit/EA code paths — sensing and fusion only.
