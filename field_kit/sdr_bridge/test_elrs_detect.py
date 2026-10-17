"""Tests for elrs_detect.py — ELRS Gemini signature DSP.

Run:  python test_elrs_detect.py        (no pytest needed; numpy only)

Honesty contract under test: the detector finds LoRa chirp trains and
scores dual-frequency coincidence. It never claims identity — there is
no "is_elrs()" anywhere, only trains and scores.
"""
import math
import sys

import numpy as np

import elrs_detect as e

SR = 4_000_000
RNG = np.random.default_rng(11)


def noise(n, level_db=-85.0):
    lin = 10 ** (level_db / 20.0)
    return ((RNG.standard_normal(n) + 1j * RNG.standard_normal(n))
            / math.sqrt(2) * lin).astype(np.complex64)


def chirp_train(f_off_hz, sf=5, bw=812_500.0, fs=SR, n_chirps=6,
                level_db=-60.0):
    """n_chirps back-to-back ideal upchirps at f_off_hz, + noise."""
    up = e.lora_upchirp(sf, bw, fs)
    sig = np.tile(up, n_chirps)
    t = np.arange(len(sig)) / fs
    sig = sig * np.exp(2j * np.pi * f_off_hz * t)
    amp = 10 ** (level_db / 20.0)
    n = len(sig) + 4096
    x = noise(n, -85.0)
    start = 2048
    x[start:start + len(sig)] += (sig * amp).astype(np.complex64)
    return x


def test_synth_chirp_train_is_detected():
    x = chirp_train(300e3)
    trains = e.detect_chirp_trains(x, SR)
    assert len(trains) >= 1, trains
    best = max(trains, key=lambda d: d["snr_db"])
    assert abs(best["freq_off_hz"] - 300e3) < 30e3, best
    assert best["sf"] == 5 and best["bw_hz"] == 812_500.0, best


def test_noise_only_produces_no_trains():
    x = noise(16384)
    assert e.detect_chirp_trains(x, SR) == []


def test_static_tone_is_not_a_chirp_train():
    # A plain carrier must never fake a LoRa preamble: after dechirp a
    # tone smears across bins instead of peaking.
    t = np.arange(16384) / SR
    x = (noise(16384)
         + (np.exp(2j * np.pi * 500e3 * t) * 10 ** (-50 / 20))
           .astype(np.complex64))
    assert e.detect_chirp_trains(x, SR) == []


