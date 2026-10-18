"""Tests for doppler_detect.py — ambient-LTE Doppler tracker.

Run:  python test_doppler_detect.py        (no pytest needed; numpy only)

Contract under test: the tracker assembles 0.5 s CPIs, locks the
direct-path reference, clutter-cancels it, and reports the strongest
Doppler peak above the SNR gate -- at most one event per CPI, silence
when idle, and ref_locked=false within 2 CPIs of reference loss. It
reports radial velocity with approaching = negative; it never claims
position, identity, or any paper's accuracy numbers.
"""
import math
import sys

import numpy as np

import doppler_detect as d

FS = 100_000          # test sample rate (2 Hz bins need only time, not BW)
N = int(FS * d.CPI_S)  # samples per CPI
CENTER = 1865.0       # MHz, the LTE downlink stare
# Truth: -1.14 m/s radial at 1865 MHz -> -14.2 Hz Doppler, approaching.
TRUTH_DOPPLER_HZ = -14.2
TRUTH_RADIAL_MS = -1.14
RNG_SEED = 5


def cpi_scene(seed, echo_phys_hz=14.2, ref_amp=1.0, echo_amp=0.1,
              noise_var=5.0):
    """One synthetic 0.5 s CPI: strong static reference at DC (the
    direct path), an optional echo at echo_phys_hz (physical sign:
    positive = approaching), plus noise.

    Levels: echo 20 dB below the reference, ~20 dB above the per-bin
    noise floor -- comfortably above the 14 dB gate with margin, while
    the static-only scene stays below it (see the clutter test).
    """
    rng = np.random.default_rng(seed)
    t = np.arange(N) / FS
    x = np.full(N, ref_amp, dtype=np.complex64)
    if echo_phys_hz:
        x = x + (echo_amp * np.exp(2j * np.pi * echo_phys_hz * t)
                 ).astype(np.complex64)
    nz = ((rng.standard_normal(N) + 1j * rng.standard_normal(N))
          / math.sqrt(2.0) * math.sqrt(noise_var)).astype(np.complex64)
    return (x + nz).astype(np.complex64)


