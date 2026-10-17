# Shepherd passive-radar prototype (RX-ONLY)

A receive-only radar: it never transmits anything. One antenna listens to a
broadcast illuminator (FM radio, DVB-T/DAB TV, LTE) directly — the *reference*
channel. A second antenna listens for that same signal reflected off a moving
target — the *surveillance* channel. The cross-ambiguity function
(delay × Doppler) of the two channels makes movers pop out of clutter, and
CFAR detection reports them as **bistatic range** (c × delay) and **Doppler
velocity**. This is the same passive coherent location (PCL) principle used
by published drone-detection research.

## Files

- `passive_radar.py` — the prototype. `--demo` runs a fully synthetic scene
  (DVB-T-like OFDM illuminator, one moving target, ground clutter,
  direct-path breakthrough, noise); `--ref/--surv` processes real captures.
  Needs only numpy + scipy.
- `b210_capture.py` — dual-RX capture for the USRP B210 (needs the `uhd`
  package + hardware). RX streams only; there is no TX code path anywhere.

## Quick start (no hardware)

```bash
pip install numpy scipy
python passive_radar.py --demo
```

Expected output: one detection at ~3,747 m bistatic range, +150 Hz Doppler,
with `RESULT: PASS`.

With a B210 and a nearby broadcast tower:

```bash
pip install uhd numpy
python b210_capture.py --freq 600e6 --duration 10   # CH0 at tower, CH1 at sky
python passive_radar.py --ref capture_ref.npy --surv capture_surv.npy \
    --fs 2000000 --fc 600e6
```

## Honest scope — read before expecting anything

- **Best published drone result: ~1,600 m bistatic range against a DJI
  Matrice M210**, using an LTE network as illuminator (REPORTED — Fraunhofer
  FKIE 2025, via a single secondary source; the primary paper was not
  independently re-verified here).
- **Vendor brochures exceed the measured literature by roughly two orders of
  magnitude** (REPORTED, same assessment). Treat any "we see drones at
  100 km" marketing as unproven until a paper shows it.
- **It needs a strong local illuminator.** PCL works near cities and
  broadcast towers and poorly in EM-quiet rural areas (CONFIRMED — this is
  basic link-budget physics: no illumination, no echo).
- **Small FPV quads are harder than a Matrice.** Radar cross-section scales
  with size and materials; a 250 g carbon quad returns far less than a
  5 kg Matrice (CONFIRMED physics).
- **This prototype is a demo, not a capability.** The synthetic scene is
  deliberately kind (strong-ish echo, clean reference). Real captures need
  longer integration, better direct-signal cancellation, and real clutter —
  weeks of DSP work, not an afternoon.
- **Dual coherent RX is mandatory.** The B210's two channels share one LO,
  which is what makes them phase-coherent. A single Pluto or RTL-SDR cannot
  do passive radar (CONFIRMED — one channel can't separate reference from
  surveillance).

## How it maps to Shepherd

If this ever matures, the natural integration is a new event type
(`passive_radar` with bistatic range + Doppler) feeding Shepherd's existing
tripwire/alert pipeline — the app layer barely changes. It stays
receive-only, inside Shepherd's defensive-only boundary.
