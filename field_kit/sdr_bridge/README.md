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
