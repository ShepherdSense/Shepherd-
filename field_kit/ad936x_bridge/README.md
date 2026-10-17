# Shepherd AD936x Bridge

Use your AD936x-family SDR as a Shepherd sensor. **Receive only — this bridge
never transmits.**

## What it does

The bridge sweeps (or stares at) the drone-relevant bands — 433 MHz, 915 MHz,
1.2 GHz, 2.4 GHz, 5.8 GHz — measures per-band RF energy, and ships the
readings over UDP to Shepherd. Shepherd treats each watched band as a
virtual tripwire link: an emitter *appearing* in a band looks exactly like a
link dip, so the adaptive thresholds, baseline hold, alerts, and event log
all work unchanged. See `docs/ad936x_driver_spec.md` in the repo for the
full design.

## Supported hardware

| Radio | Chip | Backend | Notes |
|---|---|---|---|
| ADALM-Pluto | AD9363 | `pluto` (pyadi-iio) | 70 MHz–3.8 GHz official; 5.8 GHz band auto-skipped |
| Ettus USRP B200 | AD9364 | `uhd` | 70 MHz–6 GHz, USB 3.0 |
| Ettus USRP B210 | AD9361 | `uhd` | 70 MHz–6 GHz, dual coherent RX (future DF work) |

## Quick start

1. Double-click **`RUN_AD936X_BRIDGE.bat`**. First run creates a venv and
   installs numpy.
2. For a hardware-free test: `RUN_AD936X_BRIDGE.bat --simulate` — synthetic
   spectrum with scripted emitters, so you can watch Shepherd react.
3. Pluto: `pip install pyadi-iio` in the venv, then
   `RUN_AD936X_BRIDGE.bat --backend pluto --pluto-uri ip:192.168.2.1`
   (use `usb:` for USB-connected Plutos).
4. USRP: `pip install uhd`, then
   `RUN_AD936X_BRIDGE.bat --backend uhd --uhd-args "type=b200"`.
5. In Shepherd: Settings → add radio → driver **AD936X (Pluto / USRP)**,
   address `127.0.0.1:49161` (prefilled).

## Rules that keep the sensing honest

- **Manual gain, fixed.** AGC hides the energy changes you're detecting.
  The bridge sets manual gain and never touches it again.
- **One radio = energy, not direction.** A single Pluto/B200 tells you a
  band got hot, not where the emitter is. Direction needs the dual-RX B210
  interferometry path (planned, not in v1).
- **Sweep gaps are real.** A frequency hopper can slip between dwells.
  `--stare 2437` parks on one band for gap-free watch of the 2.4 GHz ISM
  band at the cost of the others.
- **dBFS is relative.** Only deltas from the rolling baseline matter —
  never compare absolute numbers across gain settings or radios.
