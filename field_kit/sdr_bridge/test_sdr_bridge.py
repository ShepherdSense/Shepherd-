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
    sim.t0 = time.time() - 5       # hopper phase (narrow: median stays quiet)
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


def test_plan_presets():
    assert set(b.PLANS) == {"fpv", "dji", "longrange", "lora"}
    assert b.PLANS["fpv"] == [("1290", 1290.0, 8.0),
                              ("2437", 2437.0, 20.0),
                              ("5780", 5780.0, 20.0)]
    assert b.PLANS["dji"] == [("2437", 2437.0, 20.0),
                              ("5780", 5780.0, 20.0)]
    assert b.PLANS["longrange"] == [("433", 433.92, 1.0),
                                    ("868", 868.0, 1.0),
                                    ("915", 915.0, 2.0)]
    assert b.PLANS["lora"] == [("433", 433.92, 1.0),
                               ("868", 868.0, 1.0),
                               ("915", 915.0, 2.0)]


def _sig_hint(center, hots_list, energy=-80.0, noise=-85.0, t0=1000.0):
    """Feed synthetic per-observation hot-bin lists through SigHistory."""
    sig = b.SigHistory(window_s=30.0, min_obs=3)
    hint = None
    for i, hot in enumerate(hots_list):
        bins = [noise + 2.0] * 8
        for k in hot:
            bins[k] = noise + 25.0
        hint = sig.observe("x", center, t0 + i * 2.0, bins, energy, noise)
    return hint


def test_sig_hint_null_until_enough_observations():
    # Hopping pattern, but only 2 observations (< min_obs=3).
    assert _sig_hint(2437.0, [[0], [5]]) is None


def test_sig_hint_null_on_quiet():
    assert _sig_hint(2437.0, [[]] * 5) is None
    assert _sig_hint(5780.0, [[]] * 5, energy=-80.0) is None


def test_sig_hint_fhss_2g4():
    hint = _sig_hint(2437.0, [[0], [3], [6], [1], [4]])
    assert hint == "fhss-2g4", hint


def test_sig_hint_fhss_900m():
    hint = _sig_hint(915.0, [[0], [3], [6], [1], [4]])
    assert hint == "fhss-900m", hint


def test_sig_hint_ofdm_5g():
    # All sub-bands hot at once AND the median lifted: wideband OFDM.
    hint = _sig_hint(5780.0, [list(range(8))] * 3, energy=-60.0)
    assert hint == "ofdm-5g", hint


def test_sig_hint_tone_5g8():
    # One sub-band persistently hot in the 5.8 GHz video band.
    hint = _sig_hint(5780.0, [[5]] * 4)
    assert hint == "tone-5g8", hint


def test_sig_hint_null_for_static_tone_on_2g4():
    # A static tone is not frequency hopping, whatever the band.
    assert _sig_hint(2437.0, [[2]] * 4) is None


def test_sig_hint_null_for_broadband_noise_on_2g4():
    # All sub-bands always hot = broadband noise, not hopping.
    assert _sig_hint(2437.0, [list(range(8))] * 3, energy=-60.0) is None


def test_sig_hint_null_outside_known_band_families():
    # Hopping on 433 MHz matches no known signature vocabulary.
    assert _sig_hint(433.92, [[0], [3], [6], [1]]) is None


def test_sig_hint_ofdm_needs_quiet_reference():
    # Honest limit: a burst already active at startup has no quiet
    # reference to recognize the lift against -- null, not a guess.
    sig = b.SigHistory(window_s=30.0, min_obs=3)
    hint = None
    for i in range(3):
        bins = [-63.0] * 8      # burst-level everywhere, from the start
        hint = sig.observe("x", 5780.0, 1000.0 + i * 2.0, bins,
                           energy=-63.0, noise=-65.0)
    assert hint is None, hint


