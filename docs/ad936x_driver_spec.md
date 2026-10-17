# AD936x Spectrum-Sensor Driver Spec

**Status:** v1 implemented (bridge + in-app driver). **Scope:** receive-only
band-energy sensing. One radio reports energy per band — not direction,
range, or identity.

## Why this exists

AD936x-family SDRs (ADALM-Pluto, Ettus USRP B200/B210) are the most common
wideband receivers in the wild. Owners kept asking for Shepherd support.
But an SDR is not a mesh radio: it produces no link telemetry, so it can't
feed the tripwire directly. This driver bridges that gap by turning each
watched band into a *virtual link* whose "signal" is band energy.

## Architecture

```
┌──────────────┐  libiio / UHD   ┌──────────────────┐  UDP 127.0.0.1:49161  ┌─────────────┐
│ AD936x radio │ ── RX ONLY ──▶  │ ad936x_bridge.py │ ── JSON datagrams ──▶ │  Shepherd   │
│ Pluto / B200 │   (no TX path)  │  sweep / stare   │   band energy dBFS    │ Ad936xDriver│
└──────────────┘                 └──────────────────┘                       └──────┬──────┘
                                                                                 │ LinkSample
                                                                     virtual link│ per band
                                                                                 ▼
                                                     tripwire → alerts → event log → dashboard
                                                                          (fusion excluded:
                                                                           no geometry)
```

Two processes by necessity: Dart can't drive libiio/UHD, so the Python
bridge owns the radio and Shepherd owns the detection.

## The polarity trick

Shepherd's tripwire detects *dips*: `dip = baseline − snr`. A spectrum
sensor's signal is the opposite — an emitter *appearing* is an energy
*rise*. Rather than teaching the tripwire about rises, the driver negates:

- Bridge measures band energy in dBFS (negative, e.g. −81 quiet, −52 hot).
- Driver sets `LinkSample.snr = −energyDbfs` (+81 quiet, +52 hot).
- Tripwire computes `dip = 81 − 52 = +29 dB` — a "dip" that is really an
  energy rise, in honest dB.

Everything downstream then works unchanged: rolling-median baselines,
per-band adaptive (MAD) thresholds, baseline hold during events,
confirm-polls, CrossingEvents, size estimates (dB rise ≈ dip depth),
audible/haptic alerts, and the event log. Absolute dBFS is meaningless
across gain settings — only deltas matter, which is why the bridge pins
manual gain and never touches it again.

## Virtual links

- `fromNode`: `ad936x:<radio>` (e.g. `ad936x:pluto0`)
- `toNode`: `ad936x:band-<label>` (e.g. `ad936x:band-2437`)
- `snr`: negated band-median PSD (wideband, stable — the tripwire input)
- `noiseFrom`: negated noise-floor estimate
- `pcns`: negated per-sub-band (8) PEAK PSD — catches narrowband
  emitters (LoRa/RC tones) the median deliberately ignores; spur-sensitive,
  for investigation, not alarming

## What's deliberately excluded

Band-energy virtual links carry no geometry, so `_updateFusedTrack`
filters them out of the position solver, the shadow grid, and the track
stitcher. A hot band must never drag the fused track. Alerts, dashboard
link cards, and the event log all still fire — that path is the whole
point of the driver.

On the tracking map these nodes appear at auto-assigned positions (same
as any undiscovered node); drag them where you like or ignore them.

## Bridge details (`field_kit/ad936x_bridge/`)

- **Backends:** `pluto` (pyadi-iio), `uhd` (USRP B200/B210), `simulate`
  (scripted synthetic spectrum — verifies the whole pipeline with no
  hardware), `auto` (tries pluto, then uhd).
- **RX-only by construction.** Pluto is driven through `rx_*` attributes
  only; UHD opens an RX streamer only. There is no TX code path.
- **Sweep** (default): 433.92 / 915 / 1290 / 2437 / 5780 MHz; bands above
  the radio's ceiling are skipped with a warning (Pluto: 3.8 GHz, so the
  5.8 GHz band is Pluto-skipped). **Stare** (`--stare 2437`): parks on one
  band, gap-free, at the cost of the others.
- **DSP:** 4 MSPS, 16384-sample captures, Hann-windowed FFT, dBFS with
  full-scale sine = 0 dBFS. First capture after each retune is discarded.
- **Protocol:** UDP JSON to 127.0.0.1:49161 — `band` packets per dwell
  plus a `beacon` every 10 s so the driver (and `probe()`) knows the
  bridge is alive. `--print` dumps packets as JSON lines instead of
  sending (sandbox/CI friendly); `--sweeps N` exits after N sweeps.
- **Launcher:** `RUN_AD936X_BRIDGE.bat` — venv, deps, run. Double-click.

## Honest limits (v1)

1. One radio = energy, not direction. "2.4 GHz got hot" is the whole
   report. Direction needs dual-coherent-RX interferometry (B210) —
   planned, not v1.
2. Sweep gaps are real: a frequency hopper can slip between dwells.
   Stare mode closes the gap for one band.
3. dBFS is relative to the gain setting. Change the gain and the
   baselines must re-learn; never compare absolutes across radios.
4. Sub-band peaks are spur-sensitive by design (peak of 2048 bins).
   The tripwire's confirm-polls and adaptive thresholds are the guard
   rails; treat lone peak hits as leads, not detections.
5. USB throughput bounds the SDR: Pluto realistically sustains a few
   MSPS — fine for 20 MHz sweeps, not wideband real-time. The B210 over
   USB 3.0 is the wideband instrument.

## Setup (user path)

1. On the PC: double-click `RUN_AD936X_BRIDGE.bat --simulate` (test) or
   with `--backend pluto` / `--backend uhd` (hardware).
2. In Shepherd: Settings → add radio → **AD936X (Pluto / USRP)** —
   address prefills to `127.0.0.1:49161`.
3. Watch the dashboard: each band appears as a virtual link; scripted
   emitters in `--simulate` fire within ~40 s so the pipeline can be
   verified end to end.

## Future work (not v1)

- B210 dual-RX phase interferometry → true bearings into the LOB ingest
  (converges with the DF node Phase 2 plan).
- Multi-radio energy-gradient bearing (mesh hot-side bearing, per the
  DF node spec) once 3+ spectrum nodes are common.
- TX remains out of scope permanently — Shepherd stays defensive-only.
