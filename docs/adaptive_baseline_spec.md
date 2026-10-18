# Adaptive Baseline Calibration — Spec

**Status:** implemented in v0.17.0; field validation pending. **RX-only, defensive-only.** Everything
in this spec listens, measures, and adapts reference levels; nothing
transmits, jams, deauths, spoofs, or probes. There is no transmit path
anywhere in this feature.

**Honesty contract (load-bearing):** this spec calibrates the
*reference* the detector compares against — it never claims a target
is present, never claims identity, and never improves sensing range.
Any accuracy numbers cited from the literature below are CLAIMED in
their original regimes (indoor/through-wall, stationary humans,
30-node meshes) and are NOT transferred to Shepherd's regime
(6 nodes, dismounted, on the move, Group 2–3 UAS airborne targets).
The value imported is the *method*, not the numbers.

## Goal

Give the on-the-move fire-team mesh a baseline that survives drift.
The existing `TripwireDetector` calibrates during a vacant window and
holds the baseline during continuous disturbance — but a dismounted
team moves: node positions shift, body shadowing changes, temperature
and vegetation drift the channel. A stale baseline either eats the
intruder (baseline absorbs the disturbance) or raises the false-alarm
rate (thresholds anchored to a geometry that no longer exists). This
spec ports two mechanisms from the full-read literature:

1. **ARTI** — an online reference-RSS estimator with an anti-blend
   rule, so baselines track slow drift during ops *without* the target
   contaminating the links it perturbs.
2. **"Dial it in"** — a deploy-time guided routine that raises
   per-link fade level by operator repositioning, the dismounted-team
   port of a servo-calibration result.

Plus a between-sortie batch refit for post-mission analysis.

## Background

### ARTI — Kaltiokallio, Jäntti & Patwari, IEEE TVT 2017 (READ IN FULL)

**CONFIRMED** (full read): ARTI is an online estimator that maintains,
per link *per channel*, a reference RSS `mu` and a *signed* change
magnitude `phi` with weight `w = sgn(phi)`, updated every TDMA cycle.
Two hard gates decide whether an update happens at all:

- **Residual trust:** `||z − Hx̂|| < T_r = 1.0 m` — the track estimate
  must be consistent with the measurement before the measurement is
  allowed to teach the reference.
- **Motion gate:** target speed `> 0.2 m/s` — a stationary target
  freezes all updates.

Updates apply **only** to links geometrically *far* from the estimated
target (excess-path-length delta `> 2λ`): `mu` moves by EWMA
(`alpha = 0.90`); links *near* the target update `phi` only. This is
the **anti-blend mechanism** — the target never updates the reference
of the links it perturbs, which is exactly what stops a plain EWMA
from absorbing a stationary person into the background. `phi_0` is
initialized tiny and slightly negative (`−1e-3`) so the sign flips
fast; **CONFIRMED:** ~33–45% of links start wrongly signed and
self-correct within one target pass. A batch refit (Nelder–Mead on
smoothed own tracks, **no labels needed**) matches the ground-truth
oracle.

**CLAIMED** (their regime, not ours): ~2× median accuracy online,
~3× with smoothing + batch; through-wall 67.79 cm → 31.63 cm →
19.03 cm. Cite as paper claims only.

**CONFIRMED gaps (limits we inherit):**

- Single person only; multi-target behavior untested.
- **Stationary targets freeze the estimator** — no `mu`/`phi` updates
  at all while the motion gate is closed.
- No-calibration startup is supported (first sample becomes `mu`;
  converges once the subject moves), but there is no divergence
  safeguard if the estimator goes wrong.
- Nodes are static; no mobility handling whatsoever. **Our nodes
  move — this is the gap this spec closes.**

### "Dial it in" — Bocca, Luong, Patwari, Schmid, IEEE SECON 2014, arXiv:1312.5480 (READ IN FULL)

