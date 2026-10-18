# Doppler-Only Track Refinement — Spec

**Status:** implemented in v0.17.0; field validation pending. **RX-only.** The bridge listens to ambient
LTE downlink — a signal the carrier transmits anyway — and measures
what moving objects do to it. Nothing here transmits, jams, deauths,
or spoofs.

## Goal

Add a **Doppler-only track-refinement layer** to the SDR bridge +
app pipeline: a second opinion on a tripwire track's motion that
costs *zero* bandwidth and no transmitter. A 0.5 s coherent
processing interval (CPI) buys ~2 Hz Doppler resolution — about
0.16 m/s radial-velocity resolution at 1.86 GHz — on ordinary
SDR-class hardware. The output is **radial velocity, not a position**:
it answers "the track's motion is Doppler-consistent" and feeds the
gated merger as upgrade-only corroboration. Disagreement **never
deletes or downgrades** a tripwire track.

## Background

### Ji et al., arXiv:2602.08203 (Feb 2026) — READ IN FULL, CONFIRMED

Dual-bistatic *passive* drone tracking using two LTE eNodeBs
(1.85 / 1.87 GHz) as illuminators of opportunity, USRP receivers,
2.5 MHz baseband, and **Doppler-only** tracking (no range, no
bandwidth-intensive correlation surface):

- **90% of position errors < 0.5 m** with known initialization, and
  **< 1.1 m** with AoA-based initialization — at **< 30 m receiver
  range**. That is the verified operating envelope: short range,
  small target, LTE-band illumination.
- The FEKO electromagnetic simulation produced the finding that
  matters most for Shepherd's honesty posture: **removing the
  payload degrades RCS by 22 dB** (and cylinder/sphere payloads sat
  7/16 dB below the cuboid payload case). A drone's *detectability
  is dominated by what it carries*, not by its clean airframe. A
  published RCS number for a bare airframe is the optimistic case;
  a payload-stripped Group 2 airframe can sit 22 dB below it.
- Two eNBs made it *dual*-bistatic: two independent Doppler
  histories disambiguate motion that one geometry cannot.

**What the paper does NOT give us (honesty boundaries):** their
0.5 m accuracy came from a fused dual-geometry Doppler track with
USRP-class receivers and known/AoA initialization at short range.
Shepherd proposes a *single-geometry, single-radio* Doppler channel
as corroboration only — no position claim, no accuracy inheritance.
We take the *mechanism* (Doppler-only works on ambient LTE at
SDR-class cost) and the *RCS calibration point* (the 22 dB swing),
not their error statistics.

## Proposed design

### Signal chain

```
SDR stare on LTE downlink (1.8–1.9 GHz band)     ← ambient, always there
  → per-CPI (0.5 s) complex baseband buffer
  → doppler_detect.DopplerTracker (bridge-side DSP module, elrs_detect.py pattern)
      · reference tap: direct-path LTE signal (strongest static component)
      · surveillance: same buffer, clutter-canceled against reference
      · Doppler spectrum via FFT across the CPI (2 Hz bins)
      · peak detect: (doppler_hz, radial_m/s, snr_db)
  → doppler_ref event → UDP 127.0.0.1:49161 (like elrs_chirp/elrs_signature)
        ↓
SdrDriver (lib/services/radio_driver.dart): stores recent doppler_refs (120 s window)
        ↓
DopplerCorrelator (pure function, tested): predicted radial velocity from the
      app's RF tripwire track vs observed Doppler → agreement score
        ↓
confidence_merger.dart §5a: gated, upgrade-only corroboration
```

#### Stage 1 — bridge-side DSP (`doppler_detect.py`, new module)

Modeled on `elrs_detect.py`'s contract: a stateful detector class
with an `observe()` method fed from the main loop, returning a list
of UDP-ready event dicts. The bridge's `--stare` mode already parks a
radio on one center frequency; Doppler mode is a stare at an LTE
downlink carrier with a DSP chain attached instead of the band-energy
chain.

- **CPI 0.5 s.** Doppler resolution = 1/CPI = **2 Hz**. At 1.86 GHz
  (λ = 0.161 m), radial-velocity resolution = (λ/2)·Δf ≈ **0.16 m/s**.
  No bandwidth needed: Doppler resolution comes from *time*, not
  spectrum — this is the whole economic argument for the feature.
- **Reference/surveillance split.** The direct-path LTE signal (the
  strongest, static component) is the phase reference; the
  surveillance path is the same capture with the static component
  canceled (adaptive clutter cancellation, then FFT across the CPI).
  A moving reflector shows as a Doppler-shifted peak — exactly the
  passive-radar textbook shape, executed at SDR cost.
- **Output per CPI:** strongest Doppler peak(s) above an SNR gate —
  `(doppler_hz, radial_ms, snr_db)`, sign convention documented in
  the module (approaching = negative, matching the app tracker's
  velocity sign). Throttled: at most ~1 event per CPI when a peak
  persists; nothing emitted when the spectrum is empty (idle = silent,
  like the ELRS detectors).
