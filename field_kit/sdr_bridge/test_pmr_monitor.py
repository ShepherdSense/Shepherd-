"""Tests for pmr_monitor.py — EXPERIMENTAL LoRa preamble PMR monitor.

Run:  python test_pmr_monitor.py        (no pytest needed; numpy only)

HONESTY CONTRACT (read before citing any number here):
  * All signals below are SYNTHETIC ideal chirps. They validate the
    MATH (dechirp, PMR statistic, run + SFD logic, threshold logic,
    buffering, file path) — they are NOT a live claim. The paper's
    numbers are simulation-only and this file's numbers are synthetic
    too; neither is a hardware threshold. Live validation runs on
    Draco's hardware against the procedure in pmr_monitor_spec.md.
  * The jammer tests check the DIRECTION and approximate size of the
    PMR response to a second LoRa-like train (paper mechanism), not a
    detection guarantee. Thresholds below carry margin under the
    measured probe values (equal jammer: 2.74 dB drop; -8 dB jammer:
    1.30 dB drop; clean PMR 14.4-17.2 dB across rates/CFOs).
"""

import json
import math
import os
import subprocess
import sys
import tempfile

import numpy as np

import pmr_monitor as pm
from elrs_detect import lora_upchirp

RNG = np.random.default_rng(11)
FS4 = 4_000_000
FS24 = 2_400_000


def noise(n, level_db=-85.0):
    lin = 10 ** (level_db / 20.0)
    return ((RNG.standard_normal(n) + 1j * RNG.standard_normal(n))
            / math.sqrt(2) * lin).astype(np.complex64)