def test_sim_hopper_produces_fhss_hint():
    # End to end: the sim's 2.4 GHz hopper drives the detector.
    # Fresh sim starts inside the hop window; hop slots advance per
    # capture, so no clock games are needed.
    sim = b.SimBackend()
    sim.tune(2437.0, 20.0, 40)
    sig = b.SigHistory(window_s=120.0, min_obs=3)
    hint = None
    base = time.time()
    for i in range(4):
        m = b.band_measurement(sim.capture(N), SR, 20.0)
        assert m is not None
        hint = sig.observe("2437", 2437.0, base + i * 2.0,
                           m["bins"], m["energy"], m["noise"])
    assert hint == "fhss-2g4", hint


def test_sim_ofdm_burst_produces_ofdm_hint():
    # End to end: the sim's 5.8 GHz OFDM burst drives the detector.
    # The first two observations are quiet (the detector needs a calm
    # reference); the burst then arrives.
    sim = b.SimBackend()
    sim.tune(5780.0, 20.0, 40)
    sig = b.SigHistory(window_s=120.0, min_obs=3)
    hint = None
    base = time.time()
    for i, el in enumerate([100.0, 101.0, 5.0, 6.0]):
        sim.t0 = base - el
        m = b.band_measurement(sim.capture(N), SR, 20.0)
        assert m is not None
        hint = sig.observe("5780", 5780.0, base + i * 2.0,
                           m["bins"], m["energy"], m["noise"])
    assert hint == "ofdm-5g", hint


def test_sig_hint_ofdm_5g_survives_burst_past_window():
    # M3 regression: a burst outliving the rolling window must not
    # purge its own quiet reference and self-extinguish mid-burst.
    # Tiny 1 s window + real sleeps keeps the test fast; bookkeeping
    # runs on the monotonic clock, so the sleeps drive the purge.
    sig = b.SigHistory(window_s=1.0, min_obs=3)
    hint = None

    def feed(burst):
        nonlocal hint
        if burst:
            bins = [-40.0] * 8          # burst: every sub-band lifted,
            energy, noise = -60.0, -65.0  # median AND floor up
        else:
            bins = [-83.0] * 8
            energy, noise = -80.0, -85.0
        hint = sig.observe("x", 5780.0, time.time(), bins, energy, noise)

    for _ in range(3):                  # quiet reference
        feed(False)
        time.sleep(0.15)
    for _ in range(6):                  # burst arrives
        feed(True)
        time.sleep(0.15)
    assert hint == "ofdm-5g", hint
    for _ in range(6):                  # burst outlives the 1 s window:
        feed(True)                      # the quiet reference is gone
        time.sleep(0.15)
    assert hint == "ofdm-5g", hint       # without the latch this is None
    for _ in range(8):                  # burst ends: latch must release
        feed(False)
        time.sleep(0.15)
    assert hint is None, hint


def test_sim_5780_burst_fires_when_staring_off_center():
    # M14 regression: the 5780 OFDM gate keyed on the exact float
    # 5780.0, so --stare 5780.5 entered the band branch but the burst
    # never appeared. The gate now reads a MHz-normalized band key.
    sim = b.SimBackend()
    sim.tune(5780.5, 20.0, 40)
    sim.t0 = time.time() - 101.0       # first capture: quiet, primes gate
    quiet = b.band_measurement(sim.capture(N), SR, 20.0)
    assert quiet is not None
    sim.t0 = time.time() - 5.0         # burst window
    hot = b.band_measurement(sim.capture(N), SR, 20.0)
    assert hot is not None
    assert hot["energy"] - quiet["energy"] > 15.0, (quiet, hot)


# ------------------------------------------- percentile-adaptive floor
# Sorecău et al. 2025 (DOI 10.2478/kbo-2025-0093) detector design,
# defensive detection only: noise floor = 20th percentile of the
# in-band PSD, hot threshold = floor + SIG_HOT_DB, recomputed from
# every capture (see NOISE_FLOOR_PCT in sdr_bridge.py). Replaces the
# old 10th-percentile floor.

