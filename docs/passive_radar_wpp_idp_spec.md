# Passive Radar via WPP-IDP (No-Clean-Reference Architecture) — Spec

**Status:** implemented in v0.17.0; field validation pending. **RX-only, defensive-only.** This
feature listens to signals of opportunity and scores them; it never
transmits, jams, deauths, or spoofs. Nothing in this spec is a
transmit path.

**Paper basis (claim labels — read every one):**

- Colone et al., *IEEE Transactions on Aerospace and Electronic
  Systems*, vol. 59(5), 2023, pp. 6432–6451 — **READ IN FULL
  (CONFIRMED).** Source of the WPP-IDP architecture, the per-packet
  energy → DC removal → STFT chain, the waveform rule, and the Mavic
  Pro demonstration. Numbers below tagged CONFIRMED come from the
  full read.
- Yan et al., *Drones* 2023, 7(4):280 (Shahed-class blade-flash
  comparison) — **PARTIAL read: abstract + conclusions via snippets
  only; full body 403-blocked, not retried (CLAIMED-from-snippets,
  numbers unverified).** Its exact figures are documented here as
  unverified, not established.
- Vorobev et al., SPSympo 2019 (rotor-material micro-Doppler study)
  — **PRIMARY UNREAD (IEEE paywall; 4 discovery attempts failed).**
  Content below is secondhand (REPORTED) from a single secondary
  source.
- Kozlov et al., *Scientific Reports* (2026) 16:847
  (micro-Doppler deception) — **READ IN FULL (CONFIRMED).** This is
  **threat awareness, never a build item** — documented for defensive
  posture only, with no construction detail.

**Honesty contract (load-bearing):** everything this architecture
produces is *evidence consistent with a moving reflector* — never
"drone confirmed", never an identity, never a fire-control-quality
track. The Mavic Pro demonstration was meters-to-tens-of-meters
geometry; this spec must never be read as implying kilometer ranges
for this architecture. Outputs are disturbances, blobs, trails,
bearings, and estimates only — no imagery, no identity.

## Goal

Designate **WPP-IDP as the passive-radar milestone architecture for
the no-clean-reference case**: detection and Doppler estimation from
**one** RX channel with no reference antenna, no demodulation, and no
synchronization (CONFIRMED — this is what the "IDP" in the paper's
name buys you: integrated detection and processing on a single
surveillance channel). It maps directly onto hardware Shepherd
already has or is building:

- The **ESP32 WiFi sniffer already sees 802.11 preambles** — WPP-IDP's
  preamble-only processing is therefore implementable on the existing
  field-kit node firmware path, not a new hardware requirement.
- The **SDR bridge** (`field_kit/sdr_bridge/sdr_bridge.py`) is the
  capture source for per-packet energy when a wider-band SDR (not an
  ESP32) is the receiver.
- It slots **after** the standing program milestones: FIRST milestone
  is cancellation depth (~110 dB zero-Doppler cancellation of the
  direct path) in `passive_radar.py`; micro-Doppler is the classifier.
  This spec adds the no-clean-reference *detection* architecture, not
  a replacement for the two-channel PCL path — it is the designated
  fallback when no clean reference channel exists (single ESP32 node,
  single-SDR capture, no second antenna on the illuminator).

## Background — what the papers actually showed

### Colone et al. 2023: WPP-IDP (CONFIRMED, full read)

**The physics.** A WiFi access point is the illuminator of
opportunity. One receive antenna hears the AP directly (strong) **and**
the AP's signal scattered off a moving target (weak). The echo
interferes with the direct signal, producing a **slow amplitude
modulation** at the Doppler difference. Because there is no clean
reference channel, the classical passive-radar tool (cross-ambiguity
function between reference and surveillance) is unavailable. The
paper's IDP approach works on the interference itself:

```
per-packet received energy  →  DC removal  →  STFT
```

Per-packet energy turns the slow interference modulation into a
time series; DC removal strips the static direct-signal pedestal
(plus the stationary clutter); the STFT reveals the slow modulation
as a Doppler line. No demodulation, no synchronization to the AP, no
second antenna. This is the entire trick, and it is implementable in
plain DSP on sampled packet-energy time series (CONFIRMED).

