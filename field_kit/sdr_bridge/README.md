# Shepherd SDR Bridge

Use your SDR as a Shepherd sensor. **Receive only — this bridge never
transmits, and the RTL-SDR hardware can't transmit at all.**

## What it does

The bridge sweeps (or stares at) the drone-relevant bands — 433 MHz,
915 MHz, 1.2 GHz, 2.4 GHz, 5.8 GHz — measures per-band RF energy, and
ships the readings over UDP to Shepherd. Shepherd treats each watched
band as a virtual tripwire link: an emitter *appearing* in a band looks
exactly like a link dip, so the adaptive thresholds, baseline hold,
alerts, and event log all work unchanged. See `docs/sdr_driver_spec.md`
in the repo for the full design.

## Supported hardware

| Radio | Backend | Range | Notes |
|---|---|---|---|
| RTL-SDR (RTL2832U) | `rtlsdr` (pyrtlsdr) | ~24 MHz–1.75 GHz | The $30 classic; RX-only hardware. Covers 433/915, not 2.4/5.8 |
| ADALM-Pluto | `pluto` (pyadi-iio) | 70 MHz–3.8 GHz | 5.8 GHz band auto-skipped |
| Ettus USRP B200 / B210 | `uhd` | 70 MHz–6 GHz | B210's dual coherent RX is the future DF path |
| HackRF One | `soapy --soapy-driver hackrf` | 1 MHz–6 GHz | Covers every drone band |
| Airspy R2 / Mini | `soapy --soapy-driver airspy` | 24 MHz–1.8 GHz | Excellent RX performance |
| LimeSDR / SDRplay / bladeRF | `soapy --soapy-driver lime/...` | varies | Whatever SoapySDR modules you have |

`--backend auto` (the default) tries pluto → uhd → rtlsdr → any
enumerated SoapySDR device, first working one wins.

## Band plans

`--plan <name>` sweeps a curated band set instead of the default five.
Explicit `--bands` or `--stare` always win over `--plan`.

| Plan | Bands | Why these |
|---|---|---|
| `fpv` | 1290/8, 2437/20, 5780/20 | The full FPV-drone RF footprint: 1.3 GHz video, 2.4 GHz ELRS control link, 5.8 GHz video downlink |
| `dji` | 2437/20, 5780/20 | DJI OcuSync/O4: control link lives in 2.4 GHz ISM, video downlink in 5 GHz ISM |
| `longrange` | 433.92/1, 868/1, 915/2 | Sub-GHz long-range control: 433 LoRa, 868 (EU SRD band), 915 (US ISM) — Crossfire / ELRS-900 country |
| `lora` | 433.92/1, 868/1, 915/2 | Pure sub-GHz LoRa/Meshtastic watch (same bands as `longrange`; the name says what you're looking for) |

Example: `RUN_SDR_BRIDGE.bat --simulate --plan fpv`.

## Quick start

1. Double-click **`RUN_SDR_BRIDGE.bat`**. First run creates a venv and
   installs numpy.
2. Hardware-free test: `RUN_SDR_BRIDGE.bat --simulate` — synthetic
   spectrum with scripted emitters, so you can watch Shepherd react.
3. RTL-SDR: `pip install pyrtlsdr` in the venv (Windows: also run Zadig
   once to install WinUSB for the dongle), then
   `RUN_SDR_BRIDGE.bat --backend rtlsdr`.
4. Pluto: `pip install pyadi-iio`, then
   `RUN_SDR_BRIDGE.bat --backend pluto --pluto-uri ip:192.168.2.1`
   (use `usb:` for USB-connected Plutos).
5. USRP: `pip install uhd`, then
   `RUN_SDR_BRIDGE.bat --backend uhd --uhd-args "type=b200"`.
6. HackRF/Airspy/etc: install PothosSDR (Windows), then
   `RUN_SDR_BRIDGE.bat --backend soapy --soapy-driver hackrf`.
7. In Shepherd: Settings → add radio → driver **SDR**,
   address `127.0.0.1:49161` (prefilled).

## What each band packet means

- `energy_dbfs` — **median** power across the band. The tripwire input; it
  rises for *wideband* emitters (FPV video, Wi-Fi) and ignores narrow tones.
- `noise_dbfs` — **adaptive noise floor**: the 20th percentile of the
  band's spectrum, recomputed from every capture (detector design after
  Șorecău et al. 2025, defensive detection only). The signature scorer's
  "hot" threshold is this floor + 12 dB, so the threshold tracks a
  rising/drifting floor instead of false-alarming on it. *Behaviour
  change:* earlier builds used the 10th percentile — on a flat floor the
  new estimate reads ~0.8 dB higher, so `noise_dbfs` values and hot
  thresholds sit ~0.8 dB higher than before, and the ELRS chirp
  detector's CPU gate (peak − noise) is ~0.8 dB stricter. The packet
  format is unchanged. The 20th percentile is also far more robust when
  10–20% of a band sits in a fade or filter notch, where the old estimate
  collapsed toward the notch and dragged the threshold down with it
  (past ~20% notched, any percentile estimator lands in the notch).