def test_fsk_bursts_are_not_lora():
    # FLRC (ELRS 500/333 Hz modes) is coherent FSK, not LoRa: two
    # alternating tones must not light up the chirp detector. This is
    # the documented FLRC gap — the detector stays silent rather than
    # guessing.
    t = np.arange(16384) / SR
    sym = (np.arange(16384) // 64) % 2
    f = np.where(sym == 0, 200e3, -200e3)
    phase = 2 * np.pi * np.cumsum(f) / SR
    x = (noise(16384)
         + (np.exp(1j * phase) * 10 ** (-50 / 20)).astype(np.complex64))
    assert e.detect_chirp_trains(x, SR) == []


def _pair(t0=1000.0, fa=2441.0, fb=2481.0, dur=0.05):
    """Two fully overlapping trains (t0_abs_s, dur_s, freq_mhz)."""
    return [(t0, dur, fa), (t0, dur, fb)]


def test_gemini_scorer_rises_with_coincident_trains():
    sc = e.GeminiScorer()
    t = 1000.0
    scores = []
    for k in range(6):
        tk = t + k * 2.0
        mode, s = sc.observe(tk, _pair(t0=tk))  # 40 MHz apart
        scores.append(s)
    assert mode == "gemini-2g4", mode
    assert scores[-1] > scores[0] >= 0.25, scores
    assert scores[-1] <= 1.0, scores
    assert sc.obs == 6


def test_gemini_scorer_rejects_sequential_hopper():
    # REGRESSION (reviewer A, was BLOCKING): a single FHSS emitter
    # hopping -20 MHz -> +20 MHz SEQUENTIALLY (trains never overlap in
    # time) must NOT score as gemini-2g4, however Gemini-like the
    # frequency separation. The old code scored this 0.48.
    sc = e.GeminiScorer()
    for k in range(8):
        t = 1000.0 + k * 2.0
        trains = [(t, 0.05, 2421.0), (t + 0.05, 0.05, 2461.0)]
        mode, s = sc.observe(t, trains)
    assert mode is None and s == 0.0 and sc.obs == 0, (mode, s, sc.obs)


def test_gemini_scorer_accepts_overlapping_trains():
    # 60% overlap counts (>= 50% of the shorter train); pure
    # edge-touching from window quantization does not.
    sc = e.GeminiScorer()
    t = 1000.0
    trains = [(t, 0.10, 2441.0), (t + 0.04, 0.10, 2481.0)]
    mode, s = sc.observe(t, trains)
    assert mode == "gemini-2g4" and s == 0.25, (mode, s)


def test_gemini_scorer_band_aware_labeling():
    # Two sub-GHz trains 41 MHz apart match the 2.4 GHz separation
    # numerically but must NOT be labeled gemini-2g4.
    sc = e.GeminiScorer()
    t = 1000.0
    mode, s = sc.observe(t, [(t, 0.05, 900.0), (t, 0.05, 941.0)])
    assert mode is None and s == 0.0, (mode, s)
    # The real 900 MHz separation scores under its own label.
    sc2 = e.GeminiScorer()
    mode, s = sc2.observe(t, [(t, 0.05, 905.0), (t, 0.05, 915.0)])
    assert mode == "gemini-900m", (mode, s)


def test_gemini_scorer_ignores_stale_timestamps():
    # Non-monotonic t: never add score on a stale/duplicate timestamp.
    sc = e.GeminiScorer()
    t = 1000.0
    sc.observe(t, _pair(t0=t))
    s1 = sc.score
    mode, s2 = sc.observe(t, _pair(t0=t))
    assert s2 == s1, (s1, s2)


def test_gemini_scorer_ignores_single_band_trains():
    sc = e.GeminiScorer()
    for k in range(6):
        t = 1000.0 + k * 2.0
        mode, s = sc.observe(t, [(t, 0.05, 2441.0)])
    assert mode is None and s == 0.0 and sc.obs == 0, (mode, s)


def test_gemini_scorer_ignores_wrong_separation():
    sc = e.GeminiScorer()
    t = 1000.0
    mode, s = sc.observe(t, [(t, 0.05, 2441.0), (t, 0.05, 2446.0)])
    assert mode is None and s == 0.0, (mode, s)  # 5 MHz: not Gemini


def test_gemini_score_decays_without_coincidence():
    sc = e.GeminiScorer()
    t = 1000.0
    sc.observe(t, _pair(t0=t))
    s1 = sc.score
    _, s2 = sc.observe(t + 120.0, [(t + 120.0, 0.05, 2441.0)])
    assert 0 <= s2 < s1, (s1, s2)  # 2 min later, no pair


def _meas(peak_dbfs, noise_dbfs=-85.0):
    return {"peak_dbfs": peak_dbfs, "noise": noise_dbfs}


def test_detector_emits_chirp_event_and_throttles():
    d = e.ElrsDetector()
    x = chirp_train(-400e3)
    c1, s1 = d.observe("r0", "2437", 2437.0, 2000.0, x, SR,
                       _meas(-55.0))
    assert len(c1) == 1, (c1, s1)
    ev = c1[0]
    assert ev["kind"] == "elrs_chirp" and ev["band"] == "2437"
    assert abs(ev["freq_mhz"] - (2437.0 - 0.4)) < 0.05, ev
    # Immediate second observe: throttled, no new chirp event.
    c2, _ = d.observe("r0", "2437", 2437.0, 2000.5, x, SR, _meas(-55.0))
    assert c2 == [], c2
    # After the throttle gap: emits again.
    c3, _ = d.observe("r0", "2437", 2437.0, 2003.0, x, SR, _meas(-55.0))
    assert len(c3) == 1, c3


def test_detector_cpu_gate_skips_quiet_captures():
    d = e.ElrsDetector()
    x = noise(16384)
    c, s = d.observe("r0", "2437", 2437.0, 2000.0, x, SR, _meas(-84.0))
    assert c == [] and s == [], (c, s)


def test_detector_ignores_non_elrs_bands():
    d = e.ElrsDetector()
    x = chirp_train(100e3)
    c, s = d.observe("r0", "5780", 5780.0, 2000.0, x, SR, _meas(-55.0))
    assert c == [] and s == [], (c, s)


def test_bridge_local_gemini_signature_needs_wide_capture():
    # End-to-end through ElrsDetector with a 50 MHz-wide capture holding
    # two trains 40 MHz apart: the bridge-local signature must fire.
    # The FHSS gate (>= 3 distinct channels in 30 s) means hop history
    # must be built first -- mirroring real operation, where a genuine
    # ELRS link has been hopping long before any one capture.
    fs = 50_000_000
    n = 16384
    x = noise(n).astype(np.complex64)
    # NOTE: noise() uses SR timing; regenerate at fs for correctness.
    lin = 10 ** (-85.0 / 20.0)
    x = ((RNG.standard_normal(n) + 1j * RNG.standard_normal(n))
         / math.sqrt(2) * lin).astype(np.complex64)
    for f_off in (-20e6, +20e6):
        up = e.lora_upchirp(5, 812_500.0, fs)
        sig = np.tile(up, 6)
        t = np.arange(len(sig)) / fs
        sig = sig * np.exp(2j * np.pi * f_off * t) * 10 ** (-60 / 20.0)
        x[2048:2048 + len(sig)] += sig.astype(np.complex64)
    d = e.ElrsDetector()
    # Hop history: three narrow captures on distinct channels first.
    for k, off in enumerate((-1.5e6, 0.0, 1.5e6)):
        xh = chirp_train(off, fs=SR)
        d.observe("r0", "2437", 2437.0, 2990.0 + k * 3.0, xh, SR,
                  _meas(-55.0))
    c, s = d.observe("r0", "2437", 2437.0, 3000.0, x, fs, _meas(-55.0))
    assert c, "chirp event expected"
    # One coincidence scores 0.25 < emit threshold 0.30 by design (a
    # lone coincidence is weak evidence); the second coincident
    # capture pushes it over.
    c2, s2 = d.observe("r0", "2437", 2437.0, 3003.0, x, fs, _meas(-55.0))
    assert len(s2) == 1, (c2, s2)
    ev = s2[0]
    assert ev["kind"] == "elrs_signature", ev
    assert ev["mode"] == "gemini-2g4", ev
    assert 0.0 < ev["score"] <= 1.0, ev
    assert "ELRS" not in str(ev), ev  # never shout the identity it can't prove
    # The event must never claim identity: no "confirmed"/"detected ELRS".
    blob = str(ev).lower()
    assert "confirm" not in blob, blob


def test_hop_tracker_counts_distinct_channels():
    ht = e.HopTracker()
    for k in range(10):
        ht.note(5000.0 + k, 2440.0 + (k % 3))
    assert ht.hop_count() == 10
    assert ht.distinct_channels(now=5009.0) == 3


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
