#!/usr/bin/env python3
"""
Shepherd passive-radar prototype -- RECEIVE ONLY. Nothing here transmits.

Passive coherent location (PCL): one antenna listens to a broadcast
illuminator (FM / DVB-T / DAB / LTE) directly -- the *reference* channel.
A second antenna listens for that same signal reflected off a moving
target -- the *surveillance* channel. The cross-ambiguity function
(delay x Doppler) of the two channels makes movers pop out of clutter,
and CFAR detection reports them as (bistatic range, Doppler velocity).

Modes:
  --demo            fully synthetic: DVB-T-like OFDM illuminator, one moving
                    target with KNOWN delay + Doppler, ground clutter, direct-
                    path breakthrough, noise. The pipeline must DETECT the
                    target; the demo asserts range/Doppler within 10% of truth.
  --ref/--surv      offline processing of real captures (.npy, complex64,
                    shape (N,) or (2, N)), e.g. recorded by b210_capture.py.

Needs: numpy, scipy. No SDR hardware required for --demo.

This is an R&D prototype, not a fielded capability. See README.md for the
honest performance picture (best published drone result ~1,600 m bistatic,
single-source REPORTED; brochures exceed measured literature ~100x).
"""

import argparse
import json
import sys
import time

import numpy as np
from scipy.ndimage import maximum_filter, uniform_filter

C = 299_792_458.0  # m/s


# ---------------------------------------------------------------- signal gen

def ofdm_illuminator(n, rng, k=1024, cp=None):
    """DVB-T-like OFDM: random QPSK over k subcarriers + cyclic prefix.

    Noise-like ambiguity function, flat spectrum -- the properties that make
    broadcast OFDM a good illuminator of opportunity.
    """
    cp = cp or k // 8
    sym_len = k + cp
    # random QPSK symbols
    n_sym = n // sym_len + 2
    bits = rng.integers(0, 4, size=(n_sym, k))
    qpsk = np.exp(1j * (np.pi / 4 + bits * np.pi / 2)) / np.sqrt(2.0)
    # time-domain symbols with cyclic prefix
    td = np.fft.ifft(np.fft.ifftshift(qpsk, axes=1), axis=1)
    frames = np.concatenate([td[:, -cp:], td], axis=1)
    x = frames.reshape(-1)[:n].astype(np.complex64)
    x /= np.sqrt(np.mean(np.abs(x) ** 2))  # unit average power
    return x


def simulate(fs, cpi, rng, target_delay_us=12.5, target_doppler_hz=150.0,
             target_db=-35.0, seed=7):
    """Build (reference, surveillance) for the demo scene.

    Scene: direct-path breakthrough at 0 dB, two zero-Doppler clutter
    scatterers, one moving target at (target_delay_us, target_doppler_hz),
    complex AWGN. Returns ref, surv, and a truth dict.
    """
    n = int(fs * cpi)
    ref = ofdm_illuminator(n, rng)

    d_tgt = int(round(target_delay_us * 1e-6 * fs))
    a_tgt = 10 ** (target_db / 20.0)
    t = np.arange(n) / fs

    surv = np.zeros(n, dtype=np.complex64)
    surv += ref                                     # direct path, 0 dB
    for d_us, pdb in ((3.0, -12.0), (7.5, -15.0)):  # ground clutter
        d = int(round(d_us * 1e-6 * fs))
        surv[d:] += ref[:n - d] * 10 ** (pdb / 20.0)
    # moving target: delayed + Doppler-shifted echo
    dop = np.exp(2j * np.pi * target_doppler_hz * t).astype(np.complex64)
    surv[d_tgt:] += ref[:n - d_tgt] * dop[d_tgt:] * a_tgt
    # receiver noise
    surv += (rng.standard_normal(n) + 1j * rng.standard_normal(n)).astype(
        np.complex64) * 10 ** (-20.0 / 20.0) / np.sqrt(2.0)

    truth = {
        "delay_us": d_tgt / fs * 1e6,
        "doppler_hz": target_doppler_hz,
        "range_m": d_tgt / fs * C,          # bistatic range = c * delay
    }
    return ref, surv, truth


# ---------------------------------------------------------------- processing

