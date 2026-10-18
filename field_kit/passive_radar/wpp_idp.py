#!/usr/bin/env python3
"""
WPP-IDP: single-channel passive radar (WiFi preamble processing,
integrated detection and processing) -- RECEIVE ONLY. Nothing here
transmits.

Architecture (per Colone et al., IEEE TAES 59(5), 2023, pp. 6432-6451
-- READ IN FULL, CONFIRMED): with no clean reference channel, the
classical cross-ambiguity function is unavailable. The IDP trick works
on the interference itself:

    per-packet (or per-preamble) received energy  E[n]
      -> DC removal            (kills the static direct-path pedestal
                                + stationary clutter)
      -> STFT of the residual  (slow amplitude modulation -> Doppler line)
      -> CFAR-style Doppler-line detector -> (t, doppler_hz, strength)

The physics: one RX antenna hears the WiFi AP directly (strong) AND the
AP's signal scattered off a moving target (weak). The echo interferes
with the direct signal, producing a slow amplitude modulation at the
Doppler difference. Per-packet energy turns that modulation into a time
series; the STFT reveals it as a Doppler line. No demodulation, no
synchronization to the AP, no second antenna.

WAVEFORM RULE (CONFIRMED, load-bearing -- do not "improve" this chain):
  * DSSS beacons (802.11b-style): process ALL packets. Near-ideal,
    BNR ~ 32.6 dB.
  * OFDM (802.11n/ac/ax): PREAMBLE-ONLY. Random data symbols randomize
    the interference symbol-to-symbol and destroy coherent integration
    (BNR 52-57 dB, requirement growing as DNR^2 -- effectively unusable).
    Preamble-only restores determinism at a cost of ~7 dB SNR. NEVER
    include OFDM data symbols; test_wpp_idp.py::test_waveform_rule_parity
    is the anti-regression gate that proves inclusion degrades detection.

HONEST SCOPE (read before trusting any output):
  * Range is METERS TO TENS OF METERS. The Mavic Pro demonstration was
    at that scale (CONFIRMED). This is a perimeter/area gap-filler inside
    the mesh bubble, not a standoff sensor.
  * BASELINE-CROSSING detector: sensitivity peaks when the threat crosses
    a Tx-Rx baseline. Threats flying parallel to all baselines or outside
    the baseline fan are weakly covered or uncovered.
  * STATIC RECEIVER ASSUMED. Node motion impresses its own slow amplitude
    modulation on E[n] and masquerades as Doppler. Until ego-motion
    compensation exists, detections are valid for static nodes only;
    moving-node outputs must not merge into track confidence.
  * Outputs are disturbances, never identities: (t, doppler_hz, strength)
    with inbound/outbound relative to the baseline from the Doppler sign.
    No imagery, no silhouettes, no fire-control tracks, no identity.
  * Preamble-only subsampling ALSO lowers the unambiguous Doppler ceiling
    (fs_pkt / duty / 2): size the packet/preamble rate so the expected
    threat Doppler stays unambiguous, or accept aliased Doppler lines.
  * Micro-Doppler is NEVER used for identity (Kozlov et al., Sci. Rep.
    2026 -- spoofable by a PCB-scale device). Blade-flash is one
    corroborating classifier feature behind an RCS-reasonableness gate.
  * The ~110 dB zero-Doppler cancellation milestone (passive_radar.py)
    stays FIRST. This module is the designated no-clean-reference
    fallback, not a replacement for the two-channel PCL path.

DEFENSIVE-ONLY: this chain listens to signals of opportunity and scores
them. It never transmits, jams, deauths, or spoofs.

WIRE SCHEMA (shared with the sdr_bridge WPP-IDP estimator):
wpp_idp_doppler events carry v / kind / radio / band / doppler_hz /
strength / t / motion_state -- the schema the app's
WppIdpDoppler.tryParse decodes. One deliberate difference between the
two producers: doppler_hz here is SIGNED (positive = inbound vs the
Tx-Rx baseline, negative = outbound) because the baseline geometry is
known; the bridge's wpp_idp_detect.py emits doppler_hz as a MAGNITUDE
(>= 0) because its real-valued energy time series has a symmetric
spectrum and the sign is ambiguous there (resolved app-side against
track geometry). The app decoder accepts both.

Needs: numpy only. No SDR hardware required for --demo.
"""

import argparse
import json
import sys
import time

