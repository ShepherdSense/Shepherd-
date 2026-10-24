"""Tests for the v0.25.0 LTE + 5G NR adapters in sdr_bridge.py.

Run:  python test_lte_nr.py        (no pytest needed; numpy only)

Contract under test:
  LTE -- a flat-top wideband signal inside an LTE downlink band is
  reported as illuminator PRESENCE (shape only, never an LTE
  identification, never a position, no payload bits touched); a tone
  or quiet in the same band is not. LTE450 is recognised by the
  table but gated to operator opt-in in main() (the is_lte450 flag
  is what the gate reads). The existing DopplerTracker feed works
  on an LTE450-centre stare too (same 0.5 s CPI, same doppler_ref
  schema -- the wire format is unchanged). The FKIE ~1.6 km figure
  is CLAIMED, never asserted here; the bench hook (LteBenchLog /
  summarize_lte_bench) is what replaces it with measured data.
  5G NR -- the v0.25.0 adapter is a STUB: it is inert on every
  non-USRP backend and on USRP-class hardware at the bridge's
  4 MSPS, and even when its gate opens (USRP-class >= 20 MSPS)
  observe() emits NOTHING. No NR packet kind exists in v0.25.0,
  and no BSense numbers are claimed anywhere.
"""
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

import numpy as np

import sdr_bridge as b
import doppler_detect as d

SR = 4_000_000
N = b.CAPTURE_N
RNG = np.random.default_rng(11)


def noise(n=N, level_db=-85.0):
    lin = 10 ** (level_db / 20.0)
    return ((RNG.standard_normal(n) + 1j * RNG.standard_normal(n))
            / math.sqrt(2) * lin).astype(np.complex64)


def tone(f_hz, amp_db, n=N):
    t = np.arange(n) / SR
    return (np.exp(2j * np.pi * f_hz * t) * 10 ** (amp_db / 20.0)).astype(
        np.complex64)


def flat_top(n=N, half_bw_hz=1.5e6, level_db=-65.0):
    """Rectangular-spectrum wideband signal, like an LTE downlink
    slice: white noise masked in frequency to a flat top."""
    w = ((RNG.standard_normal(n) + 1j * RNG.standard_normal(n))
         / math.sqrt(2)).astype(np.complex64)
    W = np.fft.fftshift(np.fft.fft(w))
    fr = np.fft.fftshift(np.fft.fftfreq(n, d=1.0 / SR))
    W[np.abs(fr) > half_bw_hz] = 0.0
    flat = np.fft.ifft(np.fft.ifftshift(W))
    rms = float(np.sqrt(np.mean(np.abs(flat) ** 2))) or 1.0
    lin = 10 ** (level_db / 20.0)
    return (flat / rms * lin).astype(np.complex64)


DET = b.LteIlluminatorDetector()


def test_lte_band_table_matching():
    assert b.lte_band_for_center(465.0) == ("LTE450", True)
    assert b.lte_band_for_center(467.37) == ("LTE450", True)  # FKIE freq
    assert b.lte_band_for_center(1865.0) == ("B3", False)
    assert b.lte_band_for_center(2115.0) == ("B1", False)
    assert b.lte_band_for_center(2437.0) is None
    assert b.lte_band_for_center(915.0) is None


def test_lte_flat_top_in_dl_band_detected():
    # Quiet capture first: the detector measures SNR against the
    # calmest floor previously seen, so it needs a quiet reference
    # before it can report (see LteIlluminatorDetector docstring).
    assert DET.detect(noise(), SR, 465.0) is None
    det = DET.detect(noise() + flat_top(), SR, 465.0)
    assert det is not None, "flat-top in LTE450 band must detect"
    assert det["dl_band"] == "LTE450" and det["is_lte450"] is True
    assert det["snr_db"] >= b.LTE_MIN_SNR_DB, det
    assert det["fill_frac"] >= b.LTE_MIN_FILL_FRAC, det
    # Event schema: additive kind, JSON-serializable, finite values.
    pkt = DET.event("rtlsdr0", "465", 465.0, 1729123456.789, det)
    assert pkt["v"] == 1 and pkt["kind"] == "lte_illuminator"
    assert pkt["center_mhz"] == 465.0 and pkt["dl_band"] == "LTE450"
    json.dumps(pkt, allow_nan=False)


def test_lte_tone_in_dl_band_not_detected():
    # A narrowband tone in the same band fails the fill/median tests:
    # presence means flat-top wideband, not "anything energetic".
    assert DET.detect(noise() + tone(300e3, -50.0), SR, 465.0) is None


def test_lte_quiet_in_dl_band_not_detected():
    assert DET.detect(noise(), SR, 465.0) is None