def cancel_clutter(ref, surv, fs, max_delay_s=30e-6, n_taps=12):
    """Extensive-cancellation-lite: kill direct path AND strong clutter.

    Real PCL systems (the ECA family) do this: find the strongest
    zero-Doppler taps from the CAF's zero-Doppler row, least-squares fit
    their coefficients jointly, and subtract them. This removes the
    direct breakthrough and the discrete clutter whose OFDM sidelobes
    would otherwise stripe the whole Doppler axis at their delays.
    The moving target lives at non-zero Doppler, so its taps are never
    selected from the zero-Doppler row.
    """
    n = len(ref)
    max_d = int(round(max_delay_s * fs))
    r_fft = np.fft.fft(ref, 2 * n)
    zero_row = np.abs(
        np.fft.ifft(np.fft.fft(surv, 2 * n) * np.conj(r_fft))[:max_d + 1]
    ) ** 2
    # strongest local-maximum taps on the zero-Doppler row
    is_peak = maximum_filter(zero_row, size=3) == zero_row
    cands = np.argwhere(is_peak).ravel()
    cands = cands[np.argsort(-zero_row[cands])][:n_taps]
    taps = sorted(int(c) for c in cands)
    # joint least-squares fit of all tap coefficients
    a = np.zeros((n, len(taps)), dtype=np.complex64)
    for j, d in enumerate(taps):
        a[d:, j] = ref[:n - d]
    w, *_ = np.linalg.lstsq(a, surv, rcond=None)
    return surv - a @ w, taps


def cross_ambiguity(ref, surv, fs, max_delay_s, dopplers_hz):
    """|CAF(delay, doppler)|^2 via FFT fast correlation.

    CAF(tau, f) = |sum_n surv[n] * conj(ref[n-tau]) * exp(-j*2*pi*f*n/fs)|^2
    Standard PCL convention: the target echo (delay D, Doppler f_d) peaks
    at (tau = D, f = f_d).
    """
    n = len(ref)
    max_d = int(round(max_delay_s * fs))
    r_fft = np.fft.fft(ref, 2 * n)
    out = np.zeros((max_d + 1, len(dopplers_hz)), dtype=np.float32)
    nn = np.arange(n)
    for j, f in enumerate(dopplers_hz):
        comp = surv * np.exp(-2j * np.pi * f * nn / fs).astype(np.complex64)
        corr = np.fft.ifft(np.fft.fft(comp, 2 * n) * np.conj(r_fft))
        out[:, j] = np.abs(corr[:max_d + 1]) ** 2
    return out


