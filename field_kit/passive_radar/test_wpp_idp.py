#!/usr/bin/env python3
"""WPP-IDP spec tests -- numpy only.

Spec: ~/workspace/rf_sentry/docs/passive_radar_wpp_idp_spec.md
(Test / validation plan, tests 1, 2, 3, 6).

  test 1: synthetic IDP chain -- DSSS beacons + target echo at known
          Doppler (+40 Hz, BNR 35 dB); pass = recovered Doppler within
          +/-20% of truth; no-target control run must be clean.
  test 2: waveform-rule parity -- (a) including OFDM data symbols must
          DEGRADE detection vs the DSSS case (the anti-regression gate:
          nobody "improves" the chain by re-adding data symbols);
          (b) preamble-only must RECOVER detection at ~7 dB penalty,
          not worse than 10 dB.
  test 3: DC-removal regression -- static scene (direct path + fixed
          clutter, no target): 10/10 runs must show zero Doppler lines.
  test 6: blade-flash CPI parameterization -- synthetic pusher-prop
          modulation at 80 Hz and multirotor at 250 Hz; the extractor
          with class-parameterized CPI must resolve the blade line for
          BOTH classes, with the pusher-prop class automatically
          selecting the longer CPI. Exact DFD/DMR thresholds are NOT
          asserted (Yan et al. numbers are CLAIMED-from-snippets,
          unverified).

Run:  python3 test_wpp_idp.py
Exit 0 = all pass, non-zero = failure (prints which test failed).
"""

import sys

import numpy as np

from wpp_idp import (BLADE_CLASSES, blade_flash_detect, run_idp,
                     simulate_blade_flash, simulate_energy,
                     simulate_static)

FS_PKT = 2000.0     # synthetic packet-energy rate (time-compressed demo)
DURATION = 4.0
CPI = 0.5
TRUTH_DOPPLER = 40.0
BNR_DSSS = 35.0     # dB, demo operating point (paper: DSSS BNR ~ 32.6 dB)
TOL = 0.20          # +/-20% Doppler recovery tolerance


def _best_doppler(dets):
    return dets[0]["doppler_hz"] if dets else None


def _run(waveform, bnr_db, target, seed, doppler_hz=TRUTH_DOPPLER):
    rng = np.random.default_rng(seed)
    _t, e, truth = simulate_energy(FS_PKT, DURATION, rng,
                                  doppler_hz=doppler_hz, bnr_db=bnr_db,
                                  target=target, waveform=waveform)
    fs = FS_PKT / (8 if waveform == "ofdm_preamble" else 1)
    res = run_idp(e, fs, cpi_s=CPI)
    return res["detections"], truth


def check_within(detected, truth, tol, what):
    err = abs(detected - truth) / abs(truth)
    assert err <= tol, (f"{what}: recovered {detected:.1f} Hz vs truth "
                       f"{truth:.1f} Hz (err {100*err:.1f}% > {100*tol:.0f}%)")
    return err


# ------------------------------------------------------------------ test 1

def test_1_idp_chain_recovers_doppler():
    """DSSS: +40 Hz at BNR 35 dB -> recovered within +/-20%; control clean."""
    dets, truth = _run("dsss", BNR_DSSS, target=True, seed=7)
    assert dets, "test 1 FAIL: DSSS target not detected at BNR 35 dB"
    err = check_within(_best_doppler(dets), truth["doppler_hz"], TOL,
                       "test 1 DSSS")
    # no-target control: same chain, no echo -> zero lines above threshold
    dets_ctrl, _ = _run("dsss", BNR_DSSS, target=False, seed=8)
    assert not dets_ctrl, (f"test 1 FAIL: no-target control produced "
                           f"{len(dets_ctrl)} false line(s)")
    print(f"test 1 PASS: DSSS recovered {truth['doppler_hz']:+.0f} Hz "
          f"within {100*err:.1f}% (tol 20%); no-target control clean")


# ------------------------------------------------------------------ test 2