def packet(fs, cfo_hz=5000.0, level_db=-60.0, sync_shifts=(0, 0),
           jammer=None):
    """Shepherd-like packet: 10 upchirps (8 programmed + 2 sync) +
    2.25 downchirps (SFD). jammer=(offset_hz, level_db) adds a second
    LoRa-like train at full overlap (math-validation interferer)."""
    up = lora_upchirp(7, 125_000.0, fs)
    down = np.conj(up)
    n_sym = len(up)
    parts = []
    for i in range(10):
        shift = 0
        if i == 8:
            shift = sync_shifts[0]
        if i == 9:
            shift = sync_shifts[1]
        t = np.arange(n_sym) / fs
        parts.append(up * np.exp(2j * np.pi * shift * 125000 / 128 * t))
    parts.append(down)
    parts.append(down)
    parts.append(down[:n_sym // 4])
    sig = np.concatenate(parts)
    t = np.arange(len(sig)) / fs
    sig = sig * np.exp(2j * np.pi * cfo_hz * t)
    sig = sig * (10 ** (level_db / 20.0))
    if jammer is not None:
        j_off, j_level = jammer
        jtrain = np.tile(up, 13)
        tj = np.arange(len(jtrain)) / fs
        jtrain = jtrain * np.exp(2j * np.pi * j_off * tj)
        jtrain = jtrain * (10 ** (j_level / 20.0))
        n = max(len(sig), len(jtrain))
        out = np.zeros(n, dtype=np.complex64)
        out[:len(sig)] += sig
        out[:len(jtrain)] += jtrain
        sig = out
    return sig.astype(np.complex64)


def embed(sig, fs, start=8000, total_extra=20000):
    x = noise(len(sig) + total_extra)
    x[start:start + len(sig)] += sig
    return x


def test_clean_preamble_4msps():
    x = embed(packet(FS4, cfo_hz=5000.0), FS4)
    r = pm.PmrMonitor().observe(x, FS4)
    assert len(r) == 1, f"expected 1 reading, got {len(r)}: {r}"
    assert 10 <= r[0]["n_chirps"] <= 12, r[0]
    assert 13.0 <= r[0]["pmr_db"] <= 21.5, r[0]
    assert r[0]["alert"] is False and r[0]["margin_db"] is None


def test_clean_preamble_rtl_rate():
    x = embed(packet(FS24, cfo_hz=-8000.0), FS24)
    r = pm.PmrMonitor().observe(x, FS24)
    assert len(r) == 1, f"expected 1 reading, got {len(r)}: {r}"
    assert 10 <= r[0]["n_chirps"] <= 12, r[0]
    assert 12.0 <= r[0]["pmr_db"] <= 21.5, r[0]


def test_clean_preamble_zero_cfo():
    # tone_off_hz mixes true offset with the winning phase's symbol-
    # alignment offset (up to +/-16 bins = +/-15.6 kHz; a quarter
    # symbol of grid error alone is 32 bins). It is a coarse channel
    # identifier, NEVER a CFO measurement — so this test only asserts
    # it stays inside one channel (+/-62.5 kHz), not near zero.
    x = embed(packet(FS4, cfo_hz=0.0), FS4)
    r = pm.PmrMonitor().observe(x, FS4)
    assert len(r) == 1, r
    assert abs(r[0]["tone_off_hz"]) <= 62500.0, r[0]


def test_sync_word_shifts_tolerated():
    x = embed(packet(FS4, cfo_hz=5000.0, sync_shifts=(1, 2)), FS4)
    r = pm.PmrMonitor().observe(x, FS4)
    assert len(r) == 1, r
    assert 10 <= r[0]["n_chirps"] <= 12, r[0]


def test_noise_only_no_readings():
    r = pm.PmrMonitor().observe(noise(200000), FS4)
    assert r == [], r


def test_payload_only_rejected():
    up = lora_upchirp(7, 125_000.0, FS4)
    n_sym = len(up)
    t = np.arange(n_sym) / FS4
    parts = []
    for k in RNG.integers(0, 128, size=30):
        parts.append(up * np.exp(2j * np.pi * int(k) * 125000 / 128 * t))
    sig = np.concatenate(parts) * (10 ** (-60 / 20.0))
    r = pm.PmrMonitor().observe(embed(sig, FS4), FS4)
    assert r == [], r


def test_identical_data_run_no_sfd_rejected():
    up = lora_upchirp(7, 125_000.0, FS4)
    n_sym = len(up)
    t = np.arange(n_sym) / FS4
    parts = [up * np.exp(2j * np.pi * 30 * 125000 / 128 * t)
             for _ in range(10)]
    parts += [up * np.exp(2j * np.pi * 31 * 125000 / 128 * t)
              for _ in range(5)]
    sig = np.concatenate(parts) * (10 ** (-60 / 20.0))
    r = pm.PmrMonitor().observe(embed(sig, FS4), FS4)
    assert r == [], r


def test_jammer_lowers_pmr_math_validation_only():
    """MATH VALIDATION ONLY (synthetic interferer, not a live claim):
    a second LoRa-like train overlapping the preamble must lower PMR,
    more when it is stronger."""
    clean = pm.PmrMonitor().observe(
        embed(packet(FS4, cfo_hz=5000.0), FS4), FS4)[0]["pmr_db"]
    weak = pm.PmrMonitor().observe(
        embed(packet(FS4, cfo_hz=5000.0, jammer=(20000.0, -68.0)), FS4),
        FS4)[0]["pmr_db"]
    strong = pm.PmrMonitor().observe(
        embed(packet(FS4, cfo_hz=5000.0, jammer=(20000.0, -60.0)), FS4),
        FS4)[0]["pmr_db"]
    assert clean - weak >= 0.8, (clean, weak)
    assert clean - strong >= 2.0, (clean, strong)
    assert strong < weak < clean


def test_threshold_alert_logic():
    """Same input block through three monitors: report-only never
    alerts; a threshold above the reading alerts with negative margin;
    a threshold below it does not alert with positive margin."""
    x = embed(packet(FS4, cfo_hz=5000.0), FS4)
    base = pm.PmrMonitor().observe(x, FS4)[0]
    assert base["alert"] is False and base["margin_db"] is None, base
    hi = pm.PmrMonitor(threshold_db=base["pmr_db"] + 1.0).observe(
        x, FS4)[0]
    assert hi["pmr_db"] == base["pmr_db"], (hi, base)
    assert hi["alert"] is True and hi["margin_db"] == -1.0, hi
    lo = pm.PmrMonitor(threshold_db=5.0).observe(x, FS4)[0]
    assert lo["alert"] is False and lo["margin_db"] > 0, lo


def test_threshold_alert_direct():
    """Threshold logic on a fixed reading path: threshold above the
    observed PMR alerts with a negative margin."""
    mon = pm.PmrMonitor(threshold_db=99.0)
    r = mon.observe(embed(packet(FS4, cfo_hz=5000.0), FS4), FS4)
    assert len(r) == 1, r
    assert r[0]["alert"] is True, r[0]
    assert r[0]["margin_db"] < 0, r[0]
    assert abs(r[0]["margin_db"] - (r[0]["pmr_db"] - 99.0)) < 0.01


def test_cross_boundary_single_reading():
    """A preamble split across two observe() calls is reported exactly
    once (buffering + dedupe), never twice, never zero times."""
    sig = packet(FS4, cfo_hz=5000.0)
    x = embed(sig, FS4)
    # Cut mid-preamble: preamble starts at 8000, one symbol = 4096.
    cut = 8000 + 5 * 4096
    mon = pm.PmrMonitor()
    first = mon.observe(x[:cut], FS4)
    second = mon.observe(x[cut:], FS4)
    assert len(first) + len(second) == 1, (first, second)


def test_recorded_iq_file_path():
    """The recorded-IQ path reads real files (.npy + raw .bin). The
    CONTENT here is synthetic (math validation); the PATH is what
    this test proves."""
    x = embed(packet(FS4, cfo_hz=5000.0), FS4)
    with tempfile.TemporaryDirectory() as d:
        p_npy = os.path.join(d, "cap.npy")
        np.save(p_npy, x)
        got, fs = pm.read_iq_file(p_npy, FS4)
        assert fs == FS4 and len(got) == len(x)
        r = pm.PmrMonitor().observe(got, fs)
        assert len(r) == 1, r
        p_bin = os.path.join(d, "cap.bin")
        x.astype(np.complex64).tofile(p_bin)
        got2, _ = pm.read_iq_file(p_bin, FS4)
        assert np.array_equal(got, got2)
        r2 = pm.PmrMonitor().observe(got2, FS4)
        assert len(r2) == 1, r2


def test_recorded_iq_cli():
    """End-to-end CLI on a recorded file prints one JSON reading."""
    x = embed(packet(FS4, cfo_hz=5000.0), FS4)
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "cap.npy")
        np.save(p, x)
        out = subprocess.run(
            [sys.executable, "pmr_monitor.py", p, "--fs", str(FS4)],
            capture_output=True, text=True, cwd=os.path.dirname(
                os.path.abspath(__file__)), timeout=120)
        assert out.returncode == 0, out.stderr
        lines = [json.loads(ln) for ln in out.stdout.splitlines()
                 if ln.strip()]
        assert len(lines) == 1, lines
        assert 13.0 <= lines[0]["pmr_db"] <= 21.5, lines[0]


def test_dechirp_tone_property():
    """Dechirping an upchirp with its conjugate reference yields a
    tone (high peak/mean); a downchirp with the up reference does too.
    Direct property of the statistic, independent of the scanner."""
    up = lora_upchirp(7, 125_000.0, FS4)
    mon = pm.PmrMonitor()
    n_sym = len(up)
    win = (up * (10 ** (-60 / 20.0))).astype(np.complex64)
    win = win + noise(n_sym)
    up_db, _, down_db = mon._symbol_pmr(win, np.conj(up), up)
    assert up_db > 15.0, up_db
    win_d = (np.conj(up) * (10 ** (-60 / 20.0))).astype(np.complex64)
    win_d = win_d + noise(n_sym)
    up_db2, _, down_db2 = mon._symbol_pmr(win_d, np.conj(up), up)
    assert down_db2 > 15.0, down_db2
    assert up_db2 < 10.0, up_db2  # a downchirp is NOT an upchirp


def dense_block(level_db):
    """A >80%-signal block: loud-noise filler + quiet gap + one
    packet at level_db. The filler pushes the 20th percentile to
    signal, so the burst gate is the dense-regime ~noise x 30 floor
    (~+14.4 dB over the -85 dB base noise), not the sparse ~+7.6 dB
    floor. The 16-hop gap exceeds the 12-hop region padding, so the
    packet is never scanned via the filler region."""
    hop = len(lora_upchirp(7, 125_000.0, FS4)) // 4  # 1024
    filler = noise(330 * hop, level_db=-65.0)
    gap = noise(16 * hop)
    sig = packet(FS4, cfo_hz=5000.0, level_db=level_db)
    tail = noise(16 * hop)
    return np.concatenate([filler, gap, sig, tail])


def test_dense_block_burst_gate_two_regimes():
    """Dense-block regression: a +8 dB preamble is missed (below
    the dense ~+14.4 dB floor) while a +16 dB preamble is read."""
    none = pm.PmrMonitor().observe(dense_block(-77.0), FS4)
    assert none == [], none
    one = pm.PmrMonitor().observe(dense_block(-69.0), FS4)
    assert len(one) == 1, one
    assert 10 <= one[0]["n_chirps"] <= 12, one[0]
    assert 10.0 <= one[0]["pmr_db"] <= 21.5, one[0]


def test_dense_block_plus12_isolates_burst_gate():
    """At +12 dB the preamble clears the 10 dB detect gate on
    dechirp gain alone (sparse block yields a reading, PMR ~14.9),
    so zero readings in the dense block pins the BURST gate, not
    the detect gate. Probe also bounded the dense floor between
    +14 dB (missed) and +15 dB (read), consistent with ~+14.4 dB."""
    sparse = pm.PmrMonitor().observe(
        embed(packet(FS4, cfo_hz=5000.0, level_db=-73.0), FS4), FS4)
    assert len(sparse) == 1, sparse
    assert pm.PmrMonitor().observe(dense_block(-73.0), FS4) == []


def test_sync_word_0x34_tolerated_default_rejects():
    """0x34 sync chirps shift 3, 4 bins: a 0x34 monitor (tolerance
    derived from the nibbles) reads the packet; the default 0x12
    monitor rejects it (run breaks at the sync symbols, SFD check
    fails) instead of silently misreading it."""
    x = embed(packet(FS4, cfo_hz=5000.0, sync_shifts=(3, 4)), FS4)
    r = pm.PmrMonitor(sync_word=0x34).observe(x, FS4)
    assert len(r) == 1, r
    assert 10 <= r[0]["n_chirps"] <= 12, r[0]
    assert pm.PmrMonitor().observe(x, FS4) == []


def test_sample_rate_below_nyquist_raises():
    """fs below (complex) Nyquist for 125 kHz would make the 128-bin
    gather index past the window; observe() must fail loudly."""
    try:
        pm.PmrMonitor().observe(noise(10000), 100_000.0)
    except ValueError:
        pass
    else:
        raise AssertionError("expected ValueError for fs=100 kHz")
    # 250 kHz is fine (n_sym 256 >= 128 bins): noise yields no reading.
    assert pm.PmrMonitor().observe(noise(10000), 250_000.0) == []


def test_nan_inf_iq_never_emits_nan_reading():
    """Corrupted IQ (NaN or Inf slices inside the preamble) must
    never produce a non-finite reading, and must not raise. (NaN
    blocks skip at the burst gate; Inf blocks exercise the _db
    floor and the observe() skip — both end with no NaN output.)"""
    base = embed(packet(FS4, cfo_hz=5000.0), FS4)
    for bad in (np.nan, np.inf):
        x = base.copy()
        x[8000 + 2 * 4096:8000 + 4 * 4096] = np.complex64(
            bad + 1j * bad)
        r = pm.PmrMonitor().observe(x, FS4)
        for rd in r:
            assert math.isfinite(rd["pmr_db"]), rd


def test_recorded_iq_cli_bad_files_clean_error():
    """Bad inputs fail with a clean message and nonzero exit, never
    a traceback (bad .npy content, bad .bin length, missing file)."""
    with tempfile.TemporaryDirectory() as d:
        p_npy = os.path.join(d, "real.npy")
        np.save(p_npy, np.zeros(100, dtype=np.float64))
        p_bin = os.path.join(d, "odd.bin")
        with open(p_bin, "wb") as f:
            f.write(b"\x00" * 7)
        for p in (p_npy, p_bin, os.path.join(d, "missing.npy")):
            out = subprocess.run(
                [sys.executable, "pmr_monitor.py", p, "--fs", str(FS4)],
                capture_output=True, text=True,
                cwd=os.path.dirname(os.path.abspath(__file__)),
                timeout=120)
            assert out.returncode != 0, (p, out.stdout, out.stderr)
            assert "Traceback" not in out.stderr, out.stderr
            assert "pmr_monitor: error:" in out.stderr, out.stderr


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