def test_noise_floor_is_20th_percentile():
    # The estimator IS the 20th percentile, and the constant pins it.
    assert b.NOISE_FLOOR_PCT == 20.0
    ps = np.linspace(-100.0, -60.0, 401)
    assert abs(b.noise_floor_dbfs(ps)
               - float(np.percentile(ps, 20))) < 1e-9
    assert b.noise_floor_dbfs(ps) > float(np.percentile(ps, 10))


def test_noise_floor_old_vs_new_on_flat_and_notched_spectra():
    # Direct old (10th pct) vs new (20th pct) comparison on synthetic
    # PSD arrays (seeded, deterministic).
    rng = np.random.default_rng(7)
    flat = rng.normal(-85.0, 0.8, size=20000)
    old_flat = float(np.percentile(flat, 10))
    new_flat = b.noise_floor_dbfs(flat)
    # Flat floor: the two estimates are close (0.35 dB on this array)
    # and the new one sits just under the median -- on a quiet band
    # the adaptive threshold behaves ~like the old static expectation.
    assert 0.0 < new_flat - old_flat < 1.5, (old_flat, new_flat)
    assert abs(new_flat - float(np.median(flat))) < 1.5
    # Notched floor: 12% of bins faded 12 dB (filter notch / fade).
    # The 10th percentile collapses into the notch and under-reads
    # the true floor; the 20th stays on the true floor. 5% genuine
    # occupancy must not set the floor either way.
    notched = flat.copy()
    idx = rng.choice(notched.size, size=int(0.12 * notched.size),
                     replace=False)
    notched[idx] -= 12.0
    sig_idx = rng.choice(notched.size, size=int(0.05 * notched.size),
                         replace=False)
    notched[sig_idx] = -60.0
    old_n = float(np.percentile(notched, 10))
    new_n = b.noise_floor_dbfs(notched)
    assert new_n - old_n > 5.0, (old_n, new_n)      # measured ~10 dB
    assert abs(new_n - (-85.0)) < 1.5, new_n        # measured ~1.0 dB
    # Consequence: with the old floor the hot threshold (floor +
    # SIG_HOT_DB) lands within ~1 dB of the band's own median, so
    # plain noise peaks would read "hot" constantly; with the new
    # floor it clears the median by ~SIG_HOT_DB.
    med = float(np.median(notched))
    assert old_n + b.SIG_HOT_DB - med < 3.0, (old_n, med)
    assert new_n + b.SIG_HOT_DB - med > 8.0, (new_n, med)


def test_adaptive_floor_quiet_flat_no_spurious_fhss():
    # (a) Quiet flat floor, end to end: repeated pure-noise captures
    # through band_measurement + SigHistory never produce an FHSS
    # hint, and no sub-band peak ever comes near floor + SIG_HOT_DB
    # (worst AWGN excursion measured ~6.7 dB against this floor).
    rng = np.random.default_rng(3)
    sig = b.SigHistory(window_s=120.0, min_obs=3)
    hint = "unset"
    for i in range(6):
        x = ((rng.standard_normal(N) + 1j * rng.standard_normal(N))
             / math.sqrt(2) * 10 ** (-85.0 / 20.0)).astype(np.complex64)
        m = b.band_measurement(x, SR, 20.0)
        assert m is not None
        # Measurement keys unchanged (UDP packet stays byte-compatible
        # in structure; only the noise VALUE's estimator changed).
        assert set(m) == {"energy", "noise", "bins", "peak_off_mhz",
                          "peak_dbfs", "span_mhz"}, set(m)
        assert max(m["bins"]) - m["noise"] < b.SIG_HOT_DB, m
        hint = sig.observe("2437", 2437.0, 1000.0 + i * 2.0,
                           m["bins"], m["energy"], m["noise"])
    assert hint is None, hint