def test_lte_flat_top_outside_dl_band_not_detected():
    # Same signal, tuned outside any DL band: the adapter must not
    # claim an LTE illuminator where no LTE DL band is tuned.
    assert DET.detect(noise() + flat_top(), SR, 2437.0) is None


def test_lte_sim_backend_465_detected_end_to_end():
    sim = b.SimBackend()
    sim.tune(465.0, 5.0, 40)
    # First capture is quiet by design (the sim gates its LTE450
    # flat-top on one prior capture, like the 5780 OFDM demo) --
    # it calibrates the detector's quiet reference; the second
    # capture carries the flat-top and must detect.
    assert DET.detect(sim.capture(N), SR, 465.0) is None
    det = DET.detect(sim.capture(N), SR, 465.0)
    assert det is not None and det["dl_band"] == "LTE450", det


def test_lte_doppler_feed_on_lte450_stare():
    # Same DopplerTracker, same doppler_ref schema, LTE450 centre:
    # -1.14 m/s-class mover geometry at 465 MHz. Physical echo at
    # +14.2 Hz (approaching) -> reported doppler_hz -14.2, radial =
    # doppler * c / (2 * 465 MHz) = -4.58 m/s. 2 Hz bins from the
    # 0.5 s CPI, exactly as in the 1.86 GHz spec -- the feed, not a
    # new wire format.
    fs = 100_000
    n = int(fs * d.CPI_S)
    rng = np.random.default_rng(5)
    t = np.arange(n) / fs
    x = np.full(n, 1.0, dtype=np.complex64)
    x = x + (0.1 * np.exp(2j * np.pi * 14.2 * t)).astype(np.complex64)
    nz = ((rng.standard_normal(n) + 1j * rng.standard_normal(n))
          / math.sqrt(2.0) * math.sqrt(5.0)).astype(np.complex64)
    x = (x + nz).astype(np.complex64)
    tr = d.DopplerTracker()
    evs = []
    for c in range(4):
        evs = tr.observe("r0", 465.0, 1000.0,
                         x[c * n // 4:(c + 1) * n // 4], fs)
    assert len(evs) == 1, evs
    ev = evs[0]
    assert ev["kind"] == "doppler_ref" and ev["ref_locked"] is True
    assert abs(ev["doppler_hz"] - (-14.2)) < 0.5, ev
    expect_radial = -14.2 * 299792458.0 / (2.0 * 465.0e6)
    assert abs(ev["radial_ms"] - expect_radial) < 0.15, ev


def test_lte_bench_log_and_summary():
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "bench.csv")
        log = b.LteBenchLog(path)
        log.record(1000.0, "rtlsdr0", 465.0, "LTE450", 19.4)
        log.record(1001.0, "rtlsdr0", 465.0, "LTE450", 18.1)
        with open(path) as f:
            lines = f.read().strip().split("\n")
        assert lines[0].startswith("t,radio,center_mhz"), lines
        assert len(lines) == 3, lines  # header + 2 rows, range_m blank
        # Summary: rows with ground-truth range bin into detection
        # fractions; rows without a usable range are ignored.
        rows = [
            {"range_m": 50.0, "detected": True},
            {"range_m": 80.0, "detected": True},
            {"range_m": 150.0, "detected": False},
            {"range_m": 180.0, "detected": True},
            {"range_m": "", "detected": True},   # no ground truth
            {"range_m": "n/a", "detected": True},
        ]
        summ = b.summarize_lte_bench(rows, bin_width_m=100.0)
        assert summ == [(0.0, 2, 1.0), (100.0, 2, 0.5)], summ


def test_nr_gate_inert_on_non_usrp():
    nr = b.Nr5gAdapter()
    for name, fs in [("rtlsdr", 2_400_000), ("pluto", 4_000_000),
                     ("soapy-hackrf", 4_000_000), ("simulate", 4_000_000)]:
        p = nr.probe(SimpleNamespace(name=name, sample_rate=fs))
        assert p["active"] is False and p["stub"] is True, (name, p)
        assert nr.observe() == []
        assert "inert" in nr.status_line(
            SimpleNamespace(name=name, sample_rate=fs))


def test_nr_gate_inert_on_usrp_at_bridge_rate():
    # USRP-class hardware at the bridge's 4 MSPS: still inert --
    # a 3.2 MHz slice cannot ingest a 20-100 MHz NR channel.
    nr = b.Nr5gAdapter()
    be = SimpleNamespace(name="uhd", sample_rate=4_000_000)
    p = nr.probe(be)
    assert p["active"] is False and p["stub"] is True, p
    assert nr.observe() == []
    assert "inert" in nr.status_line(be)


def test_nr_gate_armed_stub_on_usrp_wideband():
    # Gate opens only at USRP-class + >= 20 MSPS -- and even then
    # the adapter is a STUB: observe() emits nothing, status says
    # stub explicitly, and no NR packet kind is produced.
    nr = b.Nr5gAdapter()
    be = SimpleNamespace(name="uhd", sample_rate=61_440_000)
    p = nr.probe(be)
    assert p["active"] is True and p["stub"] is True, p
    assert nr.observe() == []
    assert "STUB" in nr.status_line(be) or "stub" in nr.status_line(be)
    be2 = SimpleNamespace(name="soapy-uhd", sample_rate=20_000_000)
    assert nr.probe(be2)["active"] is True


def test_main_lte_sweep_vs_stare_routing():
    # Regression test for a real routing bug caught in smoke
    # testing: an explicit single-band --bands list is a SWEEP
    # (band packets + lte_illuminator), while --stare parks the
    # radio on the Doppler chain (doppler_ref, no illuminator
    # packets). The first version routed single-band sweeps into
    # the Doppler branch and silently suppressed illuminator
    # reports; these subprocess runs pin the corrected routing.
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(
        [sys.executable, os.path.join(here, "sdr_bridge.py"),
         "--simulate", "--bands", "465/5", "--print", "--sweeps", "2"],
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]
    kinds = [json.loads(line)["kind"] for line in r.stdout.splitlines()
             if line.startswith("{")]
    assert "band" in kinds and "lte_illuminator" in kinds, kinds
    assert "doppler_ref" not in kinds, kinds
    r = subprocess.run(
        [sys.executable, os.path.join(here, "sdr_bridge.py"),
         "--simulate", "--stare", "465", "--print", "--sweeps", "1"],
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]
    kinds = [json.loads(line)["kind"] for line in r.stdout.splitlines()
             if line.startswith("{")]
    assert "doppler_ref" in kinds, kinds
    assert "lte_illuminator" not in kinds, kinds


def test_lte_quiet_reference_window_expires_transient_low_floor():
    # S5: the quiet reference is a BOUNDED window, not an
    # all-time minimum. A transient low floor (gain drop,
    # antenna disconnect) used to permanently lower `quiet` and
    # inflate every later snr_db; now it expires after
    # LTE_QUIET_WINDOW later captures at the centre. Local RNG
    # so this test is independent of test-run order.
    rng = np.random.default_rng(123)

    def nz(level_db):
        lin = 10 ** (level_db / 20.0)
        return ((rng.standard_normal(N) + 1j * rng.standard_normal(N))
                / math.sqrt(2) * lin).astype(np.complex64)

    def flat(level_db):
        w = ((rng.standard_normal(N) + 1j * rng.standard_normal(N))
             / math.sqrt(2)).astype(np.complex64)
        W = np.fft.fftshift(np.fft.fft(w))
        fr = np.fft.fftshift(np.fft.fftfreq(N, d=1.0 / SR))
        W[np.abs(fr) > 1.5e6] = 0.0
        f = np.fft.ifft(np.fft.ifftshift(W))
        rms = float(np.sqrt(np.mean(np.abs(f) ** 2))) or 1.0
        return (f / rms * 10 ** (level_db / 20.0)).astype(np.complex64)

    det = b.LteIlluminatorDetector()
    assert det.detect(nz(-110.0), SR, 465.0) is None  # transient low
    weak = nz(-85.0) + flat(-90.0)
    # While the low floor is still in the window, the weak flat
    # signal clears the gate -- the false report the old
    # all-time-minimum reference would have kept forever.
    assert det.detect(weak, SR, 465.0) is not None
    for _ in range(b.LTE_QUIET_WINDOW):
        det.detect(nz(-85.0), SR, 465.0)  # normal floors expire it
    assert det.detect(nz(-85.0) + flat(-90.0), SR, 465.0) is None, \
        "weak flat signal must stop reporting once the low floor expires"
    # The window did not break real detection: a strong flat-top
    # still reports against the normal floor. (Up to 3 captures:
    # the FFT-masked flat-top's median gap sits near the 6 dB
    # gate, so a single capture is ~9/10, not 10/10 -- the
    # assertion is "reports promptly", not "reports first try".)
    assert any(det.detect(nz(-85.0) + flat(-65.0), SR, 465.0)
               is not None for _ in range(3))


def test_lte_band_label_overlap_first_match_wins():
    # S8: B28 (758-803) overlaps B20 (791-821); the table is
    # scanned in order, so an overlapped centre labels B28.
    assert b.lte_band_for_center(800.0) == ("B28", False)
    assert b.lte_band_for_center(795.0) == ("B28", False)
    assert b.lte_band_for_center(810.0) == ("B20", False)  # B20-only
    assert b.lte_band_for_center(760.0) == ("B28", False)  # B28-only


def test_lte_bench_summary_rejects_bad_bin_width():
    # S10: a non-finite or <= 0 bin width raises ValueError,
    # never a ZeroDivisionError or a nonsense bin.
    rows = [{"range_m": 50.0, "detected": True}]
    for bad in (0.0, -100.0, float("nan"), float("inf"), "wide"):
        try:
            b.summarize_lte_bench(rows, bin_width_m=bad)
            raise AssertionError(f"bin_width {bad!r} must raise")
        except ValueError:
            pass
    assert b.summarize_lte_bench(rows, bin_width_m=100.0) == [
        (0.0, 1, 1.0)]


def test_lte_bench_log_csv_quotes_free_text_fields():
    # S10: rows go through the csv module, so a comma/newline
    # in a free-text field is quoted, never a broken row.
    import csv
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "bench.csv")
        log = b.LteBenchLog(path)
        log.record(1000.0, "rtlsdr0", 465.0, "LTE450", 19.4,
                   range_m="1,000\nsurveyed", detected=True)
        with open(path, newline="") as f:
            rows = list(csv.reader(f))
        assert rows[0] == ["t", "radio", "center_mhz", "dl_band",
                           "snr_db", "range_m", "detected"], rows
        assert len(rows) == 2, rows  # header + exactly one data row
        assert rows[1][5] == "1,000\nsurveyed", rows
        assert rows[1][6] == "1", rows