- **`--no-doppler` flag** in `sdr_bridge.py` (mirroring `--no-elrs`),
  plus a SimBackend emitter for hardware-free demos: the simulate
  backend emits a wall-clock-correlated Doppler signature so the
  app-side correlator and merger wiring can be tested with zero RF.

#### Stage 2 — app-side correlation (`DopplerCorrelator` in `radio_driver.dart`)

A pure function, tested like `GeminiCorrelator`:

1. For each active RF tripwire track, take the track's estimated
   velocity vector and the known (configured) positions of the SDR
   radio and the LTE eNB being used — both are operator-configured
   station data, not measured.
2. Compute the **predicted bistatic radial velocity** of the track
   along the radio↔eNB geometry.
3. Compare against observed `doppler_ref` events in a 120 s window
   (the ELRS correlation window): agreement = |predicted − observed|
   within a gate (suggested: max(0.5 m/s, 25% of predicted) — a
   *tolerance*, labeled as starting estimate).
4. Agreement score: `1 − exp(−agreements/2)` — saturating, like the
   ELRS scorers; a lone agreement scores ~0.39, *above* the surface
   bar, so require ≥ 2 agreements or a single high-SNR (> 12 dB)
   agreement before the score counts. (The single-coincidence
   weakness documented in the ELRS spec's Urban-LoRa mode is the
   precedent — don't repeat it.)

#### Stage 3 — merger wiring (§5a)

Doppler agreement feeds the gated merger as **existence/consistency
evidence**: "an independent passive sensor measures radial motion
consistent with this track's velocity."

- Boost class: **velocity-consistency**, suggested 0.10 (below
  camera-motion's 0.15 — Doppler corroborates motion, it doesn't
  corroborate position or identity).
- Gate weight `w_dop = freshness · health · quality`:
  - **freshness:** 60 s staleness horizon (Doppler arrives at 2 Hz
    but a track's velocity estimate evolves slowly);
  - **health:** SDR driver recently polling, Doppler detector not
    `--no-doppler`-disabled, LTE reference lock healthy (a lost
    direct-path reference zeroes the weight — without the reference
    there is no coherent measurement);
  - **quality:** the agreement score itself, gated at the
    2-agreement / high-SNR bar above.
- **Never subtractive** (merger property, fuzz-tested). A Doppler
  *disagreement* contributes exactly 0 — the track keeps whatever
  confidence the tripwire earned. The honest reason: a null can mean
  tangential motion (zero radial component), a payload-stripped RCS
  22 dB below expectation, or the mover simply being RF-quiet to
  *this* geometry — none of which disproves the tripwire.
- Suspended while the track is **INCONSISTENT** (§5b), like every
  other upgrade.

### The 22 dB calibration point (honest-scope use of a negative result)

The FEKO result is not a capability — it is a *calibration of our
own optimism*, and the spec uses it that way:

- Shepherd's mission focus is **Group 2–3 UAS** (ScanEagle/Shadow/
  V-BAT-class, Geran/Shahed-type). A Shahed in terminal phase is
  **RF-quiet and payload-released** — the configuration the paper
  shows can sit ~22 dB below the "clean airframe with payload" RCS
  that a brochure number assumes.
- Design consequence, written into the spec: **Doppler detection
  thresholds and expected-detection ranges are computed against the
  payload-stripped RCS, never the brochure number.** Any range or
  sensitivity claim in a future validation report that uses the
  optimistic RCS is a spec violation.
- It also bounds the *absence* interpretation above: a missed
  Doppler return on a tripwire track is the expected outcome for a
  low-RCS configuration, not evidence the track is false.

### RX-only posture (explicit)

- The bridge **receives only**. The LTE downlink is transmitted by
  the carrier's eNB regardless of us; we measure reflections of a
  signal that already fills the air. There is no transmission, no
  modification of any network, no interaction with the eNB, and no
  decoding of user payload content — the DSP needs only the
  waveform's phase structure as a reference, never its bits.
- No new hardware transmits. The `--stare` LTE mode uses the same
  RX-only backends (RTL-SDR covers 1.8–1.9 GHz; Pluto/USRP/HackRF/
  Airspy/Lime all cover it).

## Event schema (UDP JSON → 127.0.0.1:49161)

```json
{"v":1,"kind":"doppler_ref","radio":"rtlsdr0",
 "center_mhz":1865.0,"doppler_hz":-14.2,"radial_ms":-1.14,
 "snr_db":11.3,"ref_locked":true,"t":1729123456.789}
```

- `doppler_hz`: measured Doppler shift of the peak (Hz, signed).
- `radial_ms`: radial velocity implied at the tuned center (m/s;
  negative = approaching, documented convention).
- `snr_db`: peak SNR over the clutter-canceled noise floor.
- `ref_locked`: direct-path reference healthy. App treats
  `ref_locked: false` as zero weight — no reference, no coherent
  measurement, no claim.
- Additive like all bridge events: older app builds ignore unknown
  `kind`s; the bridge sends nothing when the detector is idle.

## Honest-scope limits

- **Radial velocity only. No position, no identity, no imagery.**
  One Doppler history is a line, not a fix. The paper's sub-meter
  accuracy came from *dual*-bistatic fusion with USRPs at < 30 m —
  Shepherd claims none of it. The output is "motion consistent with
  the track", full stop.
- **Geometry-dependent.** Tangential motion is Doppler-invisible to
  a given radio↔eNB pair. A null return is *uninformative*, never
  exonerating — the merger's never-subtractive property is the
  enforcement mechanism.
- **LTE-dependent.** No ambient LTE downlink at usable strength →
  no reference → no feature. Rural/degraded-spectrum deployments
  lose this channel; the dashboard must say so (reference-lock
  health is surfaced, not hidden).
- **RCS reality.** Mission-config (possibly payload-stripped,
  RF-quiet) RCS governs detectability — the 22 dB FEKO swing is the
  standing calibration. Sensitivity numbers computed against
  brochure airframe RCS are dishonest by construction.
- **Clock/sync.** Doppler needs a stable reference over the 0.5 s
  CPI — cheap SDRs (RTL-SDR TCXO-class) are adequate for 2 Hz bins
  at 1.86 GHz; the spec documents the requirement (frequency
  stability ≪ 2 Hz over 0.5 s) rather than assuming it.

## Test / validation plan

1. **Resolution unit test** (synthetic IQ). Feed `DopplerTracker`
   a simulated LTE-like reference plus a mover at known radial
   velocity (−1.14 m/s at 1865 MHz ⇒ −14.2 Hz). *Pass:* reported
   `doppler_hz` within ±0.5 Hz of truth over 20 consecutive CPIs;
   `ref_locked` true; no events emitted for a static-only scene.
   (Validates the 0.16 m/s resolution claim end to end.)
2. **Clutter-cancellation test.** Static scene + strong direct path
   only. *Pass:* zero `doppler_ref` events above the SNR gate in
   200 CPIs — the detector must be quiet when nothing moves.
   (Fail-loud here would poison the merger; quiet is the
   requirement.)
3. **Reference-loss fail-safe.** Kill the direct-path component
   (attenuate to noise). *Pass:* `ref_locked` goes false within 2
   CPIs and the app-side weight drops to exactly 0 — no stale
   Doppler upgrades survive reference loss.
4. **Correlator agreement test** (app-side, synthetic tracks).
   Track with known velocity + matching `doppler_ref` stream.
   *Pass:* ≥ 2 in-gate agreements produce the 0.10-class boost;
   single-agreement streams below the SNR bar contribute 0.
   **Disagreement test:** track velocity vs opposite-sign Doppler.
   *Pass:* merger contribution exactly 0 AND the tripwire track's
   `C_RF` unchanged — disagreement never deletes or downgrades.
5. **Merger property tests.** *Pass:* never subtractive
   (`C_display ≥ C_RF` fuzz-tested with Doppler evidence active),
   +0.35 total cap holds with Doppler + CSI + ELRS evidence, and
   INCONSISTENT track state suspends the Doppler upgrade.
6. **SimBackend demo.** Two bridge instances in `--simulate`
   (band-energy + Doppler modes) against a scripted mover.
   *Pass:* app correlates a Doppler-consistent track and surfaces
   the evidence line — the hardware-free path the field team uses
   to validate wiring before deploying radios.
7. **Field honesty check (when hardware exists).** Vehicle pass at
   known speed past an LTE-stared radio, GPS ground truth.
   *Pass:* Doppler-inferred radial velocity within 0.5 m/s of
   ground truth in ≥ 8 of 10 passes. *Documents:* detection range
   at which the SNR gate stops firing, reported against the
   payload-stripped RCS assumption — this is where the 22 dB
   calibration gets its field number.

## Files (existing + proposed touch points)

- `field_kit/sdr_bridge/doppler_detect.py` — **new**: `DopplerTracker`
  (reference/surveillance split, clutter cancellation, CPI FFT,
  peak detect, `observe()` → event dicts); module docstring carries
  the RX-only statement.
- `field_kit/sdr_bridge/sdr_bridge.py` — main-loop wiring
  (`--no-doppler` to disable, mirroring `--no-elrs`), SimBackend
  Doppler emitter, protocol docs in the module docstring (the
  `doppler_ref` schema next to the `elrs_*` schemas).
- `field_kit/sdr_bridge/test_doppler_detect.py` — **new**: DSP tests
  (items 1–3 above).
- `lib/services/radio_driver.dart` — `DopplerRef` parsing,
  `DopplerCorrelator` (pure function, tested), `SdrDriver` storage
  (120 s window).
- `lib/services/confidence_merger.dart` — `e_dop` boost banding,
  `w_dop` gates (§5a); INCONSISTENT suspension (§5b).
- `lib/state/app_state.dart` — evidence lines + merger wiring.
- Proposed tests: `test/doppler_refinement_test.dart` (correlator,
  merger properties, disagreement-no-delete).