import numpy as np

# ---------------------------------------------------------------- constants

# Class-parameterized coherent processing intervals for the blade-flash
# feature extractor. Pusher-prop (Shahed-class, Group 2-3 mission target)
# blade modulation is WEAKER than multirotor lifting-blade modulation
# (Yan et al., Drones 2023 -- CLAIMED-from-snippets, exact DFD/DMR numbers
# unverified), so the pusher-prop class gets the LONGER CPI. Exact
# DFD/DMR thresholds are deliberately NOT asserted here.
BLADE_CLASSES = {
    # class: (cpi_s, description)
    "pusher_prop":  (1.00, "Shahed-class pusher prop: weaker modulation, "
                           "longer CPI budgeted"),
    "multirotor":   (0.25, "multirotor lifting blades: stronger modulation, "
                           "shorter CPI suffices"),
}

EVENT_KIND = "wpp_idp_doppler"


# ---------------------------------------------------------------- simulation

def simulate_energy(fs_pkt, duration_s, rng, doppler_hz=40.0, bnr_db=35.0,
                    target=True, waveform="dsss", preamble_duty=8,
                    seed_phase=0.0):
    """Synthetic per-packet/preamble energy time series E[n].

    Model: E[n] = E_dc + s[n] + w[n], where s[n] is the slow interference
    modulation between the direct AP signal and the target echo,
        s[n] = A * cos(2*pi*doppler_hz*t_n + phi_n),
    and BNR (beacon-to-noise ratio, dB) = 10*log10((A^2/2) / sigma_w^2).

    waveform selects the per-packet phase rule (the WPP rule):
      "dsss"         phi_n constant  -- deterministic DSSS beacons,
                                     coherent integration works.
      "ofdm_full"    phi_n random per packet -- random data symbols
                     randomize the interference (white, no spectral
                     line). This is the deliberately-broken mode.
      "ofdm_preamble" keep every preamble_duty-th packet (preamble
                     portions only), phi_n constant on kept packets.
                     Coherent again, but fewer samples -> an integration
                     penalty in principle (~7 dB in the paper). MEASURED
                     here: 0 dB penalty for duty 8 at the test BNRs
                     (test_wpp_idp.py::test_waveform_rule_parity) -- the
                     synthetic scene (constant phase, white noise, no
                     DNR^2 worsening) is kinder than the paper's real
                     captures, so the measured penalty is not the
                     paper's number and is not quoted as one.

    Returns (t, E, truth) with truth = {"doppler_hz": ...} or None.
    """
    if waveform not in ("dsss", "ofdm_full", "ofdm_preamble"):
        raise ValueError(f"unknown waveform {waveform!r}")

    if waveform == "ofdm_preamble":
        fs_eff = fs_pkt / preamble_duty
    else:
        fs_eff = fs_pkt
    n = int(round(fs_eff * duration_s))
    t = np.arange(n) / fs_eff

    sigma_w = 1.0
    a = np.sqrt(2.0 * 10.0 ** (bnr_db / 10.0)) * sigma_w if target else 0.0

    if waveform == "ofdm_full":
        phi = rng.uniform(0.0, 2.0 * np.pi, size=n) if target \
            else np.zeros(n)
    else:
        phi = np.full(n, seed_phase) if target else np.zeros(n)

    e_dc = 100.0  # strong static direct-path pedestal (DC removal kills it)
    s = a * np.cos(2.0 * np.pi * doppler_hz * t + phi) if target \
        else np.zeros(n)
    w = rng.standard_normal(n) * sigma_w
    e = e_dc + s + w

    truth = {"doppler_hz": doppler_hz, "bnr_db": bnr_db,
             "waveform": waveform} if target else None
    return t, e, truth


def simulate_static(fs_pkt, duration_s, rng, clutter_db=20.0,
                    waveform="dsss", preamble_duty=8):
    """Static scene: direct path + fixed clutter, NO target.

    Everything is zero-Doppler, so DC removal must leave only noise and
    the detector must report zero lines. Used by the DC-removal
    regression test (10/10 static runs clean).
    """
    if waveform == "ofdm_preamble":
        fs_eff = fs_pkt / preamble_duty
    else:
        fs_eff = fs_pkt
    n = int(round(fs_eff * duration_s))
    e_dc = 100.0
    clutter = 10.0 ** (clutter_db / 20.0)   # strong fixed scatterer, DC too
    e = e_dc + clutter + rng.standard_normal(n)
    return np.arange(n) / fs_eff, e


