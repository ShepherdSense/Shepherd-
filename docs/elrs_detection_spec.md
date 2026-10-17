# ELRS Gemini Signature Detection — Spec

**Status:** implemented, unreleased. **RX-only.** There is no transmit
path anywhere in this feature; it listens and scores, nothing more.

## What this is

Protocol-pattern evidence for ELRS-style control links, built on a
verified RF fact: **Gemini helps the detector, not the hider.**
Single-band Gemini transmits the same packet on two frequencies at
once (~40 MHz apart @ 2.4 GHz, ~10 MHz apart @ 900 MHz); GemX
transmits on 2.4 GHz **and** 900 MHz simultaneously. Both are FHSS
underneath, LoRa modulation (FLRC at the highest 2.4 GHz packet rates
is a documented gap — §5). Twice the energy, and for GemX a
time-correlated dual-band chirp pattern almost nothing else makes.

**Honesty contract (load-bearing):** the output is *"signature
consistent with ELRS Gemini"* — never "confirmed ELRS", never "ELRS
drone detected". No public ELRS-specific detector exists; this is the
first attempt, and it must not present as ground truth. Any LoRa FHSS
emitter inside the detection grid can raise the score. UI strings are
asserted by tests (`test/sdr_bridge_test.dart`, "ELRS honesty
contract") to contain "Possible" and to never contain
"confirm"/"identified as"/"detected ELRS".

## Signal chain

```
SDR capture (2.4 GHz / 900 MHz band)
  → CPU gate: narrowband peak ≥ 8 dB over noise? (else skip)
  → dechirp scan over the (SF, BW) candidate grid
      · multiply each chirp-length window by the conjugate ideal upchirp
      · FFT; window "lights" if top-3 bins hold ≥ 50% of window energy
        (a dechirped preamble is a pure tone, ~0.9; a dechirped plain
        tone/FSK is still a sweep, ~0.05 -- peak-to-median alone cannot
        tell them apart, concentration can)
      · two window phases (0, half-chirp) so straddling trains are caught
      · cluster lit windows by frequency (1 MHz); longest run of
        ≥ 6 consecutive windows = one chirp train
  → elrs_chirp event (throttled: ≤ 1 per band per 2 s, strongest train)
  → hop tracker: (t, freq) sequence per band — doubles as the FHSS
    gate (below)
  → bridge-local GeminiScorer: in ONE capture, two chirp trains that
    (a) OVERLAP in time by ≥ 50% of the shorter train (a sequential
    FHSS hopper's trains never overlap — regression-tested), and
    (b) sit at the band's documented Gemini separation — 35–45 MHz
    @ 2.4 GHz (`gemini-2g4`) or 8–12 MHz @ 900 MHz (`gemini-900m`),
    chosen band-aware (a sub-GHz pair is never labeled 2g4).
    FHSS gate: the tracker's distinct-channel count must be ≥ 3 in
    the last 30 s, or the coincidence doesn't count (two fixed tones
    40 MHz apart are not Gemini). Score += 0.25 per coincidence,
    30 s decay, cap 1.0 → elrs_signature event at score ≥ 0.30
```

App side (`SdrDriver`): keeps recent `elrs_chirp`s (120 s window) and
latest bridge `elrs_signature`s per radio. `GeminiCorrelator`
(pure function, tested) pairs chirps **across radios** within 2 s:

- **GemX:** 2.4 GHz chirp + 900 MHz chirp → mode `gemx`
- **Cross-radio dual-frequency:** two 2.4 GHz chirps 35–45 MHz apart
  → mode `gemini-2g4` (two cheap SDRs stitched across the pair)

Score: `1 − exp(−pairs/3)` — several coincidences to matter; a lone
pair scores ~0.28, below the 0.30 bar the app uses to surface and
merge. Saturating, like the bridge scorer.

**App-level limits (read before trusting a `gemx` hit):**
- The 2 s coincidence window cannot establish true simultaneity —
  two radios' captures are seconds apart per sweep and their clocks
  aren't synchronized. A single fast-hopping non-Gemini ELRS link heard
  by two radios at *different* hops within 2 s can pair up. The app
  score is therefore weaker evidence than a bridge-local coincidence;
  both are labeled "Possible" either way. Carrying train `t0`/duration
  in `elrs_chirp` events (for tighter app-level correlation) is
  follow-up work.
- **Urban-LoRa false-positive mode:** in a LoRa-dense environment
  (LoRaWAN gateways + 2.4 GHz LoRa devices), two coincidental
  cross-band chirp pairs inside the 120 s window are plausible, and the
  margin is thin by construction (1 pair = 0.28 vs the 0.30 bar).
  Bounded by upgrade-only + the merger's +0.35 cap + "Possible"
  wording — but treat lone-pair GemX hits in cities as weak.
- **Pair-stability (known limitation, follow-up):** neither scorer
  requires the coincident pair's *separation* to stay stable across
  observations. Gemini's dual-chain offset is fixed by firmware; two
  independent hoppers' separation jitters. Tracking separation
  consistency (e.g. std < 1 MHz) would genuinely discriminate them.

## How the app uses it (upgrade-only)

The RF tripwire remains the detection authority — the signature never
originates a track. It feeds the gated confidence merger
(`lib/services/confidence_merger.dart`) as **existence evidence**:
"a LoRa-FHSS emitter with the Gemini dual-emission pattern is
active", while the track's position comes from the tripwire. No
geometry is claimed.

- Boost 0.15 (camera-motion class), gate weight =
  `reliabilityGate(alignmentQuality: score, age, 60 s horizon,
  sourceHealthy: SDR driver recently polling)`.
- Stale (> 60 s), unscored (< 0.30), or unhealthy-source signatures
  contribute exactly 0 — the AV-FDTI zero-weight case.
- Never subtractive (merger property, fuzz-tested).
- Not double-counting: SDR band *energy* already feeds the tripwire
  via virtual links; this is the modulation *pattern* on top of the
  energy — a distinct measurement. And within the ELRS path itself: a
  bridge-local signature and an app-correlated signature of the same
  mode never both contribute (the app one is skipped when the bridge
  already reported that mode).

Surfaced in the evidence sheet ("WHY DID IT ALERT") as an RF
SIGNATURES section with the "consistent with, never confirmed"
disclaimer.

## Score semantics

| Score | Meaning |
|------:|---------|
| 0.00–0.29 | Weak / single coincidence. Not surfaced, not merged. |
| 0.30–0.59 | Possible signature, few coincidences. Surfaced; small upgrade. |
| 0.60–1.00 | Repeated coincidences. Stronger upgrade (still capped by the merger's +0.35 total). |

## Hardware requirements (no hand-waving)

| What you want | What it takes |
|---|---|
| LoRa chirp trains, one band | Any supported SDR sweeping/staring 2.4 GHz or 900 MHz (RTL-SDR covers 900 MHz; 2.4 GHz needs Pluto/USRP/HackRF/Airspy/Lime). |
| Bridge-local `gemini-2g4` signature | **≥ ~50 MHz instantaneous bandwidth** in one capture (USRP X310 class). On narrower radios this event simply never fires — documented, not a bug. |
| GemX (2.4 GHz + 900 MHz) | **Two radios**, two bridge instances (e.g. `--stare 2437` + `--stare 915`), one app correlating. No single SDR spans both bands. |
| Single-band Gemini via two radios | Two 2.4 GHz-capable SDRs tuned ~40 MHz apart. |

**Near-far desensitization (reviewer A, documented not fixed):** a
strong narrowband interferer (~+15 dB over the chirp) spreads its
energy across all bins after dechirp, dragging the spectral
concentration below the 0.5 gate — the detector goes silent. In the
2.4 GHz ISM band a +15 dB interferer is the normal case, not the edge
case. Failure direction is fail-silent (safe for an upgrade-only
path), but "any supported SDR sweeping 2.4 GHz" overpromises in
congested spectrum. Tone excision before the dechirp scan is
follow-up work.

Demo without hardware: two `--simulate` instances (one `--stare 2437`,
one `--stare 915`) emit wall-clock-correlated chirp trains 100–108 s of
every 180 s; the app correlates them into a GemX signature.

## Modes covered vs gaps

**Covered:** ELRS LoRa modes — 2.4 GHz packet rates 250/150/100/50 Hz
(SX1280 LoRa) and 900 MHz LoRa modes (SX127x), via the (SF, BW)
candidate grid. Exact per-rate (SF, BW) mapping is UNVERIFIED against
the ELRS source; the grid covers the plausible space, so any LoRa
chirp there is caught regardless. Rows in `ELRS_LORA_CANDIDATES`
marked "sub-GHz SX127x narrow modes" are grid-fill for the generic
LoRa case, not confirmed ELRS modes — a missed ELRS mode fails
quiet (safe direction for a corroboration channel), never loud.

**Gaps (documented, not hidden):**
1. **FLRC modes** (2.4 GHz 500/333 Hz): coherent FSK, not LoRa — the
   chirp detector stays silent (tested: FSK bursts produce no trains).
   A dedicated FLRC detector is future work.
2. **Encrypted / hidden variants:** none exist in mainline ELRS; if
   they appear, the signature still fires on the modulation (it never
   relied on content).
3. **Identity:** cannot distinguish ELRS from any other LoRa FHSS
   emitter with certainty — hence "consistent with", always.
4. **DF:** this feature is detection/corroboration only. DF of ELRS
   (pseudo-Doppler, TDOA, interferometry) is a separate, unbuilt
   problem — see the ELRS brief's honest gaps.
5. **NCC 2022 FHSS-RNG finding** (partly predictable hop sequence):
   unverified against 3.x/4.x firmware; not relied upon.

## Event schemas (UDP JSON → 127.0.0.1:49161)

```json
{"v":1,"kind":"elrs_chirp","radio":"rtlsdr0","band":"2437",
 "center_mhz":2437.0,"freq_mhz":2441.23,"sf":5,"bw_khz":812.5,
 "snr_db":14.2,"t":1729123456.789}

{"v":1,"kind":"elrs_signature","radio":"usrp0","mode":"gemini-2g4",
 "score":0.62,"obs":7,"bands":["2437"],
 "freqs_mhz":[2441.2,2481.3],"t":1729123456.789}
```

Both are additive: older app builds ignore unknown `kind`s; the
bridge sends nothing when the detector is idle.

## Files

- `field_kit/sdr_bridge/elrs_detect.py` — DSP (chirp detector, hop
  tracker, Gemini scorer, ElrsDetector)
- `field_kit/sdr_bridge/sdr_bridge.py` — main-loop wiring (`--no-elrs`
  to disable), SimBackend chirp emitter, protocol docs
- `field_kit/sdr_bridge/test_elrs_detect.py` — 13 DSP tests
- `lib/services/radio_driver.dart` — ElrsChirp/ElrsSignature parsing,
  GeminiCorrelator, SdrDriver storage
- `lib/state/app_state.dart` — evidence lines + merger wiring
- `lib/screens/evidence_sheet.dart` — RF SIGNATURES section
- `test/sdr_bridge_test.dart` — 15 app-side tests incl. honesty contract