**The waveform matters (CONFIRMED).** The authors' performance
parameter is BNR (beacon-to-noise ratio required at detection):

- **DSSS beacons are near-ideal: BNR ≈ 32.6 dB** — the constant,
  repeating beacon structure makes the interference deterministic and
  the IDP chain extracts it cleanly.
- **OFDM data symbols are bad: BNR ≈ 52–57 dB, and the requirement
  grows as DNR²** — random data symbols randomize the interference
  from symbol to symbol, destroying the coherent integration the
  chain depends on. The data-symbol version of this architecture is
  effectively unusable in real traffic.
- **The fix is WPP-IDP: preamble-only processing.** Processing only
  the periodic, identical preamble portions of WiFi frames restores
  determinism — it is the truly reference-free fix, at a cost of
  **~7 dB SNR** relative to ideal processing, and it **won the
  authors' indoor multipath tests** (where the data-symbol approach
  collapsed).

**The drone demonstration (CONFIRMED).** A **DJI Mavic Pro (~730 g)**
was demonstrated **detectable across its full trajectory** with this
architecture. Honest geometry: the tests were **meters-to-tens-of-
meters** scale — this is a perimeter/area sensor, not a long-range
radar, and the spec's deployment guidance is written for that scale.

**The hard limits (CONFIRMED, carried as limits, not solved):**

- **Forward-scatter baseline geometry is strongest.** Detection is a
  baseline-crossing phenomenon: the threat should cross Tx–Rx
  baselines, and sensitivity peaks near the baseline itself.
- **Static receiver assumed.** The paper's processing assumes the
  receiver does not move. Node motion on a mobile mesh is an **open
  problem** — this spec documents the requirement (ego-motion
  compensation) without claiming a solution.

### Yan et al. 2023: Shahed-class blade-flash caveat (PARTIAL)

From abstract + conclusion snippets only — **exact numbers are
unverified until the primary is obtained, and are stated here as
claims, not facts:**

- X-band active radar showed **puller/pusher-blade micro-Doppler
  WEAKER than lifting blades**: DFD (a Doppler-spread measure, Hz)
  **< 100 Hz** and DMR (a dimensionless modulation ratio) **< 0.3**
  for the pusher configuration, versus **> 200 Hz / 0.8** for lifting
  blades (CLAIMED-from-snippets, partial read).
- Companion material study (Vorobev et al., SPSympo 2019) is
  **PRIMARY UNREAD**; from a single secondhand source (REPORTED):
  carbon-fiber blades give clear micro-Doppler, plastic is weaker but
  detectable, and blade-modulation SNR tracks blade **material and
  length**.
- Physics summary for the spec: **material sets flash AMPLITUDE,
  blade-count × RPM sets FREQUENCY (WIDELY REPORTED).**

Shepherd implication, documented as design guidance: pusher-prop
(Shahed-class, Group 2–3 mission target) micro-Doppler is weaker
than multirotor lifting-blade modulation — **budget LONGER CPI on
the blade-flash feature for Shahed-class targets**, and treat blade
material as a **detectability prior, not a frequency prior** (it
moves amplitude, not the expected flash rate).

### Kozlov et al. 2026: micro-Doppler deception (CONFIRMED, full read — awareness only)

A **passive backscatter device** (described at block level: vector
modulator + arbitrary waveform generator, Vivaldi antennas) **mounted
on a DJI Mini 2 camouflaged it as a helicopter** to a 2.4 GHz radar
in an anechoic chamber (CONFIRMED). Key properties established by the
paper:

- Works on **moving** targets; **robust to frequency hopping**;
  **does not need exact radar-frequency knowledge** (CONFIRMED).