**CONFIRMED** (full read): servo-rotated RF nodes; the mechanism is
*sub-wavelength position change making small-scale fading more
constructive*. Both of the paper's calibration procedures maximize
**network-wide mean static RSS**, which raises per-link fade level
`F_l` (static RSS minus the path-loss prediction). Procedure: greedy
coordinate ascent, 3–4 sweeps to converge, ~10 s per position per
node; requires an empty room; indoor only.

**CLAIMED:** 32% mean localization-error reduction — **in the paper's
regime: indoor, stationary-human, rich-multipath.** NOT transferable
to open-field airborne detection; cite with that caveat, always.

**Shepherd port constraint:** servos are dead on arrival for a
dismounted team. The mechanism (raise `F_l` by sub-wavelength
repositioning) survives; the actuator becomes the operator's hand.

## Proposed design

Three pieces: an always-on online updater (ARTI), a deploy-time guided
routine ("Dial it in" port), and an offline batch refit.

### A. ARTI online updater (always-on during ops)

Per virtual link `l`, per band/sub-band `c`, per RSS-change direction
`δ ∈ {+, −}`, maintain reference `mu_{c,l}` and signed magnitude
`phi_{c,l}` with weight `w = sgn(phi)`. ("Virtual link" = one
physical link × one band/sub-band, per the SDR-bridge convention:
each band becomes a virtual link.)

**Per-update cycle (on each new link sample batch):**

1. Compute the current track estimate `x̂` (position + velocity) from
   the existing tracker (`lib/services/tracker.dart`).
2. **Residual gate:** `||z − Hx̂|| < T_r`. Shepherd adaptation:
   `T_r` is set in *disturbance units*, not meters — the residual is
   between observed link disturbance and the track-predicted
   disturbance. Default: residual within 2× the link's MAD threshold
   (see existing MAD per-link thresholds in `tripwire.dart`).
3. **Motion gate:** estimated speed `> 0.2 m/s` (paper value kept;
   tune against Group 2–3 UAS ground speeds in field test — a slow
   loitering orbit may sit near this boundary; document the tuning).
4. **Far/near split:** recompute excess-path-length geometry in **3D**
   from live node fixes (GPS, `lib/services/gps_positioning.dart`)
   and the track position — **not** the paper's 2D node-height plane.
   Use the **actual wavelength of the link's band**
   (`λ = c/f`: ~0.125 m @ 2.4 GHz, ~0.33 m @ 915 MHz, ~0.69 m @
   433 MHz) — **do NOT copy the paper's `λ_0 = 0.05 m`**; it is a
   2.4 GHz-geometry fit constant, meaningless at our bands and
   altitudes.
5. **Far links** (excess-path delta `> 2λ`): `mu ← EWMA(mu, sample,
   alpha=0.90)`.
6. **Near links**: update `phi` only (the signed disturbance magnitude
   feeding the imaging weights); `mu` is untouched — the anti-blend
   rule.
7. Initialize `phi_0 = −1e-3` per the paper; expect ~a third of links
   to start wrongly signed and self-correct within one pass — this is
   normal, log it, don't "fix" it.

**Divergence safeguard (the paper has none; we need one):** cap
`|mu − mu_calib|` per link-channel (default 6 dB from the last
deploy-time calibration value); exceeding the cap marks the link
`suspect` in `health.dart` and freezes its updates until the next
vacant window. A runaway estimator is worse than a stale one.

**Mobility handling (the paper has none; our core gap):** node fixes
arrive continuously; when any node's reported position moves more
than 1 m since the last geometry recompute, the excess-path
deltas for all its links are recomputed before the far/near split.
Stale geometry with a moving mesh silently inverts the anti-blend
rule (near links treated as far, target absorbed into `mu`) — this
recompute is the single most important adaptation.

### B. Deploy-time guided fade routine ("Dial it in" port, operator-driven)

Runs after emplacement, before ops — the dismounted replacement for
servos.

1. Operator taps **Calibrate** (Settings → Mesh, or the dashboard
   banner when the mesh is newly formed). App requires a **vacant
   30–60 s** where possible: no tracks, no operator movement near
   nodes. If the tactical situation doesn't allow it, the routine
   runs in degraded mode on whatever quiet it gets, and says so.