def simulate_blade_flash(fs_pkt, duration_s, rng, flash_hz, snr_db=20.0):
    """Synthetic blade-flash energy series: AM tone at the flash rate."""
    n = int(round(fs_pkt * duration_s))
    t = np.arange(n) / fs_pkt
    a = np.sqrt(2.0 * 10.0 ** (snr_db / 10.0))
    e = a * np.cos(2.0 * np.pi * flash_hz * t) + rng.standard_normal(n)
    return t, e


# ---------------------------------------------------------------- processing

def dc_remove(e):
    """Strip the static pedestal: direct path + stationary clutter.

    The paper's DC-removal step. Operates per processing block; the slow
    target modulation (non-zero Doppler) survives, the zero-Doppler
    pedestal does not.
    """
    e = np.asarray(e, dtype=float)
    return e - np.mean(e)


def stft_power(x, fs, cpi_s, hop_s=None):
    """Hann-windowed STFT power spectrogram of the residual.

    Returns (freqs_hz, times_s, power) with power[f, k] = |X|^2 for frame k.
    """
    x = np.asarray(x, dtype=float)
    n_win = max(8, int(round(cpi_s * fs)))
    hop = int(round((hop_s if hop_s else cpi_s / 2.0) * fs))
    hop = max(1, hop)
    if len(x) < n_win:
        raise ValueError("series shorter than one CPI window")
    win = np.hanning(n_win)
    n_frames = 1 + (len(x) - n_win) // hop
    freqs = np.fft.rfftfreq(n_win, d=1.0 / fs)
    power = np.empty((len(freqs), n_frames), dtype=float)
    for k in range(n_frames):
        seg = x[k * hop:k * hop + n_win] * win
        spec = np.fft.rfft(seg)
        power[:, k] = np.abs(spec) ** 2
    times = (np.arange(n_frames) * hop + n_win / 2) / fs
    return freqs, times, power


def _cfar_threshold_alpha(pfa_per_frame, n_bins):
    """CFAR-style threshold multiplier on an exponential noise floor.

    Noise power per bin is exponential; floor is estimated by
    median/ln(2) (robust to the line itself). alpha = -ln(PFA/n_bins)
    gives the requested per-frame false-alarm rate for a flat floor.
    """
    return -np.log(pfa_per_frame / n_bins)


def detect_doppler_lines(freqs, times, power, f_min_hz=5.0, f_max_hz=None,
                         pfa_per_frame=1e-4):
    """CFAR-style Doppler-line detector on the STFT power spectrogram.

    For each frame: noise floor = median/ln(2) over unmasked bins,
    threshold = alpha * floor, local maxima above threshold are lines.
    The |f| <= f_min_hz band is masked (DC residue / static clutter).
    Returns a list of dicts: {t_s, doppler_hz, strength_db}.
    strength_db is the peak's margin above the frame threshold, in dB.
    """
    freqs = np.asarray(freqs)
    keep = freqs >= f_min_hz
    if f_max_hz is not None:
        keep &= freqs <= f_max_hz
    if not np.any(keep):
        return []
    f = freqs[keep]
    p = power[keep, :]
    n_bins = p.shape[0]
    alpha = _cfar_threshold_alpha(pfa_per_frame, n_bins)

    dets = []
    for k in range(p.shape[1]):
        col = p[:, k]
        floor = np.median(col) / np.log(2.0)
        if floor <= 0:
            continue
        thresh = alpha * floor
        # local maxima (interior bins), above threshold
        interior = np.arange(1, n_bins - 1)
        is_peak = (col[interior] >= col[interior - 1]) & \
                  (col[interior] >= col[interior + 1]) & \
                  (col[interior] > thresh)
        for i in interior[is_peak]:
            margin_db = 10.0 * np.log10(col[i] / thresh)
            dets.append({"t_s": float(times[k]),
                         "doppler_hz": float(f[i]),
                         "strength_db": float(margin_db)})
    dets.sort(key=lambda d: -d["strength_db"])
    return dets