def cfar_detect(power, pfa=1e-6, mask_doppler_hz=15.0, dopplers_hz=None):
    """Cell-averaging CFAR on the CAF power surface.

    Training window 17x9 minus 5x3 guard; the zero-Doppler rows are masked
    (ground clutter lives there even after cancellation). Returns a list of
    (delay_idx, doppler_idx, power) local-maximum detections.
    """
    nd, nf = power.shape
    ow, gw = (17, 9), (5, 3)          # outer / guard window sizes
    m = ow[0] * ow[1] - gw[0] * gw[1]  # training cells
    alpha = m * (pfa ** (-1.0 / m) - 1.0)

    sum_outer = uniform_filter(power, size=ow, mode="constant") * ow[0] * ow[1]
    sum_guard = uniform_filter(power, size=gw, mode="constant") * gw[0] * gw[1]
    thresh = alpha * (sum_outer - sum_guard) / m

    det = power > thresh
    # full window support only (no edge under-estimates)
    det[:ow[0] // 2 + 1, :] = False
    det[-(ow[0] // 2):, :] = False
    det[:, :ow[1] // 2 + 1] = False
    det[:, -(ow[1] // 2):] = False
    # mask the clutter ridge
    if dopplers_hz is not None:
        det[:, np.abs(dopplers_hz) <= mask_doppler_hz] = False

    peaks = (maximum_filter(power, size=3) == power) & det
    idx = np.argwhere(peaks)
    # strongest first
    order = np.argsort(-power[peaks])
    return [(int(i), int(j), float(power[i, j])) for i, j in idx[order]]


# ---------------------------------------------------------------- main

def run_pipeline(ref, surv, fs, fc_hz, max_delay_s=30e-6,
                 doppler_max_hz=250.0, doppler_step_hz=5.0, verbose=True):
    """Full chain: cancel -> CAF -> CFAR. Returns detection dicts."""
    t0 = time.time()
    surv_c, taps = cancel_clutter(ref, surv, fs)
    dopplers = np.arange(-doppler_max_hz, doppler_max_hz + 1e-9,
                         doppler_step_hz)
    caf = cross_ambiguity(ref, surv_c, fs, max_delay_s, dopplers)
    dets = cfar_detect(caf, dopplers_hz=dopplers)
    lam = C / fc_hz
    out = []
    for di, fi, p in dets:
        delay_s = di / fs
        fd = float(dopplers[fi])
        out.append({
            "delay_us": delay_s * 1e6,
            "bistatic_range_m": delay_s * C,
            # bistatic bisector velocity, monostatic-equivalent approx
            "doppler_hz": fd,
            "velocity_ms": fd * lam / 2.0,
            "power": p,
        })
    if verbose:
        print(f"[pipeline] cancelled {len(taps)} clutter taps, "
              f"CAF {caf.shape[0]} delays x {caf.shape[1]} "
              f"doppler bins in {time.time()-t0:.1f}s, "
              f"{len(out)} CFAR detection(s)")
    return out


def main():
    ap = argparse.ArgumentParser(description="Shepherd passive-radar "
                                 "prototype (RX-only)")
    ap.add_argument("--demo", action="store_true",
                    help="synthetic scene with known truth (default if no "
                         "files given)")
    ap.add_argument("--ref", default="", help=".npy reference channel")
    ap.add_argument("--surv", default="", help=".npy surveillance channel")
    ap.add_argument("--fs", type=float, default=2e6, help="sample rate Hz")
    ap.add_argument("--fc", type=float, default=600e6,
                    help="illuminator centre Hz (for velocity scaling)")
    ap.add_argument("--cpi", type=float, default=0.25,
                    help="coherent integration time, seconds (demo)")
    ap.add_argument("--json", action="store_true", help="emit JSON only")
    args = ap.parse_args()

    if args.ref and args.surv:
        ref = np.asarray(np.load(args.ref), dtype=np.complex64).ravel()
        surv = np.asarray(np.load(args.surv), dtype=np.complex64).ravel()
        n = min(len(ref), len(surv))
        ref, surv, truth = ref[:n], surv[:n], None
    else:
        rng = np.random.default_rng(7)
        ref, surv, truth = simulate(args.fs, args.cpi, rng)
        if not args.json:
            print(f"[demo] truth: delay={truth['delay_us']:.2f} us "
                  f"-> bistatic range {truth['range_m']:.0f} m, "
                  f"doppler {truth['doppler_hz']:.1f} Hz")

    dets = run_pipeline(ref, surv, args.fs, args.fc,
                        verbose=not args.json)
    if args.json:
        print(json.dumps({"truth": truth, "detections": dets}, indent=1))
        return

    if not dets:
        print("DETECTIONS: none")
    else:
        print(f"DETECTIONS ({len(dets)}):")
        for k, d in enumerate(dets[:8]):
            print(f"  #{k+1}  range {d['bistatic_range_m']:8.0f} m   "
                  f"doppler {d['doppler_hz']:+7.1f} Hz   "
                  f"vel ~{d['velocity_ms']:+6.1f} m/s")

    if truth is not None:
        if not dets:
            print("RESULT: FAIL -- synthetic target not detected")
            sys.exit(1)
        best = dets[0]
        r_err = abs(best["bistatic_range_m"] - truth["range_m"]) \
            / truth["range_m"]
        f_err = abs(best["doppler_hz"] - truth["doppler_hz"]) \
            / abs(truth["doppler_hz"])
        ok = r_err <= 0.10 and f_err <= 0.10
        print(f"RESULT: {'PASS' if ok else 'FAIL'} -- range err "
              f"{100*r_err:.1f}%, doppler err {100*f_err:.1f}% "
              f"(tolerance 10%)")
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