- `bins_dbfs` — 8 sub-bands, **low → high frequency**, peak power each.
  Catches narrowband emitters (LoRa, RC links) the median ignores; more
  spur-sensitive, so it is an investigation aid, not an alarm source.
- `peak_mhz` / `peak_dbfs` — frequency and level of the strongest bin
  (DC spike masked). Tells you *where in the band* to look. It is a
  frequency, not a direction.
- `span_mhz` — the width actually measured. Only the central 80% of the
  radio's sample rate is trusted (the edges are filter roll-off), so a
  20 MHz band on a 4 MS/s capture reports `span_mhz` ≈ 3.2. Raise the
  sample rate (`--soapy-rate`) on radios that support it for wider coverage.
- `sig_hint` — emitter *signature* hint, or `null`. One of:
  - `"fhss-2g4"` — 2.4 GHz band, energy hopping between sub-bands
    (ELRS-style frequency-hopping control link)
  - `"fhss-900m"` — 900 MHz band, same hopping behaviour
    (ELRS-900 / Crossfire-style)
  - `"ofdm-5g"` — 5 GHz band, energy up across most sub-bands at once
    with the median lifted (DJI O4-style wideband OFDM video)
  - `"tone-5g8"` — 5.8 GHz band, one sub-band persistently hot
    (analog-FPV-style video carrier)
  - `null` — nothing signature-like (or not enough observations yet)
- Measurements are Welch-averaged over several FFT segments per capture;
  `--dwell N` averages N captures per band per sweep.
- A capture that fails or comes back short is **dropped, not reported**
  (the beacon's `dropped` counter says how many). A fake "-120 dBFS"
  reading would otherwise poison the baseline and cause a phantom alert
  on the next good read.

## Rules that keep the sensing honest

- **Manual gain, fixed.** AGC hides the energy changes you're detecting.
  The bridge sets manual gain and never touches it again. (RTL-SDR gain
  snaps to the nearest valid tuner step and tells you.)
- **One radio = energy, not direction.** A single SDR tells you a band
  got hot, not where the emitter is. Direction needs the dual-RX
  interferometry path (planned, not in v1).
- **Sweep gaps are real.** A frequency hopper can slip between dwells.
  `--stare 2437` parks on one band for gap-free watch of the 2.4 GHz ISM
  band at the cost of the others.
- **dBFS is relative.** Only deltas from the rolling baseline matter —
  never compare absolute numbers across gain settings or radios.
- **Know your ceiling.** The bridge skips bands above your radio's max
  frequency and tells you. An RTL-SDR will never see 2.4 GHz — that's
  physics, not a bug.
- **Signatures are not identities.** `sig_hint` says "something is
  frequency-hopping the way ELRS control links hop" — never "this is an
  ELRS drone", and never a drone claim of any kind. A hint needs several
  observations of the band (a few seconds at least); the OFDM hint also
  needs a quiet baseline the bridge has actually seen, so a burst
  already active at startup reads as `null` until the bridge learns
  calm. Additive field: older Shepherd builds ignore it.