def test_2_waveform_rule_parity():
    """(a) data-symbol inclusion degrades; (b) preamble-only recovers."""
    # (a) OFDM full-packet processing at the SAME BNR where DSSS detects
    # must fail: random data symbols randomize the interference and kill
    # the coherent line (paper: BNR 52-57 dB required, grows as DNR^2).
    dets_dsss, _ = _run("dsss", BNR_DSSS, target=True, seed=7)
    assert dets_dsss, "test 2a setup FAIL: DSSS baseline did not detect"
    dets_full, _ = _run("ofdm_full", BNR_DSSS, target=True, seed=7)
    assert not dets_full, (
        f"test 2a FAIL (anti-regression): OFDM data-symbol processing "
        f"detected at BNR {BNR_DSSS:.0f} dB where it must degrade -- "
        f"the waveform rule is violated")
    # even 15 dB hotter, data symbols must not produce a coherent line
    dets_full_hot, _ = _run("ofdm_full", BNR_DSSS + 15.0, target=True,
                            seed=7)
    assert not dets_full_hot, (
        "test 2a FAIL: OFDM data-symbol processing produced a line at "
        f"BNR {BNR_DSSS + 15.0:.0f} dB -- the degradation model is broken")
    print(f"test 2a PASS: OFDM data-symbol inclusion degrades detection "
          f"(no line at BNR {BNR_DSSS:.0f} dB, nor at +15 dB) -- "
          f"anti-regression gate holds")

    # (b) preamble-only must recover detection within a <=10 dB penalty
    # vs the DSSS operating point (paper: ~7 dB cost).
    bnr_req = None
    for bnr in [BNR_DSSS + k for k in range(0, 16)]:
        dets, _ = _run("ofdm_preamble", bnr, target=True, seed=7)
        if dets and abs(dets[0]["doppler_hz"] - TRUTH_DOPPLER) \
                / TRUTH_DOPPLER <= TOL:
            bnr_req = bnr
            break
    assert bnr_req is not None, \
        "test 2b FAIL: preamble-only never recovered detection"
    penalty = bnr_req - BNR_DSSS
    assert penalty <= 10.0, (
        f"test 2b FAIL: preamble-only penalty {penalty:.0f} dB > 10 dB")
    print(f"test 2b PASS: preamble-only recovered +{TRUTH_DOPPLER:.0f} Hz "
          f"at BNR {bnr_req:.0f} dB (penalty {penalty:.0f} dB <= 10 dB; "
          f"paper reports ~7 dB)")


# ------------------------------------------------------------------ test 3

def test_3_dc_removal_static_clean():
    """10/10 static runs (direct path + fixed clutter, no target): zero lines."""
    for seed in range(10):
        rng = np.random.default_rng(100 + seed)
        _t, e = simulate_static(FS_PKT, DURATION, rng, clutter_db=20.0)
        res = run_idp(e, FS_PKT, cpi_s=CPI)
        n = len(res["detections"])
        assert n == 0, (f"test 3 FAIL: static run {seed} produced "
                        f"{n} false Doppler line(s) -- DC removal leaking")
    print("test 3 PASS: DC removal regression -- 10/10 static runs clean")


# ------------------------------------------------------------------ test 6

def test_6_blade_flash_cpi_parameterized():
    """Pusher-prop 80 Hz + multirotor 250 Hz both resolved; pusher gets
    the longer CPI automatically. No exact DFD/DMR thresholds asserted."""
    cases = [("pusher_prop", 80.0), ("multirotor", 250.0)]
    used = {}
    for cls, flash_hz in cases:
        rng = np.random.default_rng(200 + int(flash_hz))
        _t, e = simulate_blade_flash(FS_PKT, 2.0, rng, flash_hz,
                                     snr_db=20.0)
        out = blade_flash_detect(e, FS_PKT, cls)
        used[cls] = out["cpi_s"]
        assert out["flash_hz"] is not None, (
            f"test 6 FAIL: {cls} blade line at {flash_hz:.0f} Hz not "
            f"resolved with CPI {out['cpi_s']:.2f} s")
        err = abs(out["flash_hz"] - flash_hz) / flash_hz
        assert err <= 0.10, (
            f"test 6 FAIL: {cls} flash {out['flash_hz']:.1f} Hz vs "
            f"{flash_hz:.0f} Hz (err {100*err:.1f}%)")
        print(f"test 6: {cls:11s} flash {flash_hz:6.0f} Hz -> "
              f"{out['flash_hz']:6.1f} Hz (CPI {out['cpi_s']:.2f} s)")
    assert used["pusher_prop"] > used["multirotor"], (
        "test 6 FAIL: pusher-prop class did not select the longer CPI")
    cpi_p, cpi_m = BLADE_CLASSES["pusher_prop"][0], \
        BLADE_CLASSES["multirotor"][0]
    assert used["pusher_prop"] == cpi_p and used["multirotor"] == cpi_m
    print(f"test 6 PASS: both blade lines resolved; pusher-prop CPI "
          f"({used['pusher_prop']:.2f} s) > multirotor CPI "
          f"({used['multirotor']:.2f} s) -- automatic longer integration "
          f"for the weaker Shahed-class modulation (no DFD/DMR "
          f"thresholds asserted)")


# ------------------------------------------------------------------ runner

def main():
    tests = [test_1_idp_chain_recovers_doppler,
             test_2_waveform_rule_parity,
             test_3_dc_removal_static_clean,
             test_6_blade_flash_cpi_parameterized]
    failed = 0
    for t in tests:
        try:
            t()
        except AssertionError as ex:
            print(str(ex))
            failed += 1
    print(f"\n{'ALL 4 TESTS PASS' if not failed else f'{failed} TEST(S) FAILED'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
