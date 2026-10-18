"""Tests for wpp_idp_detect.py — WPP-IDP per-preamble energy estimator.

Run:  python test_wpp_idp_detect.py      (no pytest needed; numpy only)

Contract under test: the estimator accumulates per-preamble energy
E[n], applies the WAVEFORM RULE (DSSS beacons -> all packets; OFDM ->
preamble-only, ~7 dB documented cost; data symbols are NEVER
processed), and emits wpp_idp_doppler events for Doppler lines above
the gate. The headline regression: running full-packet processing on an
OFDM capture must NOT recover the line -- this stops anyone
"improving" the chain by re-adding data symbols.
"""
import math
import sys

import numpy as np

import wpp_idp_detect as w

FS = 1_000_000
FRAME_S = 0.005      # 200 frames/s
PRE_FRAC = 0.2       # 1 ms preamble per 5 ms frame
F_DOP = 40.0         # synthetic mover Doppler (Hz, magnitude)
WINDOW = 128         # slots per estimate (0.64 s)


def synth_ofdm(seed=3, f_dop=F_DOP, echo_amp=0.35, data_on=True,
               noise_db=-20.0, dur_s=0.70):
    """Synthetic OFDM-like capture: 1 ms identical preamble bursts +
    4 ms random data symbols per 5 ms frame. The echo is a DELAYED copy
    with Doppler phase rotation -- the delay decorrelates random data
    (its cross-term becomes noise) while the identical preamble stays
    coherent, which is exactly the paper's waveform-rule physics.
    """
    rng = np.random.default_rng(seed)
    n = int(FS * dur_s)
    t = np.arange(n) / FS
    ph = (t / FRAME_S) % 1.0
    is_pre = ph < PRE_FRAC
    pre_pos = np.clip(ph / PRE_FRAC, 0.0, 1.0)
    taper = (np.sin(np.pi * pre_pos) ** 2) * is_pre
    pre = np.exp(2j * np.pi * 50e3 * t) * taper
    if data_on:
        fidx = np.floor(t / FRAME_S)
        h = np.abs(np.sin(fidx * 12.9898) * 43758.5453) % 1.0
        data = (((rng.standard_normal(n) + 1j * rng.standard_normal(n))
                 / math.sqrt(2.0)) * (0.5 + h) * (~is_pre))
    else:
        data = np.zeros(n)
    s = (pre + data).astype(np.complex64)
    if f_dop:
        s = s + (echo_amp * np.roll(s, 37)
                 * np.exp(2j * np.pi * f_dop * t)).astype(np.complex64)
    nl = 10 ** (noise_db / 20.0)
    nz = ((rng.standard_normal(n) + 1j * rng.standard_normal(n))
          / math.sqrt(2.0) * nl).astype(np.complex64)
    return (s + nz).astype(np.complex64)


def run_est(x, waveform, seed_t=3000.0, motion_state=None, **kw):
    est = w.WppIdpEstimator(waveform=waveform, window_slots=WINDOW, **kw)
    kw2 = {} if motion_state is None else {"motion_state": motion_state}
    return est.observe("r0", "2437", 2437.0, seed_t, x, FS, **kw2)


def test_ofdm_preamble_only_detects_doppler():
    # Preamble-only processing on an OFDM capture recovers the line
    # within +/-20% (the paper's qualitative result, bridge-side).
    evs = run_est(synth_ofdm(), "ofdm")
    assert len(evs) == 1, evs
    ev = evs[0]
    assert abs(ev["doppler_hz"] - F_DOP) <= 0.2 * F_DOP, ev
    assert ev["strength"] >= w.SNR_GATE_DB, ev


def test_data_symbol_inclusion_kills_detection():
    # REGRESSION (the waveform rule): full-packet processing
    # (waveform="dsss" == whole slots, data symbols included) on the
    # SAME OFDM capture must not recover the line. This is the
    # documented BNR blow-up -- including data does not add
    # sensitivity, it destroys it.
    evs = run_est(synth_ofdm(), "dsss")
    assert evs == [], f"data-symbol processing detected {evs} -- the " \
                      f"waveform rule is broken"