def run_idp(e, fs, cpi_s=0.5, f_min_hz=5.0, f_max_hz=None,
            pfa_per_frame=1e-4):
    """Full WPP-IDP chain: DC removal -> STFT -> Doppler-line detector."""
    t0 = time.time()
    resid = dc_remove(e)
    freqs, times, power = stft_power(resid, fs, cpi_s)
    dets = detect_doppler_lines(freqs, times, power, f_min_hz=f_min_hz,
                                f_max_hz=f_max_hz,
                                pfa_per_frame=pfa_per_frame)
    return {"detections": dets, "n_frames": len(times),
            "elapsed_s": time.time() - t0}


def blade_flash_detect(e, fs, target_class):
    """Blade-flash feature extractor with CLASS-PARAMETERIZED CPI.

    Pusher-prop (Shahed-class) automatically gets the longer CPI because
    its blade modulation is weaker (Yan et al. -- CLAIMED-from-snippets).
    Exact DFD/DMR thresholds are NOT asserted; this resolves the flash
    line with the class's CPI and reports which CPI was used.

    Returns {"flash_hz": est or None, "cpi_s": used, "class": name}.
    Micro-Doppler is NEVER used for identity -- this is one corroborating
    classifier feature behind an RCS-reasonableness gate.
    """
    if target_class not in BLADE_CLASSES:
        raise ValueError(f"unknown blade class {target_class!r}; "
                         f"expected one of {sorted(BLADE_CLASSES)}")
    cpi_s, _desc = BLADE_CLASSES[target_class]
    e = np.asarray(e, dtype=float)
    n_win = int(round(cpi_s * fs))
    if len(e) < n_win:
        raise ValueError("series shorter than the class CPI")
    seg = dc_remove(e[:n_win]) * np.hanning(n_win)
    spec = np.abs(np.fft.rfft(seg)) ** 2
    freqs = np.fft.rfftfreq(n_win, d=1.0 / fs)
    keep = freqs >= 10.0
    f, p = freqs[keep], spec[keep]
    alpha = _cfar_threshold_alpha(1e-4, len(f))
    floor = np.median(p) / np.log(2.0)
    thresh = alpha * floor
    interior = np.arange(1, len(f) - 1)
    is_peak = (p[interior] >= p[interior - 1]) & \
              (p[interior] >= p[interior + 1]) & (p[interior] > thresh)
    cands = interior[is_peak]
    if len(cands) == 0:
        return {"flash_hz": None, "cpi_s": cpi_s, "class": target_class}
    best = cands[int(np.argmax(p[cands]))]
    return {"flash_hz": float(f[best]), "cpi_s": cpi_s,
            "class": target_class}


# ---------------------------------------------------------------- events

def doppler_event(radio, band, doppler_hz, strength, t,
                  motion_state="static"):
    """Build the wpp_idp_doppler event dict (UDP JSON to the app).

    Wire schema -- shared with the bridge's WppIdpEstimator events; this
    is the schema the app's WppIdpDoppler.tryParse decodes (it was built
    to the bridge variant, so everything aligns to it). Field names:
    v / kind / radio / band / doppler_hz / strength / t / motion_state,
    plus direction_vs_baseline, merger_eligible, evidence (app ignores
    unknown extra fields). The node id rides in "radio".

    Signed-vs-magnitude convention (documented at both ends):
      * passive_radar (this module): doppler_hz is SIGNED where the
        Tx-Rx baseline geometry is known -- > 0 means the bistatic
        range-sum is shrinking (INBOUND vs the baseline), < 0 means
        OUTBOUND. direction_vs_baseline carries the same call.
      * sdr_bridge (wpp_idp_detect.py): doppler_hz is a MAGNITUDE
        (>= 0). The bridge works from a real energy time series whose
        spectrum is symmetric, so inbound/outbound is ambiguous at that
        stage -- resolved app-side against track geometry.
    The app decoder accepts both: it never asserts a sign; bridge-side
    sign ambiguity is resolved against track geometry app-side.

    motion_state must be "static" for detections to be merger-eligible;
    moving-node outputs are R&D logging only (ego-motion is an open
    problem -- the paper assumes a static receiver).
    """
    direction = ("inbound" if doppler_hz > 0 else
                 "outbound" if doppler_hz < 0 else "unknown")
    return {
        "v": 1,
        "kind": EVENT_KIND,
        "radio": radio,
        "band": band,
        "doppler_hz": float(doppler_hz),
        "strength": float(strength),
        "t": float(t),
        "direction_vs_baseline": direction,
        "motion_state": motion_state,
        "merger_eligible": bool(motion_state == "static"),
        "evidence": ("WPP-IDP Doppler line (single-channel, no clean "
                     "reference). Disturbance consistent with a moving "
                     "reflector near the Tx-Rx baseline -- not an identity. "
                     "Meters-to-tens-of-meters geometry."),
    }