def test_main_combined_bands_and_stare_is_sweep():
    # F5: combined --bands + --stare -- --bands wins band
    # selection, so the list is NOT stare-derived and stays a
    # sweep (band + lte_illuminator), never Doppler-routed.
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(
        [sys.executable, os.path.join(here, "sdr_bridge.py"),
         "--simulate", "--bands", "465/5", "--stare", "465",
         "--print", "--sweeps", "2"],
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]
    kinds = [json.loads(line)["kind"] for line in r.stdout.splitlines()
             if line.startswith("{")]
    assert "band" in kinds and "lte_illuminator" in kinds, kinds
    assert "doppler_ref" not in kinds, kinds


def test_main_bands_1865_is_sweep_not_doppler():
    # F5 (1800-1900 branch): the old unconditional branch sent
    # any --bands sweep containing 1865 into Doppler. Under the
    # unified stare-only rule it is a sweep: band packets, no
    # doppler_ref. (--stare 1865 still runs Doppler; covered by
    # the stare routing test's --stare 465 analogue and the
    # Doppler demo band.)
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(
        [sys.executable, os.path.join(here, "sdr_bridge.py"),
         "--simulate", "--bands", "1865/20", "--print", "--sweeps", "1"],
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]
    kinds = [json.loads(line)["kind"] for line in r.stdout.splitlines()
             if line.startswith("{")]
    assert "band" in kinds, kinds
    assert "doppler_ref" not in kinds, kinds


