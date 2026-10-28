# PMR Preamble-Jamming Monitor — Spec

> **EXPERIMENTAL.** This entire feature is experimental. It is a live-data
> monitor, not a validated detector: it has been verified on synthetic
> chirps for math only, never on live hardware. Do not present its
> readings as jamming verdicts, do not use its numbers as thresholds
> without re-deriving them on real hardware, and do not build
> operational decisions on it until the live-test procedure below has
> been run on real gateway traffic.

## What it is

A gateway-side early-warning monitor for LoRa preamble jamming, based
on Herrera-Loera et al., Sensors 2026, 26(19), 6123, "Early-Warning
Margins for Preamble-Directed Jamming in LoRa: A Dechirp-Domain
Sensitivity Framework with Severity-Graded Composite-Channel Stress
Testing" (Panamericana / RIT; full-read notes in
`~/memory/topics/shepherd_research/lane4_lowpower_transmission.md`,
entry [P27], 2026-10-28 sweep).

Shepherd's backhaul is raw SX1276 LoRa, 22-byte codec, SF7 / 125 kHz,
star topology (gateway + nodes; `radio.begin(freq, 125.0, 7, 5, 0x12,
power, 8)` — preambleLength register 8, i.e. 8 programmed upchirps + 2
sync-word upchirps + 2.25 downchirps (SFD) on the air). The monitor
watches that channel for preambles and reports each preamble's PMR.

## The statistic

For one preamble, PMR is computed exactly as in the paper:

1. Dechirp each preamble upchirp against an ideal reference (multiply
   by the conjugate ideal upchirp — the same `lora_upchirp` generator
   the bridge's ELRS detector uses, so there is one chirp convention).
2. DFT of the dechirped symbol. **The DFT is 128 points (2^SF), the
   paper's demod-domain grid.** This is deliberate: PMR's sensitivity
   to a second tone scales as 1/n_bins, so a zero-padded 16k-bin FFT
   would make a LoRa-like jammer tone invisible in the mean. With 128
   bins, PMR saturates at 10·log10(128) ≈ 21.1 dB (the paper's "bounded
   PMR" remark) and a second equal tone costs ~3 dB.
3. PMR per symbol = dominant-bin magnitude / mean spectral magnitude.
4. Preamble PMR = mean of the per-symbol PMR values (linear mean,
   then converted to dB) over the detected upchirp run.

Under a LoRa-like preamble jammer, the dechirped spectrum gains energy
outside the dominant bin, the mean rises, and PMR FALLS. A low PMR on
an otherwise present preamble is therefore *consistent with* preamble
interference. It is not proof of jamming: fading, a weak link, or an
overlapping legitimate transmission can also lower PMR.

## The floor / onset / margin framework (paper definitions)

Three quantities on one relative jammer-level axis:

- **Detection sensitivity floor L★₀.₉**: the smallest jammer level
  reaching P_D = 0.9 at P_FA = 10⁻².
- **Preamble-degradation onset L^SER₀.₀₅**: the jammer level at which
  preamble symbol-error rate rises 5 points over the jamming-free
  baseline.
- **Early-warning margin M₀.₉ = onset − floor**: a *power-domain*
  headroom in dB. It is explicitly NOT elapsed warning time. A
  positive margin means the detector trips before packets start
  degrading.

The paper's headline numbers (simulation-only, see Limits): under
strong co-channel interference (0 dB CCI), PMR reaches P_D = 0.9 at
−8.45 dB with a 6.58 dB margin; OC-SVM beat PMR in that showcase
condition (margin ≥8.13 dB); the CAE autoencoder never reached P_D =
0.9 there. Under severe Rayleigh fading PMR never reached P_D = 0.9
while CAE reached −1.53 dB. Under AWGN at SNR = 0 dB, CAE and OC-SVM
margins went negative while PMR stayed positive. No detector
dominates; conditions pick the winner.

## Rules carried from the paper (non-negotiable)

1. **PMR is a SEPARATE decision.** Score-level fusion by weight-free
   maximum rule does NOT preserve PMR's advantage — the fused floor
   follows the heavier-tailed CAE score because the bounded PMR
   statistic saturates below the fused threshold. Never max-fuse PMR
   with a learned score. This build contains no learned score at all.
2. **Sim numbers are NOT thresholds.** The paper's floors, margins,
   and AUC values are controlled simulation-domain estimates. No
   sim-derived threshold is baked into this build as a default, ever.
   Without `--pmr-threshold` the monitor is REPORT-ONLY: it logs and
   emits PMR values and never alerts.
3. **No CAE / OC-SVM in this build.** The learned detectors need a
   training pipeline and are a separate future candidate. PMR is the
   training-light statistic; that is why it was picked first.
4. **Alerts only.** PMR readings never feed the tripwire, never fuse
   into tracks, never veto anything, and never merge into the
   confidence merger. The Dart side stores them for the monitor
   section only.

## Why it runs on the SDR bridge, not the gateway

The SX1276 exposes no IQ. The monitor therefore CANNOT run on the
gateway chip. It runs in `sdr_bridge.py` (stare mode), which already
captures IQ from RTL-SDR / HackRF / Pluto / USRP / SoapySDR radios
and ships UDP JSON to Shepherd at 127.0.0.1:49161. The operator stares
at the backhaul channel (default 915.0 MHz US915; 433.0 MHz for AS433)
and the monitor watches the same channel the gateway receives on.

## Implementation

Files:

- `shepherd_field_kit/sdr_bridge/pmr_monitor.py` — the monitor
  (`PmrMonitor`), plus a recorded-IQ CLI (`python pmr_monitor.py
  capture.npy --fs 4000000`). RX-only; reads IQ or files, generates
  nothing.
- `shepherd_field_kit/sdr_bridge/sdr_bridge.py` — `--pmr` (stare-only),
  `--pmr-threshold` (optional, default unset = report-only),
  `--pmr-channel` (default 915.0, the declared backhaul channel; the
  monitor runs on the actual stare center and only warns on mismatch).
- `lib/services/radio_driver.dart` — `PmrReading` (requires
  `"experimental": true`, else the packet is rejected), `SdrDriver`
  storage + `recentPmrReadings` / `latestPmrAlert`.
- `lib/state/app_state.dart` — `pmrMonitorLines` (alerts first, then
  readings, capped at 12). Deliberately NOT wired into the merger.
- `lib/screens/evidence_sheet.dart` — "PMR MONITOR (EXPERIMENTAL)"
  section with the honesty footnote.

Detection pipeline (per stare block of 8 consecutive captures):

1. **Burst gate.** Hop energies (quarter-symbol hops); a burst is
   hops above min(20th-percentile × 6, minimum NONZERO-hop × 30).
   The min() matters: when a preamble fills most of the block, the
   median IS the signal and a median gate goes blind (found by
   probe). TWO REGIMES: sparse blocks (signal < ~80% of hops) gate
   at ~noise × 6 (~+7.6 dB); dense blocks (signal > ~80% of hops)
   have a signal 20th percentile, so the min() selects the
   minimum-hop term and the gate becomes ~noise × 30 (~+14.4 dB) —
   a preamble must clear the higher floor to be seen at all. The
   minimum is over nonzero hops (a single exactly-zero hop must not
   zero the gate). A 100% signal block yields no burst — accepted
   limit (a continuously hot channel has no quiet reference; the
   RSS-anomaly path covers it). False bursts only cost CPU, never a
   false reading (readings still need the run + SFD checks).
2. **Phase search.** Four symbol phases (0, 1/4, 1/2, 3/4) per burst
   region; grid windows step one symbol. A window joins a run when
   its PMR clears the 10 dB structural find gate AND its peak bin is
   within tolerance of the run median (for sync 0x12, the deployed
   sync word, ±2 bins — its sync chirps shift by ≤2 bins; data
   symbols typically jump further, which is what breaks payload
   runs; another sync word shifts differently and needs the
   monitor's sync_word parameter). The 10 dB gate is a DETECTION
   gate, not a jamming threshold: it is a MAGNITUDE ratio, so a
   noise-only window exceeds it with probability ~10^-32 (a 10 dB
   magnitude ratio is a 100× power ratio; the ~0.6% figure applies
   to a power ratio only and was wrong here), and a run of ≥6 plus
   bin consistency plus the SFD check makes a noise false preamble
   negligible.
3. **SFD confirmation.** The window after the run must look like a
   downchirp (downchirp PMR ≥ gate). A run of identical data symbols
   with no SFD is rejected. A run ending at the buffer end is held
   (not emitted, not discarded) until more data resolves it.
4. **Reading.** PMR averaged over the run (reported with its true
   length; nodes send 10 upchirps, edge windows may add ±1).
   Threshold set: `alert = pmr_db < threshold_db`,
   `margin_db = pmr_db - threshold_db` (negative = alerting).
   Threshold unset: `alert = false`, `margin_db = null`, always.

UDP contract (`kind: "pmr"`, all readings carry `"experimental":
true`):

```json
{"v": 1, "kind": "pmr", "radio": "rtlsdr0", "channel_mhz": 915.0,
 "experimental": true, "pmr_db": 16.0, "n_chirps": 11,
 "tone_off_hz": 37109.4, "threshold_db": null, "margin_db": null,
 "alert": false, "t": 1729123456.789}
```

`tone_off_hz` mixes the true frequency offset with the winning
phase's symbol-alignment offset (up to ±16 bins = ±15.6 kHz; a
quarter-symbol grid error alone is 32 bins). It is a COARSE channel
identifier only (own channel vs a neighbour 100 kHz away), NEVER a
CFO measurement. Sub-phase refinement to tighten it is future work.

## Honest limits

- **Simulation-only paper.** GNU Radio waveforms + channel models;
  PA nonlinearity, phase noise, quantization, front-end filtering,
  and AGC were not modeled. Operating points are simulation-domain
  estimates, not hardware thresholds.
- **SF7 / 125 kHz only.** Higher SFs are NOT shown to improve PMR
  sensitivity (its mathematical upper bound scales with
  samples-per-symbol, but that is not a measured sensitivity gain).
- **Single-jammer model.** One LoRa-like jammer at a fixed 20-sample
  offset in the first preamble symbol. Reactive variable-delay,
  frequency-selective, multi-adversary, and protocol-aware attacks are
  outside the threat model.
- **Estimated-sync loss.** The paper used true sampling-time offset
  and deterministic FFT-bin CFO compensation. This monitor searches
  4 phases (alignment within 1/8 symbol); practical estimated sync
  loses additional sensitivity versus the paper.
- **Concentration-preserving adversary defeats PMR.** A jammer
  crafted to preserve dechirp spectral concentration looks like a
  clean preamble by construction. PMR covers the LoRa-like
  preamble-injection class only.
- **Scalloping bias.** A tone between DFT bins loses up to ~3.9 dB
  of peak, and because CFO is constant across a preamble, that loss
  is a CONSTANT bias per preamble, not noise. PMR baselines must be
  derived PER LINK (per node-gateway pair), not as one global number.
  Measured on synthetic chirps: clean PMR 14.4–17.2 dB across
  rates/CFOs (math validation only, not a hardware claim).
- **One reading per burst region** (the longest run; ties broken by
  higher PMR). Dense packet bursts inside one region may
  under-report.
- **Burst-gate floor (two regimes).** Sparse blocks miss preambles
  less than ~+7.6 dB over the block noise floor; dense blocks
  (signal > ~80% of hops) miss preambles less than ~+14.4 dB over
  noise. This monitor is a strong-signal jamming watch, not a
  decoder (LoRa decodes far below this).
- **No live validation yet.** Everything below the live-test
  procedure is unproven on hardware. The synthetic test numbers
  (clean PMR 14.4–17.2 dB; equal-amplitude second train −2.7 dB;
  −8 dB second train −1.3 dB) validate the MATH and the direction of
  the response only.

## Live-test procedure (runs on Draco's hardware)

Do NOT generate jamming or interference signals for this test. All
three steps use normal traffic and opportunistic real interference.

**(a) Baseline distribution.** Run the bridge with
`--stare 915 --pmr` (or `--stare 433 --pmr --pmr-channel 433` for
AS433) during normal backhaul traffic. Collect PMR readings per node
(node identity comes from the gateway's own UDP 49160 traffic on the
same timeframe, correlated by time — the PMR monitor itself does not
identify nodes). Record, PER LINK: median PMR, 5th-percentile PMR,
and reading count. These per-link distributions ARE the baseline;
there is no global threshold to copy from anywhere. Expect clean-link
PMR in the mid-teens dB (synthetic range 14–17 dB is a rough guide,
not a target). If a link's baseline sits near or below 10 dB, that
link is already marginal (weak, faded, or interfered) — investigate
the link before trusting any threshold on it.

**(b) Comparison against existing alerts.** Run the PMR monitor
alongside the existing gateway alerts (RSS-anomaly + gap/sync-failure)
in normal operation for at least a week of traffic. Log every PMR
reading below each link's 5th percentile AND every RSS-anomaly /
gap alert, with timestamps. The comparison questions: (1) Does PMR
dip BEFORE gap alerts fire on real interference days (early-warning
behavior)? (2) Does PMR stay quiet on clean days (false-alarm rate)?
(3) Do PMR dips coincide with RSS-anomaly alerts (same events) or
cover different events (complementary coverage)? Only if (1) or (3)
answers yes, and (2) shows a tolerable false-alarm rate, is a
threshold worth setting — and then set it PER LINK at that link's
5th-percentile baseline, never as a global number.

**(c) Opportunistic real interference.** When real interference
occurs on the backhaul channel (observed via the gateway's own
missed-packet / RSS logs, or noticed in the field), preserve the SDR
capture around it (record IQ with the bridge or any SDR tool) and run
`python pmr_monitor.py <capture> --fs <rate>` over it. Compare PMR
during the event against the same link's baseline from (a). A real
interference event with a clear PMR dip is the first hardware
evidence for the monitor; a real event with NO PMR dip bounds what
the monitor can see (and should be written up as a limit, not
explained away).

**Threshold-setting rule (only after (a)–(c)).** A threshold is set
per link at that link's 5th-percentile baseline PMR, and only after
at least one real interference event (or a clear interference day in
(b)) shows PMR dipping below it while clean days stay above it.
Until then the monitor stays report-only. If no threshold is ever
justified, report-only IS the delivered state — that is a successful
outcome for an experimental monitor, not a failure.

## Out of scope (deliberate)

- CAE / OC-SVM learned detectors (need a training pipeline).
- Max-rule or any other fusion of PMR with another score.
- Gateway-chip implementation (SX1276 has no IQ path).
- Any transmit, jamming-generation, or interference-generation
  capability. This monitor is receive-only, defensive detection only.