def test_dsss_beacons_all_packets_detect():
    # DSSS beacons (identical packets, no data) -> all packets usable.
    evs = run_est(synth_ofdm(data_on=False), "dsss")
    assert len(evs) == 1, evs
    assert abs(evs[0]["doppler_hz"] - F_DOP) <= 0.2 * F_DOP, evs[0]


def test_quiet_scene_silent():
    # Beacons present, no mover -> no line above the gate, both modes.
    for waveform in ("ofdm", "dsss"):
        evs = run_est(synth_ofdm(f_dop=0.0), waveform)
        assert evs == [], (waveform, evs)


def test_event_schema_fields():
    evs = run_est(synth_ofdm(), "ofdm")
    assert len(evs) == 1, evs
    ev = evs[0]
    for f in ("v", "kind", "radio", "band", "center_mhz", "doppler_hz",
              "strength", "t", "motion_state"):
        assert f in ev, (f, ev)
    assert ev["v"] == 1 and ev["kind"] == "wpp_idp_doppler", ev
    assert ev["band"] == "2437" and ev["radio"] == "r0", ev
    assert ev["doppler_hz"] >= 0, ev  # magnitude: sign ambiguous here
    # Language contract: a disturbance strength, never an identity.
    blob = str(ev).lower()
    assert "drone" not in blob and "confirm" not in blob, blob


def test_ofdm_mode_structurally_excludes_data_symbols():
    # The WAVEFORM RULE is enforced, not advisory: ofdm mode with a
    # full-slot fraction must raise rather than ingest data symbols.
    try:
        w.WppIdpEstimator(waveform="ofdm", preamble_frac=1.0)
    except ValueError:
        pass
    else:
        raise AssertionError("ofdm+preamble_frac=1.0 must raise")
    try:
        w.WppIdpEstimator(waveform="ofdm", preamble_frac=0.0)
    except ValueError:
        pass
    else:
        raise AssertionError("ofdm+preamble_frac=0.0 must raise")
    try:
        w.WppIdpEstimator(waveform="bogus")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown waveform must raise")
    # dsss forces whole-slot processing regardless.
    est = w.WppIdpEstimator(waveform="dsss", preamble_frac=0.2)
    assert est.preamble_frac == 1.0, est.preamble_frac


def test_preamble_only_cost_documented():
    # The ~7 dB preamble-only cost is a named constant, not lore.
    assert abs(w.OFDM_PREAMBLE_ONLY_COST_DB - 7.0) < 0.1, \
        w.OFDM_PREAMBLE_ONLY_COST_DB


def test_motion_state_carried():
    evs = run_est(synth_ofdm(), "ofdm", motion_state="moving")
    assert len(evs) == 1, evs
    assert evs[0]["motion_state"] == "moving", evs[0]
    evs = run_est(synth_ofdm(), "ofdm")
    assert evs[0]["motion_state"] == "static", evs[0]


def test_gap_reset_keeps_sweep_mode_quiet():
    # A wall-clock gap (sweep mode) resets the accumulator instead of
    # FFT-ing a gapped energy series.
    est = w.WppIdpEstimator(waveform="ofdm", window_slots=WINDOW)
    x = synth_ofdm(dur_s=0.70)
    evs1 = est.observe("r0", "2437", 2437.0, 4000.0, x, FS)
    assert len(evs1) == 1, evs1
    # Ten seconds later (a sweep revisit, not a stare): the partial
    # window is discarded, so one more capture cannot complete an
    # event from stale slots.
    evs2 = est.observe("r0", "2437", 2437.0, 4010.0, x[:20000], FS)
    assert evs2 == [], evs2


def main():
    fns = [(k, v) for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    bad = 0
    for name, fn in fns:
        try:
            fn()
            print(f"  ok {name}")
        except AssertionError as ex:
            bad += 1
            print(f" FAIL {name}: {ex}")
        except Exception as ex:  # noqa: BLE001 -- test harness
            bad += 1
            print(f" ERROR {name}: {type(ex).__name__}: {ex}")
    print(f"{len(fns) - bad}/{len(fns)} passed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
