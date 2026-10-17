# Shepherd DF Node — pseudo-Doppler direction-finding variant

Status: SPEC (accepted 2026-10-16). Not yet implemented.
Owner: Draco. Implements: his "at least a general direction" bar for
external RF emitters.

## 1. Goal

A variant of the ESP32 field-kit node that reports a general-direction
bearing to an external RF emitter — not a fix, not an identification,
just "that way, with confidence." Bearings feed Shepherd over the same
UDP channel the nodes already use, so the future ESP32Driver and mesh
fusion can cross-fix two stations later.

## 2. The principle (and what v1 honestly is)

Classic pseudo-Doppler DF: 4+ whip antennas in a ring are switched
sequentially into ONE receiver, simulating a single rotating antenna.
The simulated rotation phase-modulates the incoming signal; an FM
receiver demodulates that as a tone at the switching rate, and the
tone's phase relative to the switching clock gives the bearing. No
moving parts. Ham-radio foxhunt staple.

**What v1 is, stated plainly:** true pseudo-Doppler needs an
FM-demodulating receiver to extract the Doppler tone. The CC1101 is an
FSK/GFSK/OOK packet radio — it has no FM voice demodulator and no
audio output. What it DOES have is a real 8-bit RSSI register. So v1
rotates the 4 antennas and compares per-antenna RSSI: the antenna
facing the emitter reads hotter. Bearing = weighted vector centroid of
the four readings. That is sequential lobing — same family, coarser,
buildable today on the hardware already in the node. **This spec does
not claim Doppler-tone extraction.** True tone extraction is the
documented Phase 2 upgrade path (§9), which needs an FM receiver stage.

(The nRF24L01 cannot do this at all: it has only a 1-bit RPD, no RSSI
register. v1 is a 433 MHz / CC1101 band instrument.)

## 3. Hardware

- **Antenna ring:** 4 quarter-wave whips at 0°/90°/180°/270° on a disc
  ~λ/4 in diameter. At 433.92 MHz, λ ≈ 69 cm → ~17 cm disc — a
  dinner-plate-sized unit, vertical monopoles over a small ground plane
  (PCB or tin disc). Each antenna's pattern is shaped by mutual
  coupling and shadowing from its neighbors; that differentiation is
  what the RSSI comparison reads.
- **RF switch:** SP4T IC recommended for buildability —
  SKY13317-373LF or Peregrine PE42442/PE4259 (0.1–6 GHz, GPIO-level
  control, ~0.5 dB insertion loss, nanosecond switching). PIN-diode
  alternative (4× SMP1345 with bias tees and RF chokes) noted: cheaper,
  more soldering, more ways to get it subtly wrong.
- **Control:** 2 ESP32 GPIOs for switch select lines (suggest GPIO 25/26
  — safe, non-strapping). CC1101 stays on the existing VSPI wiring
  (CS=21, SCK=18, MISO=19, MOSI=23) from the base node firmware.
- **Power:** same USB power as the base node; the switch IC draws
  negligible current.
- **Reference mark:** antenna 0 gets a physical "N" mark on the
  enclosure. Bearings are relative to antenna 0 unless the operator
  aligns the mark to north.

## 4. Firmware (variant sketch, shares the base node)

New sketch `shepherd_df_node.ino`, built from `shepherd_node.ino` —
same beacon/event UDP protocol (port 49160), same nodeId/Preferences/
mDNS/WebServer scaffolding, same tripwire sensors (wifi/ble/nRF24/CC1101
energy) running as before. The DF node is a superset: everything the
base node does, plus bearings.

### Measurement cycle

For rotation r in 1..N (N=8):
  for antenna a in 0..3:
    set switch GPIOs → dwell 3 ms (let CC1101 RSSI settle) →
    read RSSI register (0xF4) 3×, average → accumulate rssi[a]

4 × 3 ms × 8 rotations ≈ 100 ms per bearing measurement. The node
averages several cycles and reports one bearing per ~1–2 s. A cycle is
rejected (not averaged) if total received energy varies wildly across
it — that means the emitter is bursty or gone, and incomparable
per-antenna samples would produce a confident-looking wrong bearing.

### Bearing math

Per-antenna mean RSSI in dBm → convert to linear power for weighting
(a hot antenna should dominate, and dB averaging would flatten it):

    w_i = 10^(rssi_i / 10),  φ_i = i × 90°
    X = Σ w_i·cos(φ_i),  Y = Σ w_i·sin(φ_i)
    bearing = atan2(Y, X)   (relative to antenna 0; see §3 mark)

Confidence from reading spread — equal readings on all four antennas
means no directional information:

    spread_dB = max(rssi) − min(rssi)
    conf = clamp((spread_dB − 1.5) / 6.0, 0, 1)