- Authors estimate miniaturization to **≤ 5×5 cm, ≤ 100 g**
  (CONFIRMED as the authors' estimate).
- The paper also describes the inverse: **making a flock of birds
  appear as a swarm of drones** (CONFIRMED).
- One co-author is from **Rafael Advanced Defense Systems**
  (CONFIRMED) — this is serious, resourced radar-countermeasure
  work, not a lab curiosity.

**Defensive-posture implication (this is why it is in this spec):**
any classifier that trusts blade micro-Doppler as **identity** —
including Shepherd's planned passive-radar classification feature —
is **spoofable by a cheap PCB-scale device**. Design rule, stated as
a hard constraint:

- **NEVER classify on micro-Doppler alone.**
- Keep an **RCS-reasonableness check** as the
  counter-countermeasure — this is the countermeasure the paper
  itself names (a Mini 2 cannot have a helicopter's radar
  cross-section; the lie fails a physics sanity check).

This section is **situational awareness, not a build item**. It is
documented here so the classifier design carries the constraint from
day one. It is not elaborated into instructions — there is no
buildable content in this subsection by design.

## Proposed design

### When WPP-IDP applies

Decision gate, evaluated per deployment:

```
Clean reference channel available? (second antenna on the illuminator,
B210-class dual coherent RX)
  YES → two-channel PCL path (passive_radar.py, cancellation-depth milestone first)
  NO  → WPP-IDP single-channel path (this spec)
      · single ESP32 node hearing WiFi preambles
      · single SDR capture with no reference antenna
      · any node where only packet-energy / preamble-energy time series exist
```

The two paths are complementary, not competing. WPP-IDP is the
designated architecture for the **no-clean-reference case**, which is
the common field-kit case (a lone ESP32 node does not have a second
antenna pointed at the AP).

### Signal chain (single RX channel)

```
RX capture (802.11 band, ESP32 preamble sniffer or SDR bridge)
  → per-packet (or per-preamble) energy time series E[n]
      · ESP32 path: the WiFi sniffer already reports per-packet RSSI/preamble
        observations — E[n] is a firmware-side accumulation, no IQ needed
      · SDR path: bridge-side per-packet energy estimator on the capture stream
  → waveform gate (the WPP rule — load-bearing):
      · illuminator using DSSS beacons → process all packets
      · illuminator using OFDM (802.11n/ac/ax data) → PREAMBLE-ONLY:
        keep energy samples from preamble portions, discard data-symbol portions
        (~7 dB SNR cost vs ideal — CONFIRMED paper result; accept it, do not try
        to "fix" it by including data symbols)
  → DC removal on E[n]  (kills the static direct-path pedestal + stationary clutter)
  → STFT over the residual  (slow amplitude modulation → Doppler line)
  → Doppler-line detector: CFAR-style threshold on the STFT magnitude
      · output: (t, doppler_hz, strength) — a *disturbance bearing estimate*,
        never an identity, never a position fix
  → events to the app (UDP JSON, same transport as the bridge's other events):
      {"v":1,"kind":"wpp_idp_doppler", ...}  (schema finalized at implementation)
```

App side (`SdrDriver` / ESP32 driver path in `radio_driver.dart`):
`wpp_idp_doppler` events are **detection corroboration**, merged as
existence evidence through the gated confidence merger
(`lib/services/confidence_merger.dart`) under the same upgrade-only
contract as the ELRS signature: they **never originate a track** —
the RF tripwire remains the detection authority — and they are
never subtractive. Doppler sign gives **inbound/outbound relative to
the baseline**, which the app already computes for tracks; no new
geometry is claimed beyond that.

### Waveform rule (carried verbatim into implementation)

| Illuminator waveform | Processing | Expected cost |
|---|---|---|
| DSSS beacons (802.11b-style) | All packets, IDP chain | Near-ideal (BNR ≈ 32.6 dB, CONFIRMED) |
| OFDM with preambles (802.11n/ac/ax) | **Preamble-only (WPP-IDP)** | ~7 dB SNR cost (CONFIRMED) |
| OFDM data symbols included | **Do not do this** | BNR 52–57 dB, worsens as DNR² (CONFIRMED) — effectively unusable |

The ESP32 sniffer already observes preambles; the firmware-side work
is accumulating per-preamble energy rather than per-packet RSSI.
Document the 7 dB cost in the UI-facing evidence text so operators
understand preamble-only detections are inherently weaker.

### Deployment geometry guidance (from the forward-scatter limit)

Because sensitivity peaks at baseline crossing (CONFIRMED):

- **Threat axes should cross Tx–Rx baselines.** In a fire-team bubble
  (4–6 nodes), the strongest WPP-IDP coverage is on the links whose
  baselines are perpendicular to the expected threat approach axis.
- The app's deployment guidance (future UI work, not this spec)
  should visualize baselines and flag approach axes with no baseline
  coverage as **blind sectors for this sensor** — honest geometry,
  stated up front.
- Range expectation: **meters to tens of meters** per the
  demonstrated geometry. This is a gap-filler inside the mesh's
  tripwire bubble, not a standoff sensor.

### Ego-motion: documented open problem, not solved here

The paper assumes a static receiver (CONFIRMED). Shepherd's
operational concept is **dismounted, on the move** — node motion
impresses its own slow amplitude modulation on E[n] and will
masquerade as Doppler. This spec **documents the requirement**
(ego-motion compensation before mobile WPP-IDP is trustworthy) and
**does not propose a solution**. Until it exists:

- WPP-IDP detections are valid only for **static nodes**
  (emplaced tripwire / overwatch positions).
- On moving nodes the chain may run for R&D logging, but its
  outputs **must not merge into track confidence** — gate on node
  motion state (GPS/IMU stillness) at the merger.

### Blade-flash classifier guidance (Shahed-class caveat)

Micro-Doppler is the **classifier**, not the detector (program
milestone order stands: cancellation depth first, then Doppler
features). Carrying the Yan/Vorobev findings as design guidance:

- **Longer CPI for Shahed-class targets.** Pusher-prop blade
  modulation is weaker than multirotor lifting-blade modulation
  (CLAIMED-from-snippets; exact DFD/DMR numbers unverified). The
  blade-flash feature extractor must support a **longer coherent
  processing interval for the Group 2–3 pusher-prop class** than for
  the multirotor class — parameterize CPI per target class, do not
  hard-code one CPI.
- **Blade material is a detectability prior, not a frequency prior.**
  Carbon fiber flashes brighter than plastic (REPORTED, single
  secondhand source; primary unread). Use it to set **detection
  thresholds**, never to predict flash frequency — frequency comes
  from blade-count × RPM (WIDELY REPORTED).
- **The deception constraint overrides everything in this
  subsection:** even a textbook blade-flash signature is
  **never sufficient for identity** — micro-Doppler is spoofable by
  a ≤5×5 cm, ≤100 g PCB-scale device (CONFIRMED). Blade-flash feeds
  the classifier as one feature among several, always behind the
  RCS-reasonableness gate.

## Integration points (actual files)

- `~/workspace/shepherd_field_kit/passive_radar/passive_radar.py` —
  existing PCL prototype; the **two-channel path stays primary where
  a clean reference exists**. WPP-IDP is implemented as the
  single-channel sibling (new module in the same directory), sharing
  the event vocabulary. The **~110 dB zero-Doppler cancellation
  milestone is unchanged and still comes first**.
- `~/workspace/shepherd_field_kit/passive_radar/b210_capture.py` —
  dual-RX capture; WPP-IDP needs only one channel, so single-channel
  captures from any supported SDR (including the bridge's stare
  mode) are valid inputs. No changes required; document single-
  channel capture as the WPP-IDP input.
- `~/workspace/shepherd_field_kit/passive_radar/README.md` — honest-
  scope section gains the WPP-IDP entries: meters-to-tens-of-meters
  demonstrated geometry, baseline-crossing requirement, static-
  receiver assumption, preamble-only 7 dB cost.
- `~/workspace/shepherd_field_kit/sdr_bridge/sdr_bridge.py` —
  RX-only bridge; the capture source for the SDR-side WPP-IDP chain.
  Per-packet/preamble energy estimation lives bridge-side (same
  process as the ELRS DSP in `elrs_detect.py`); events ride the
  existing UDP JSON transport to 127.0.0.1:49161. RX-only by
  construction — nothing here transmits.
- `~/workspace/rf_sentry/lib/services/radio_driver.dart` —
  `SdrDriver` app side: parse `wpp_idp_doppler` events, hold them in
  the recent-observations window, and feed the gated confidence
  merger as upgrade-only existence evidence (same pattern as
  `elrs_signature`). ESP32 preamble-energy observations arrive via
  the existing ESP32 driver path and the node UDP hub.

## Honest-scope limits (read before trusting any output)

1. **Range is meters to tens of meters.** The Mavic Pro demonstration
   (CONFIRMED) was at that scale. This architecture is a
   perimeter/area gap-filler inside the mesh bubble. Any reading of
   this spec as long-range radar is wrong.
2. **Baseline-crossing detector.** Sensitivity peaks when the threat
   crosses a Tx–Rx baseline (CONFIRMED). Threats flying parallel to
   all baselines, or outside the baseline fan, are weakly covered or
   uncovered — deployment guidance must show blind sectors honestly.
3. **Static receiver only, until ego-motion is solved.** Node motion
   is an open problem (CONFIRMED as the paper's assumption); moving-
   node outputs are R&D logging, never merged.
4. **Needs an illuminator of opportunity.** No WiFi AP (or other
   packetized illuminator) in range, no echo — same link-budget
   physics as the PCL honest-scope note. EM-quiet rural areas are
   poor terrain for this sensor.
5. **Preamble-only costs ~7 dB.** OFDM networks pay this by
   construction (CONFIRMED). Detections on preamble-only chains are
   inherently weaker; the evidence sheet must say so.
6. **OFDM data symbols are excluded deliberately.** Including them
   does not add sensitivity — it destroys it (BNR 52–57 dB, DNR²
   growth, CONFIRMED). "More data" is the wrong instinct here.
7. **Outputs are disturbances, not identities.** Doppler lines,
   inbound/outbound relative to a baseline, strength estimates. No
   imagery, no silhouettes, no fire-control-quality tracks, no
   identity — and per the deception finding, **micro-Doppler can be
   actively spoofed**, so identity was never on the table regardless.
8. **Blade-flash numbers are unverified.** The DFD < 100 Hz / DMR <
   0.3 pusher figures are CLAIMED-from-snippets from a partial read;
   the material study's primary is UNREAD. Longer-CPI guidance is
   directionally sound (physics: weaker modulation needs longer
   integration); the exact numbers are not established and must not
   be quoted as such.
9. **Small, quiet targets are harder.** A 250 g plastic quad returns
   less than a 730 g Mavic Pro, and an RF-quiet airframe in terminal
   phase leans entirely on the passive link-disturbance layer —
   consistent with the app's existing honest scope.
10. **The deception paper changes classifier design, not detection.**
    Kozlov et al. (CONFIRMED) proves micro-Doppler-as-identity is
    spoofable at PCB scale. Consequence: the classifier treats
    blade-flash as one corroborating feature behind an
    RCS-reasonableness gate, never as identity. This is a constraint
    carried forward, not a capability.

## Test / validation plan (concrete pass criteria)

1. **Synthetic IDP chain test** (`passive_radar/` test suite, new):
   simulate a WiFi AP emitting DSSS beacons + a target echo at known
   Doppler (e.g. +40 Hz) at BNR ≥ 35 dB, run per-packet energy → DC
   removal → STFT → Doppler-line detector. **Pass:** recovered
   Doppler within ±20% of truth, no false lines above threshold in
   the no-target control run.
2. **Waveform-rule parity test** (synthetic): same scene with OFDM
   data symbols — (a) full-packet processing must show the documented
   degradation (detection fails or BNR requirement jumps vs the
   DSSS case); (b) preamble-only processing must recover detection at
   the ~7 dB penalty, not worse than 10 dB. **Pass:** both (a) and
   (b) reproduce the paper's qualitative result. This test exists to
   stop anyone "improving" the chain by re-adding data symbols.
3. **DC-removal regression test:** static scene (direct path + fixed
   clutter, no target) → STFT of the residual must show **no Doppler
   lines above threshold**. **Pass:** zero detections in 10/10 static
   runs — the chain must not invent movers from pedestal leakage.
4. **Cancellation-depth milestone (unchanged, still first):**
   ~110 dB zero-Doppler cancellation of the direct path on real
   dual-channel captures before any field WPP-IDP trial is treated
   as signal rather than artifact. **Pass:** measured cancellation
   depth ≥ 100 dB on a controlled bench capture (10 dB engineering
   margin documented, not hidden).
5. **ESP32 preamble-energy offline demo (no SDR):** ESP32 sniffer
   logs per-preamble energy during a walked human crossing of a
   WiFi AP–node baseline; offline STFT must show the crossing as a
   Doppler excursion with the correct inbound/outbound sign.
   **Pass:** sign correct on 5/5 walked crossings, excursion visible
   above the noise floor in the STFT. (Human crossings stand in for
   the Mavic-class target at bench stage — stated, not hidden.)
6. **Blade-flash CPI parameterization test:** synthetic pusher-prop
   modulation at DFD = 80 Hz (below the claimed 100 Hz ceiling) and
   multirotor modulation at 250 Hz; the feature extractor with
   class-parameterized CPI must resolve the blade line for **both**
   classes. **Pass:** blade line detected in both, with the
   pusher-prop class automatically selecting the longer CPI. Exact
   DFD/DMR thresholds are **not** asserted until the Yan primary is
   obtained.
7. **Deception-constraint honesty test** (app side,
   `test/` suite): feed the classifier a textbook helicopter-like
   blade-flash signature attached to an RCS estimate of a 250 g
   quad. **Pass:** the classifier **refuses identity** — output
   contains "Possible" language, never a type assertion, and the
   RCS-reasonableness gate flags the mismatch. This test encodes
   "never classify on micro-Doppler alone" as a regression gate.
8. **Ego-motion gate test:** simulated node motion (0.5 m/s walk)
   with no target → WPP-IDP chain output must be **excluded from the
   merger** when the node motion state is non-static. **Pass:**
   merger contribution exactly 0 for all moving-node events; static-
   node events merge normally.

## Files (to be created — spec only, no code in this change)

- `field_kit/passive_radar/wpp_idp.py` — single-channel chain:
  per-packet/preamble energy → DC removal → STFT → Doppler-line
  detector (mirrors the `passive_radar.py` CLI conventions:
  `--demo` synthetic scene with asserted Doppler recovery)
- `field_kit/passive_radar/test_wpp_idp.py` — tests 1, 2, 3, 6 above
- `field_kit/sdr_bridge/wpp_idp_detect.py` — bridge-side per-preamble
  energy estimator + event emission (pattern follows `elrs_detect.py`)
- `lib/services/radio_driver.dart` — `wpp_idp_doppler` parsing +
  `SdrDriver` observation window (pattern follows `elrs_chirp`)
- `lib/state/app_state.dart` — merger wiring (upgrade-only, gated)
- `test/wpp_idp_test.dart` — app-side tests incl. honesty contract
  and the deception-constraint regression test (7)
- `field_kit/passive_radar/README.md` — honest-scope additions
  (§Integration points)

## Open questions (parked, not solved here)

- Ego-motion compensation for mobile nodes (open problem per the
  paper; R&D track, no proposal in this spec).
- Exact Yan et al. DFD/DMR figures — pending primary-paper access
  (full body 403-blocked); the CPI guidance stands on physics, the
  numbers do not stand as established.
- `wpp_idp_doppler` event schema fields (FINALIZED at implementation;
  aligned 2026-10-18 to the bridge variant: v / kind / radio (= node id)
  / band / doppler_hz / strength / t / motion_state, plus optional
  direction_vs_baseline, merger_eligible, evidence. One deliberate
  difference between producers: bridge doppler_hz is a MAGNITUDE
  (>= 0, sign ambiguous from the real energy series); passive_radar
  doppler_hz is SIGNED where the Tx-Rx baseline geometry is known
  (positive = inbound vs baseline). The app decoder
  (WppIdpDoppler.tryParse, built to this schema) accepts both.)
- Whether the ESP32 firmware accumulates per-preamble energy on-
  device or ships per-packet RSSI for host-side accumulation
  (firmware cost vs UDP bandwidth tradeoff — decided at
  implementation).