# ---------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description="WPP-IDP single-channel "
                                 "passive radar (RX-only)")
    ap.add_argument("--demo", action="store_true",
                    help="synthetic DSSS scene with known truth "
                         "(default if no input file given)")
    ap.add_argument("--input", default="",
                    help=".npy energy time series E[n] (float)")
    ap.add_argument("--waveform", default="dsss",
                    choices=["dsss", "ofdm_full", "ofdm_preamble"],
                    help="phase rule for the synthetic scene "
                         "(default dsss)")
    ap.add_argument("--doppler", type=float, default=40.0,
                    help="synthetic target Doppler, Hz (default 40)")
    ap.add_argument("--bnr", type=float, default=35.0,
                    help="synthetic beacon-to-noise ratio, dB (default 35)")
    ap.add_argument("--fs-pkt", type=float, default=2000.0,
                    help="packet/preamble energy sample rate, Hz "
                         "(default 2000; must exceed 2x the expected "
                         "Doppler after preamble subsampling -- the "
                         "synthetic demo compresses time; real 802.11 "
                         "beacons are ~10 Hz)")
    ap.add_argument("--duration", type=float, default=4.0,
                    help="synthetic scene length, s (default 4)")
    ap.add_argument("--cpi", type=float, default=0.5,
                    help="STFT coherent processing interval, s (default 0.5)")
    ap.add_argument("--json", action="store_true", help="emit JSON only")
    ap.add_argument("--node-id", default="demo-node",
                    help="node id stamped on emitted events")
    ap.add_argument("--band", default="2.4GHz",
                    help="band label stamped on emitted events")
    args = ap.parse_args()

    if args.input:
        e = np.asarray(np.load(args.input), dtype=float).ravel()
        fs = args.fs_pkt  # sample rate of the provided series
        truth = None
        wf = "provided"
    else:
        rng = np.random.default_rng(7)
        _t, e, truth = simulate_energy(
            args.fs_pkt, args.duration, rng, doppler_hz=args.doppler,
            bnr_db=args.bnr, target=True, waveform=args.waveform)
        fs = args.fs_pkt / (8 if args.waveform == "ofdm_preamble" else 1)
        wf = args.waveform
        if not args.json:
            print(f"[demo] waveform={wf} truth: doppler "
                  f"{truth['doppler_hz']:+.1f} Hz at BNR {truth['bnr_db']:.0f} "
                  f"dB, E[{len(e)}] @ {fs:.0f} Hz")

    res = run_idp(e, fs, cpi_s=args.cpi)
    dets = res["detections"]
    events = [doppler_event(radio=args.node_id, band=args.band,
                            doppler_hz=d["doppler_hz"],
                            strength=d["strength_db"], t=d["t_s"])
              for d in dets]

    if args.json:
        print(json.dumps({"truth": truth, "waveform": wf,
                          "detections": dets, "events": events}, indent=1))
        return

    print(f"[idp] {res['n_frames']} STFT frames in {res['elapsed_s']:.2f}s, "
          f"{len(dets)} Doppler line(s)")
    if not dets:
        print("DETECTIONS: none")
    else:
        print(f"DETECTIONS ({len(dets)}):")
        for k, d in enumerate(dets[:8]):
            direction = ("INBOUND " if d["doppler_hz"] > 0 else "OUTBOUND")
            print(f"  #{k+1}  doppler {d['doppler_hz']:+7.1f} Hz "
                  f"({direction} vs baseline)  "
                  f"strength +{d['strength_db']:5.1f} dB  t={d['t_s']:.2f}s")

    if truth is not None and args.waveform == "dsss":
        if not dets:
            print("RESULT: FAIL -- synthetic target not detected")
            sys.exit(1)
        best = dets[0]
        f_err = abs(best["doppler_hz"] - truth["doppler_hz"]) \
            / abs(truth["doppler_hz"])
        ok = f_err <= 0.20
        print(f"RESULT: {'PASS' if ok else 'FAIL'} -- doppler err "
              f"{100*f_err:.1f}% (tolerance 20%)")
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