2. App collects static RSS per link-channel and fits a least-squares
   path-loss model `P(d)` over the live node geometry, then shows
   **per-link fade level `F_l = r̄ − P(d)`** as a simple ranked list:
   worst links first, owning node named ("Node RAPTOR-2 owns 4 of the
   5 worst links").
3. Prompt, double-click-simple: *"Nudge or rotate RAPTOR-2 a few
   inches and tap Re-measure."* Re-measure (~10 s), re-fit, re-rank.
   Repeat until fade levels stop improving (no link improves > 1 dB
   across two consecutive rounds) or the operator taps Done.
4. The final per-link-channel `F_l` values become the calibration
   anchor `mu_calib` for the ARTI divergence safeguard and are logged
   as first-class telemetry (see Schemas).

Design note: the existing `TripwireDetector` already computes fade
level (median of link medians, anti-fade vs deep-fade split,
`fadeGate = 3.0`). The routine reuses that computation but runs it
per link-channel during the vacant window instead of over rolling
history.

### C. Between-sortie batch refit (offline, post-mission)

Nelder–Mead refit of `mu`/`phi` over the sortie's smoothed own
tracks — **no labels needed**, per the paper. Runs from recorded
telemetry (`lib/services/recorder.dart`) after the sortie, never
live. Purpose: tighten the reference for the *next* sortie at the
same site and give post-mission analysis a converged baseline to
tie misses to. The paper's CLAIMED ~3× number lives here; we make no
live-accuracy claim for it.

## When calibration runs

| Phase | What | Operator action |
|---|---|---|
| Emplacement | Guided fade routine (B), vacant 30–60 s where possible | Tap Calibrate, nudge worst node, tap Re-measure until it plateaus, Done |
| Ops | ARTI online updater (A), always-on | None — it runs silently; divergence-suspect links surface in health banner |
| Post-sortie | Batch refit (C) on recorded telemetry | None (runs on export) or one tap |

ARTI and the existing vacant-window calibration are not either/or:
the deploy-time routine sets `mu_calib`; ARTI tracks drift from
there; the existing rolling-median baseline in `tripwire.dart`
continues to feed the tripwire thresholds directly (ARTI's `mu`
does not replace the tripwire's baseline — it is the *calibration
layer beneath it*, see Integration).

## What the operator does (the whole UX)

1. Emplace nodes. 2. Tap **Calibrate**. 3. Stand clear 30–60 s.
4. Read the ranked worst-link list. 5. Nudge the named node inches,
   tap **Re-measure**. 6. Repeat until the app says "fade levels
   stable" or tap Done. Total: a few minutes, no numbers to
   interpret, no RF knowledge required.

## What gets logged (first-class telemetry)

- **Calibration record:** start/end time, vacant-window quality
  (track-free seconds), per-link-channel `F_l`, path-loss fit
  parameters, rounds of nudge/re-measure, final `mu_calib`.
- **ARTI runtime stats** (1/min aggregates): fraction of updates
  blocked by each gate (residual / motion / near-field), per-link
  `|mu − mu_calib|`, count of `suspect` links, geometry-recompute
  events (node moved > 1 m).
- **Baseline-hold events** from the existing tripwire (already
  logged) now also carry the ARTI `mu` at hold start/end, so a
  post-mission analyst can see whether the reference moved under a
  long disturbance.

All of it through the existing recorder path so it lands in the
same sortie file as tracks and health.

## Integration points (actual files)

- **`lib/services/tripwire.dart`** — `TripwireDetector`
  (rolling-median baseline, `baselineWindow=120`, `minBaseline=10`,
  baseline-hold during continuous disturbance, fade-signed deviation
  = `baseline − snr` on anti-fade links, `snr − baseline` on
  deep-fade links, MAD per-link thresholds, `fadeGate = 3.0`).
  ARTI's `mu`/`phi` live in a new `AdaptiveBaseline` service *next
  to* the detector, not inside it: the detector keeps its proven
  baseline logic; the adaptive layer feeds it (a) the
  per-link-channel `mu_calib` anchors, (b) drift-compensated `mu`
  for the fade-level computation, and (c) `phi` sign for the
  fade-signed deviation. Detection stays deterministic; ARTI never
  suppresses an alert.
- **`lib/state/app_state.dart`** — calibration state machine
  (idle / calibrating / stable / degraded), worst-link ranking for
  the guided routine, surfacing `suspect`-link counts.
- **`lib/services/health.dart`** — node health scoring consumes
  per-link fade levels and ARTI divergence flags: a node owning
  persistently deep-fade or `suspect` links degrades honestly
  instead of silently feeding bad geometry to the tracker.
- **`~/workspace/shepherd_field_kit/esp32/shepherd_node/shepherd_node.ino`**
  — beacons on UDP 49160 already carry node identity/position;
  calibration mode needs one addition: a `calib` flag in the beacon
  so the app knows which nodes are participating in the vacant
  window (a node mid-reboot must not contaminate the fit).
- **`lib/services/node_udp_hub.dart`** — parses the `calib` beacon
  flag; routes per-link-channel static RSS into the calibration
  accumulator during the vacant window.
- **`lib/services/recorder.dart`** — persists calibration records
  and ARTI runtime stats into the sortie file.
- **`lib/services/tracker.dart`** — supplies `x̂` (position +
  velocity) for the residual and motion gates; consumes nothing new
  (ARTI reads the track, never steers it).

## Honest-scope limits

- **Regime transfer:** every accuracy number in this spec (ARTI
  ~2×/3×, "Dial it in" 32%) is CLAIMED in 30-node, indoor or
  through-wall, stationary-human regimes. Shepherd's regime — 6
  nodes / 15 links, dismounted, moving, open field, airborne
  Group 2–3 UAS — is outside all of it. The method ports; the
  numbers do not. Field validation must re-measure from zero.
- **Single-target heritage:** ARTI is CONFIRMED single-person only.
  Multi-target far/near splits (two tracks, one link near both) are
  unspecified — first implementation treats a link near *any*
  track as near, which is conservative (more frozen `mu`, less
  drift tracking). Document the choice.
- **Through-wall numbers** (67.79 → 31.63 → 19.03 cm) are
  building-penetration results; irrelevant to open-field UAS
  except as evidence the anti-blend mechanism works.
- **"Dial it in" port:** the paper's 32% is indoor rich-multipath.
  Open-field sub-wavelength repositioning may help less (fewer
  multipath components to make constructive) — the routine is
  still worth running because deep-fade links are where misses
  hide, but expect smaller gains. Measure, don't assume.
- **No identity, no imagery:** calibration changes what counts as
  "disturbed". Output remains blobs/trails/estimates.

## The loitering-target caveat (documented, not hand-waved)

ARTI's motion gate **freezes all `mu`/`phi` updates when the track
is stationary** (speed ≤ 0.2 m/s). For Shepherd this is protective:
a loitering Group 2–3 UAS — holding overhead, the hardest profile
for a tripwire — **cannot blend into the baseline**, because the
estimator refuses to learn while the target is still. The existing
baseline-hold during continuous disturbance already leans this way;
ARTI makes it principled.

The design tension, stated plainly: while updates are frozen, the
baseline also **cannot recalibrate** — slow environmental drift
(temperature, vegetation, a node settling in mud) accumulates
uncompensated for as long as the loiter persists. Two mitigations,
neither a fix:

1. The divergence safeguard still watches `|mu − mu_calib|`; if
   drift pushes a frozen link past the cap it is marked `suspect`
   rather than silently trusted.
2. The residual gate keeps checking track-vs-measurement
   consistency, so a drifting baseline that starts disagreeing with
   the track surfaces as inconsistency, not as confidence.

If the loiter ends (target moves or leaves), the motion gate reopens
and ARTI resumes — the first post-loiter updates should be treated
as suspect-adjacent in the log, because the reference may have
drifted under the frozen window. A loiter longer than the
divergence cap's drift budget is a recalibration event: re-run the
vacant-window routine when the air is clear.

## Test / validation plan

All tests run against recorded or simulated telemetry first; field
tests re-measure from zero (no paper numbers as pass criteria).

1. **Vacant-window convergence.** 60 s of quiet field data, run the
   calibration fit. **Pass:** `|mu − vacant-window mean| < 1 dB` on
   ≥ 90% of link-channels; path-loss fit residual within 3 dB RMS.
2. **Anti-blend (simulated crossing).** Replay a simulated track
   crossing with injected slow baseline drift (0.5 dB/min).
   **Pass:** near-link `mu` (excess-path delta < 2λ) drifts
   < 0.5 dB during the pass while far-link `mu` tracks the injected
   drift within 0.3 dB — the target does not contaminate its own
   reference.
3. **phi sign self-correction.** Simulation, `phi_0 = −1e-3`.
   **Pass:** ≥ 90% of links converge to the correct sign within one
   simulated pass, matching the paper's CONFIRMED behavior.
4. **Loiter freeze.** Simulated stationary target, 5 min, with
   injected drift. **Pass:** zero `mu`/`phi` updates while the
   motion gate is closed; alerts persist for the full 5 min; the
   baseline does not absorb the disturbance (post-loiter `mu`
   within 0.5 dB of pre-loiter `mu`).
5. **Divergence safeguard.** Inject 10 dB step drift on one link.
   **Pass:** link marked `suspect` in health within 60 s of crossing
   the 6 dB cap; its updates frozen; no alert suppression on
   neighboring links.
6. **Guided routine UX (synthetic).** Scripted link data with one
   deliberately deep-fade node. **Pass:** routine names the right
   node, completes in ≤ 4 nudge rounds, log contains before/after
   per-link-channel fade levels.
7. **Batch refit (recorded sortie).** Run Nelder–Mead on smoothed
   own tracks, no labels. **Pass:** cost decreases monotonically to
   convergence; runs offline in < 5 min on a phone-class CPU;
   refit `mu` within 2 dB of the next sortie's vacant-window fit
   (validates it as a next-sortie prior, not as a live claim).
8. **Mobility recompute.** Simulated node moving 3 m mid-track.
   **Pass:** geometry recompute triggers (logged), far/near split
   follows the new geometry; without the recompute the same
   scenario must show near-link `mu` contamination (negative
   control proving the recompute matters).

## Telemetry schemas

Calibration record (via `recorder.dart`, JSON):

```json
{"v":1,"kind":"calibration","t0":1729123456.0,"t1":1729123516.0,
 "vacant_s":58,"rounds":3,"degraded":false,
 "pathloss":{"n":2.31,"r0_db":-41.2,"rmse_db":2.4},
 "links":[{"link":"RAPTOR-1/RAPTOR-2","band":"2437","ch":0,
           "fade_db":-8.3,"mu_calib_dbm":-72.1}]}
```

ARTI runtime stats (1/min aggregate):

```json
{"v":1,"kind":"arti_stats","t":1729123576.0,
 "gated_residual":12,"gated_motion":40,"gated_near":31,"updated":214,
 "suspect_links":["RAPTOR-2/RAPTOR-3@915"],
 "max_mu_drift_db":3.1,"geom_recompute":2}
```

## Files (to be created/modified on implementation)

- `lib/services/adaptive_baseline.dart` — NEW: ARTI updater, guided-routine accumulator, batch refit
- `lib/services/tripwire.dart` — consume `mu_calib`/drift-compensated `mu`/`phi` sign; detection logic unchanged
- `lib/services/tracker.dart` — expose `x̂` + velocity for gates (read-only)
- `lib/services/gps_positioning.dart` — 3D node fixes for excess-path geometry
- `lib/services/health.dart` — `suspect`-link handling, fade-level health input
- `lib/services/node_udp_hub.dart` — `calib` beacon flag parsing
- `lib/services/recorder.dart` — calibration + `arti_stats` persistence
- `lib/state/app_state.dart` — calibration state machine, worst-link ranking
- `~/workspace/shepherd_field_kit/esp32/shepherd_node/shepherd_node.ino` — `calib` flag in UDP 49160 beacons