def test_main_lte_bench_logs_misses_not_just_detections():
    # F6: one bench row per LTE-band sweep visit, detection AND
    # miss. On --simulate --bands 465/5 the first visit is quiet
    # (miss) and the second carries the gated flat-top (hit), so
    # the file must contain a detected=0 row AND a detected=1 row
    # -- and the measured fraction over the visits is below 1.0.
    import csv
    here = os.path.dirname(os.path.abspath(__file__))
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "bench.csv")
        r = subprocess.run(
            [sys.executable, os.path.join(here, "sdr_bridge.py"),
             "--simulate", "--bands", "465/5", "--print", "--sweeps", "2",
             "--lte-bench-out", path],
            capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, r.stderr[-2000:]
        with open(path, newline="") as f:
            rows = list(csv.reader(f))
        detected = [row[6] for row in rows[1:]]
        assert "0" in detected, rows  # a miss was logged
        assert "1" in detected, rows  # ...and a detection
        assert len(detected) >= 2, rows


def test_nr_band_table_present_but_unused_by_stub():
    # n77 (3300-4200) contains n78 (3300-3800); first match wins,
    # so 3600 MHz is ambiguous by construction and only 4000 MHz
    # (n77-only) has a unique answer. The table is interface-only
    # in v0.25.0 regardless.
    assert b.nr_band_for_center(4000.0) == "n77"
    assert b.nr_band_for_center(3600.0) is not None
    assert b.nr_band_for_center(465.0) is None
    # The stub never consults the table for detection: even a
    # perfectly NR-band-centred capture yields no events.
    assert b.Nr5gAdapter().observe() == []


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