def test_adaptive_floor_tracks_rising_floor_no_false_fhss():
    # (b) Rising floor: the whole band climbs 15 dB across the
    # observations (front end warming up / interference rising). The
    # bins are sub-band PEAKS: they ride the floor with only the usual
    # few-dB noise excursion and a rotating slightly-highest sub-band
    # -- ordinary noise, not hopping.
    floors = [-85.0 + 3.0 * i for i in range(6)]   # -85 -> -70

    def obs_bins(fl, i):
        bins = [fl + 2.0] * 8
        bins[i % 8] = fl + 6.0       # rotating noise peak, < SIG_HOT_DB
        return bins

    # Adaptive path (what the scorer does now): each observation is
    # judged against its own contemporaneous floor -> nothing is ever
    # hot -> no FHSS call, however far the floor has drifted.
    sig = b.SigHistory(window_s=120.0, min_obs=3)
    hint = None
    for i, fl in enumerate(floors):
        hint = sig.observe("x", 2437.0, 1000.0 + i * 2.0,
                           obs_bins(fl, i), fl + 1.0, fl)
    assert hint is None, hint
    # Counterfactual fixed threshold: freeze the floor at its
    # starting value (the failure mode adaptive thresholding exists
    # to prevent). The SAME bins late in the rise sit > SIG_HOT_DB
    # over the frozen floor in rotating sub-bands and the scorer
    # calls it FHSS -- proof the scenario discriminates, and that the
    # per-capture adaptation is what saves it.
    sig_fixed = b.SigHistory(window_s=120.0, min_obs=3)
    hint_fixed = None
    for i, fl in enumerate(floors):
        hint_fixed = sig_fixed.observe("x", 2437.0, 1000.0 + i * 2.0,
                                       obs_bins(fl, i), fl + 1.0,
                                       floors[0])
    assert hint_fixed == "fhss-2g4", hint_fixed


def test_adaptive_floor_end_to_end_rising_capture_levels():
    # (b, end to end) Real captures whose noise level rises 15 dB:
    # band_measurement's floor estimate tracks the rise while the
    # peak-over-floor margin stays at its quiet value -- the scorer
    # sees nothing new to call hot.
    rng = np.random.default_rng(11)
    margins, floors = [], []
    for lvl in (-85.0, -78.0, -70.0):
        x = ((rng.standard_normal(N) + 1j * rng.standard_normal(N))
             / math.sqrt(2) * 10 ** (lvl / 20.0)).astype(np.complex64)
        m = b.band_measurement(x, SR, 20.0)
        assert m is not None
        floors.append(m["noise"])
        margins.append(max(m["bins"]) - m["noise"])
    assert floors[-1] - floors[0] > 12.0, floors   # tracked the rise
    assert all(mg < b.SIG_HOT_DB for mg in margins), margins


def test_fhss_hopper_still_detected_over_adaptive_floor():
    # (c) FHSS hopper over the floor, end to end at capture level: a
    # strong narrowband tone hopping between sub-bands across
    # captures is still called fhss-2g4 under the 20th-percentile
    # floor. The hop peaks sit ~68 dB over the floor, so the ~0.8 dB
    # threshold rise from the percentile change cannot hide them;
    # detection is floor-relative, not absolute.
    sig = b.SigHistory(window_s=120.0, min_obs=3)
    hint = None
    for i, off_mhz in enumerate([-1.4, -0.2, 1.0, -1.0, 0.6]):
        x = noise() + tone(off_mhz * 1e6, -50.0)
        m = b.band_measurement(x, SR, 20.0)
        assert m is not None
        assert max(m["bins"]) - m["noise"] > b.SIG_HOT_DB + 10.0, m
        hint = sig.observe("2437", 2437.0, 1000.0 + i * 2.0,
                           m["bins"], m["energy"], m["noise"])
    assert hint == "fhss-2g4", hint
    # Same pattern riding on a floor 15 dB higher (drifted band):
    # floor-relative scoring calls it identically.
    hint = _sig_hint(2437.0, [[0], [3], [6], [1], [4]],
                     energy=-68.0, noise=-70.0)
    assert hint == "fhss-2g4", hint


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
