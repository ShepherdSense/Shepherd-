"""Regression tests for the DSP/measurement layer of sdr_bridge.py.

Run:  python test_sdr_bridge.py        (no pytest needed; numpy only)
"""
import math
import sys
import time

import numpy as np

import sdr_bridge as b

SR = 4_000_000
N = b.CAPTURE_N
RNG = np.random.default_rng(1)


def noise(n=N, level_db=-85.0):
    lin = 10 ** (level_db / 20.0)
    return ((RNG.standard_normal(n) + 1j * RNG.standard_normal(n))
            / math.sqrt(2) * lin).astype(np.complex64)


def tone(f_hz, amp_db, n=N):
    t = np.arange(n) / SR
    return (np.exp(2j * np.pi * f_hz * t) * 10 ** (amp_db / 20.0)).astype(
        np.complex64)


def test_wideband_emitter_raises_median():
    quiet = b.band_measurement(noise(), SR, 20.0)
    hot = b.band_measurement(noise() + noise(level_db=-57.0), SR, 20.0)
    assert hot["energy"] - quiet["energy"] > 20.0, (quiet, hot)


def test_sim_backend_wideband_burst_is_visible():
    sim = b.SimBackend()
    sim.tune(2437.0, 20.0, 40)
    sim.t0 = time.time() - 5       # quiet phase
    quiet = b.band_measurement(sim.capture(N), SR, 20.0)
    sim.t0 = time.time() - 25      # burst phase
    hot = b.band_measurement(sim.capture(N), SR, 20.0)
    # Regression: the old sim emitter was a DC tone and moved the median
    # by 0.2 dB, so --simulate could never trip the energy tripwire.
    assert hot["energy"] - quiet["energy"] > 15.0, (quiet, hot)


def test_narrowband_tone_is_in_peaks_not_median_and_frequency_ordered():
    x = noise() + tone(+1.0e6, -50.0)
    m = b.band_measurement(x, SR, 4.0)
    base = b.band_measurement(noise(), SR, 4.0)
    assert abs(m["energy"] - base["energy"]) < 1.0
    assert abs(m["peak_off_mhz"] - 1.0) < 0.01
    # +1.0 MHz of a +/-1.6 MHz span -> upper half; -1.0 MHz -> lower half.
    hi = int(np.argmax(m["bins"]))
    lo = int(np.argmax(b.band_measurement(noise() + tone(-1.0e6, -50.0),
                                          SR, 4.0)["bins"]))
    assert hi >= 5 and lo <= 2, (hi, lo)   # old unshifted FFT gave 3 and 5


def test_bandwidth_is_honoured():
    # A tone at +1.5 MHz is outside a 1 MHz band and must not appear.
    x = noise() + tone(1.5e6, -50.0)
    narrow = b.band_measurement(x, SR, 1.0)
    wide = b.band_measurement(x, SR, 4.0)
    assert narrow["peak_dbfs"] < -90 < wide["peak_dbfs"]
    assert abs(narrow["span_mhz"] - 1.0) < 1e-6
    assert wide["span_mhz"] <= 0.8 * SR / 1e6 + 1e-9   # clipped, reported


def test_dc_spike_does_not_pose_as_emitter():
    x = noise() + (0.05 + 0j)      # strong DC offset
    m = b.band_measurement(x, SR, 4.0)
    assert m["peak_dbfs"] < -90, m


def test_bad_captures_are_rejected_not_reported_as_minus_120():
    assert b.band_measurement(np.array([], dtype=np.complex64), SR, 4.0) is None
    x = noise()
    x[10] = np.nan
    assert b.band_measurement(x, SR, 4.0) is None


def test_all_reported_values_are_finite_json():
    import json
    m = b.band_measurement(noise(), SR, 20.0)
    vals = [m["energy"], m["noise"], m["peak_dbfs"], *m["bins"]]
    json.dumps(vals, allow_nan=False)
    assert all(math.isfinite(v) for v in vals)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("PASS", name)
            except AssertionError as e:
                fails += 1
                print("FAIL", name, e)
    sys.exit(1 if fails else 0)