A bearing is emitted only when conf ≥ 0.35 AND the CC1101 energy
channel (the existing `chCc` tripwire) says something is actually
there. No bearing is better than a wrong bearing.

### Calibration (part of Phase 1, not optional polish)

Per-antenna gain offsets (PCB asymmetry, switch path differences) are
real and will bias bearings if ignored. Procedure: place a known
433.92 MHz source (a second ESP32, a cheap 433 MHz keyfob) at fixed
radius, walk it around the node in 45° steps, record per-antenna means,
store 4 offset floats in Preferences, subtract before the bearing math.
The status page shows raw per-antenna bars so the operator can see the
calibration working.

## 5. Protocol extension (existing UDP 49160 channel)

New message type alongside `beacon` and `event`:

    {"type":"df_bearing","node":"SHN-XXXX","sensor":"cc110",
     "bearing_deg":135,"conf":0.6,"freq_hz":433920000}

- `bearing_deg`: 0–359, relative to the antenna-0 reference mark.
- Shepherd-side integration (future ESP32Driver / mesh fusion):
  bearings are timestamped estimates with confidence, same honest
  treatment as everything else. Two stations' bearings → cross-fix,
  app-side, later — not this spec's build.

The beacon's `sensors` array gains `"df"` when the switch hardware is
detected at boot (probe: drive the switch through all 4 positions,
confirm CC1101 RSSI changes sanely — a dead switch reads identical on
all antennas).

## 6. Honest limits (non-negotiable, stated in-app where shown)

1. **Emitter persistence.** The signal must be present and roughly
   stable through a measurement window (~0.1–2 s). Bursty
   frequency-hoppers (FHSS) defeat per-antenna comparison — the samples
   aren't comparable. This is the big one; state it, don't hedge it.
2. **Multipath smears bearings.** Indoors, urban clutter, near big
   metal — bearings degrade like every DF system ever built.
3. **One station = a bearing, not a fix.** Two stations → cross-fix,
   and that math lives in Shepherd, not the node.
4. **Accuracy is quadrant-level.** Realistic ±20–40° — "point that way,"
   not BEAST+ phase-interferometry precision. It clears Draco's
   "general direction" bar with margin and claims nothing more.
5. **Relative bearing** unless the operator aligns the antenna-0 mark
   to north. A magnetometer add-on is a possible later refinement, not
   promised here.
6. **Passive receive-only.** The switch IC and CC1101 never transmit
   in this design. Defensive-only posture holds, same as the base node.
7. **433 MHz band.** Covers 433.92 MHz-class links (RC, some drone
   control, LoRa). 2.4 GHz DF needs RSSI-capable 2.4 GHz hardware —
   the nRF24 can't do it — noted as future, not promised.

## 7. What this does NOT do

- Does not identify the emitter (no demod, no protocol decode) —
  bearing + confidence only.
- Does not track fast hoppers or very brief transmissions.
- Does not replace the base node's tripwire sensors; it adds to them.
- Does not do true Doppler-tone extraction (see §2, §9).

## 8. Phased build

- **Phase 1 — switched-RSSI DF variant (this spec).** Ring + SP4T
  hardware, `shepherd_df_node.ino` firmware, calibration procedure,
  `df_bearing` protocol, boot self-test of the switch. Field
  validation: known-source walk-around at several ranges, record
  bearing-error statistics before trusting the confidence numbers.
- **Phase 2 — true Doppler-tone upgrade path (documented, not
  designed here).** Add an FM receiver stage behind the same antenna
  ring and switch; demodulate the switching-rate tone; phase-compare
  against the switch clock for tighter bearings. Same ring, same
  protocol, better math.

## 9. Hermes one-shot implementation prompt

> In ~/workspace/shepherd_field_kit/esp32/, implement Phase 1 of
> ~/workspace/rf_sentry/docs/df_node_spec.md: the DF node variant
> firmware. Create shepherd_df_node/ as a copy of shepherd_node/,
> sharing its UDP 49160 beacon/event protocol, nodeId/Preferences/mDNS/
> WebServer scaffolding, and tripwire sensors. Add: SP4T switch drive
> on 2 GPIOs (default 25/26), the §4 measurement cycle (N=8 rotations,
> 3 ms dwell, RSSI register 0xF4 triple-read average), linear-power
> weighted bearing math with spread-based confidence, the conf ≥ 0.35
> + energy-gate emission rule, the df_bearing message (§5), the boot
> switch self-test advertising "df" in the beacon sensors array, the
> Preferences-backed 4-offset calibration with a serial-guided
> procedure, and per-antenna RSSI bars on the status page. Then compile
> with the project's arduino-cli ESP32 2.0.17 toolchain until it builds
> clean, and report the sketch size. Do NOT claim Doppler-tone
> extraction anywhere in code or comments — the header must state the
> switched-RSSI (sequential lobing) method honestly. Passive
> receive-only: no transmit code paths.