def feed_cpi(tr, x, t, chunks=4):
    """Feed one CPI in `chunks` pieces (exercises the accumulation
    path); return the events from the completing call."""
    evs = []
    for c in range(chunks):
        evs = tr.observe("r0", CENTER, t, x[c * N // chunks:(c + 1) * N // chunks], FS)
    return evs


def test_resolution_mover_reported_accurately():
    # Spec test 1: simulated mover at -1.14 m/s @1865 MHz -> -14.2 Hz,
    # within +/-0.5 Hz, over 20 consecutive CPIs; ref_locked true.
    tr = d.DopplerTracker()
    for k in range(20):
        evs = feed_cpi(tr, cpi_scene(RNG_SEED + k), 1000.0 + k)
        assert len(evs) == 1, (k, evs)  # throttled: exactly 1 per CPI
        ev = evs[0]
        assert ev["v"] == 1 and ev["kind"] == "doppler_ref", ev
        assert ev["ref_locked"] is True, ev
        assert abs(ev["doppler_hz"] - TRUTH_DOPPLER_HZ) <= 0.5, ev
        assert abs(ev["radial_ms"] - TRUTH_RADIAL_MS) <= 0.05, ev
        assert ev["snr_db"] >= d.SNR_GATE_DB, ev
        assert ev["radio"] == "r0" and ev["center_mhz"] == CENTER, ev


def test_static_scene_is_silent():
    # Spec test 1, second half: a static-only scene emits nothing.
    tr = d.DopplerTracker()
    for k in range(5):
        evs = feed_cpi(tr, cpi_scene(500 + k, echo_phys_hz=0.0), 2000.0 + k)
        assert evs == [], (k, evs)


def test_clutter_cancellation_200_cpis_silent():
    # Spec test 2: static scene + strong direct path only. The detector
    # must be quiet when nothing moves -- fail-loud here would poison
    # the merger, so quiet is the requirement, not a nice-to-have.
    tr = d.DopplerTracker()
    total = 0
    for k in range(200):
        evs = feed_cpi(tr, cpi_scene(9000 + k, echo_phys_hz=0.0),
                       3000.0 + k, chunks=2)
        total += len(evs)
    assert total == 0, f"{total} false events in 200 static CPIs"


def test_reference_loss_failsafe():
    # Spec test 3: kill the direct-path component -> ref_locked goes
    # false within 2 CPIs, and no peak events are emitted while lost
    # (no reference = no coherent measurement = no claim).
    tr = d.DopplerTracker()
    for k in range(3):
        evs = feed_cpi(tr, cpi_scene(700 + k), 5000.0 + k)
        assert len(evs) == 1 and evs[0]["ref_locked"] is True, evs
    first_false = None
    for k in range(3, 7):
        # Reference loss = the illumination is gone: the direct path
        # AND its echo vanish together (leaving the echo would just
        # promote it to the new "strongest static component").
        evs = feed_cpi(tr, cpi_scene(700 + k, ref_amp=1e-4, echo_amp=0.0),
                       5000.0 + k)
        for ev in evs:
            assert ev["ref_locked"] is False, ev
            assert ev["doppler_hz"] == 0.0 and ev["snr_db"] == 0.0, ev
            if first_false is None:
                first_false = k
    assert first_false is not None, "no ref_locked=false status emitted"
    assert first_false <= 4, \
        f"reference loss reported at CPI {first_false}, need within 2 CPIs"


def test_reference_relock():
    # The tracker recovers when the reference returns (the status
    # events stop and peak events resume).
    tr = d.DopplerTracker()
    feed_cpi(tr, cpi_scene(31, ref_amp=1e-4, echo_amp=0.0), 6000.0)
    evs = feed_cpi(tr, cpi_scene(32, ref_amp=1e-4, echo_amp=0.0), 6001.0)
    assert evs and evs[0]["ref_locked"] is False, evs
    evs = feed_cpi(tr, cpi_scene(33), 6002.0)
    assert len(evs) == 1 and evs[0]["ref_locked"] is True, evs
    assert abs(evs[0]["doppler_hz"] - TRUTH_DOPPLER_HZ) <= 0.5, evs


def test_sign_convention_receding_is_positive():
    # Approaching = negative, so receding = positive on both fields.
    tr = d.DopplerTracker()
    evs = feed_cpi(tr, cpi_scene(77, echo_phys_hz=-14.2), 7000.0)
    assert len(evs) == 1, evs
    ev = evs[0]
    assert abs(ev["doppler_hz"] - 14.2) <= 0.5, ev
    assert abs(ev["radial_ms"] - 1.14) <= 0.05, ev


def test_event_schema_fields():
    tr = d.DopplerTracker()
    evs = feed_cpi(tr, cpi_scene(99), 8000.0)
    assert len(evs) == 1, evs
    ev = evs[0]
    for f in ("v", "kind", "radio", "center_mhz", "doppler_hz",
              "radial_ms", "snr_db", "ref_locked", "t"):
        assert f in ev, (f, ev)
    assert ev["kind"] == "doppler_ref" and ev["v"] == 1


def test_bad_captures_never_become_events():
    tr = d.DopplerTracker()
    assert tr.observe("r0", CENTER, 9000.0,
                      np.array([], dtype=np.complex64), FS) == []
    bad = cpi_scene(101)
    bad[10] = np.nan
    assert feed_cpi(tr, bad, 9001.0) == []
    assert tr.observe("r0", CENTER, 9002.0,
                      cpi_scene(102)[:100], 0.0) == []  # bad fs


def test_degenerate_captures_are_safe():
    # All-zero and constant captures must not raise (log10(0)) and
    # must not produce peak events. A constant is a perfect,
    # noiseless "reference" with nothing else in the scene: after
    # cancellation the surveillance is exactly zero -> silent, locked
    # (the reference itself is present).
    tr = d.DopplerTracker()
    z = np.zeros(N, dtype=np.complex64)
    evs = feed_cpi(tr, z, 9100.0)
    assert evs and evs[0]["ref_locked"] is False, evs  # no reference
    tr2 = d.DopplerTracker()
    c = np.full(N, np.complex64(0.5 + 0.25j))
    evs = feed_cpi(tr2, c, 9200.0)
    assert evs == [], evs  # reference present, nothing moving: silent


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
