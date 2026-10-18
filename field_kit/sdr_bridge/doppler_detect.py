#!/usr/bin/env python3
"""Ambient-LTE Doppler tracker — RX-only DSP for the SDR bridge.

Listens to an LTE downlink carrier the operator's carrier transmits
anyway (1.8-1.9 GHz stare) and measures what moving reflectors do to
it. This module RECEIVES ONLY:

  * no transmission, no jamming, no deauthentication, no spoofing --
    there is no TX code path anywhere in this file or in the bridge;
  * no decoding of user payload content -- the DSP needs only the
    waveform's phase structure as a reference, never its bits;
  * no interaction with the eNodeB and no modification of any network.

Signal chain (per 0.5 s coherent processing interval):

    CPI buffer (complex baseband)
      -> reference tap: the strongest static component near DC
         (the direct-path LTE signal) is estimated from a rectangular
         FFT ...
      -> surveillance: the same buffer with the reference tone
         subtracted in the time domain (adaptive clutter cancellation),
         then a belt-and-braces notch of its FFT bins ...
      -> Doppler spectrum: Hann-windowed FFT across the CPI
         (2 Hz bins: Doppler resolution comes from *time*, not
         bandwidth -- the whole economic argument for this feature)
      -> peak detect: strongest bin above the SNR gate
         -> (doppler_hz, radial_ms, snr_db)

Sign convention (documented, matches the app tracker's velocity sign):
APPROACHING = NEGATIVE. The physical frequency increase produced by an
approaching reflector is reported negated, so both doppler_hz and
radial_ms are negative for inbound motion:
    radial_ms = doppler_hz * c / (2 * center_hz).

Output: at most ONE doppler_ref event per CPI while a peak persists;
nothing at all when the reference is locked and no peak clears the
gate (idle = silent, like the ELRS detectors). If the direct-path
reference is lost, one status event with ref_locked=false is emitted
per CPI -- without the reference there is no coherent measurement, and
the app must give such events zero weight.

Event schema (UDP JSON -> 127.0.0.1:49161, like the other bridge events):
    {"v":1,"kind":"doppler_ref","radio":"rtlsdr0",
     "center_mhz":1865.0,"doppler_hz":-14.2,"radial_ms":-1.14,
     "snr_db":11.3,"ref_locked":true,"t":1729123456.789}

Honest-scope notes (do not quote beyond these):

  * Radial velocity ONLY. No position, no identity, no imagery. One
    Doppler history is a line, not a fix. The sub-meter numbers in Ji
    et al. (arXiv:2602.08203) came from *dual*-bistatic fusion with
    USRPs at < 30 m with known initialization -- this single-geometry,
    single-radio channel inherits NONE of that accuracy. The output is
    "motion consistent with the track", full stop.
  * Geometry-dependent: tangential motion is Doppler-invisible to a
    given radio<->eNB pair. A null return is uninformative, never
    exonerating -- disagreement semantics live app-side (the merger is
    never subtractive); the bridge just emits measurements.
  * LTE-dependent: no ambient LTE downlink at usable strength -> no
    reference -> no feature. ref_locked=false says so explicitly.
  * RCS reality: sensitivity math for this channel MUST be computed
    against the payload-stripped RCS assumption (Ji et al.'s FEKO
    result: removing the payload degrades RCS by ~22 dB), never
    against a brochure airframe number. A missed return on a
    payload-released, RF-quiet target is the expected outcome, not
    evidence the track is false.
  * Minimum detectable radial speed ~= 0.5 m/s (the +/-3-bin reference
    notch spans +/-6 Hz ~= +/-0.48 m/s at 1.86 GHz).
  * Clock: Doppler needs frequency stability << 2 Hz over the 0.5 s
    CPI (RTL-SDR TCXO-class is adequate at 1.86 GHz); documented as a
    requirement, not assumed.
  * Narrowband spurs inside the +/-400 Hz search band are
    indistinguishable from movers in a single CPI -- the app-side
    DopplerCorrelator (agreement of observed vs track-predicted radial
    velocity, >= 2 agreements or one high-SNR agreement) is the
    disambiguator. This module reports peaks; it does not decide what
    they are.

How it plugs in: sdr_bridge.py feeds captures from a 1.8-1.9 GHz stare
to DopplerTracker.observe(). The tracker assembles 0.5 s CPIs from the
consecutive captures (no retune between them) and returns UDP-ready
event dicts. A --simulate Doppler emitter (SimBackend, 1865 MHz band)
provides the hardware-free demo path.
"""

import math

import numpy as np

C = 299_792_458.0  # m/s

CPI_S = 0.5            # coherent processing interval -> 2 Hz Doppler bins
REF_SEARCH_HZ = 25.0   # reference tap: strongest peak within +/- this of DC
REF_LOCK_DB = 15.0     # ... this far above the spectral median to count
NOTCH_BINS = 3         # clutter notch half-width around the reference
MAX_DOPPLER_HZ = 400.0  # search band: ~ +/-32 m/s radial at 1.86 GHz
SNR_GATE_DB = 14.0     # peak-to-median gate on the clutter-canceled floor
# (14 dB: the expected worst noise peak over 200 CPIs x 800 bins is
# ~12.4 dB, so the gate keeps the detector silent on static scenes
# while a 20 dB mover clears it with margin.)


class DopplerTracker:
    """Per-bridge ambient-LTE Doppler tracker.

    Feed captures via observe(); collect throttled doppler_ref events.
    One detector instance serves all radios (state is per radio id).
    """

    def __init__(self):
        self._st = {}  # radio -> {"buf": complex64, "fs": float}

    @staticmethod
    def _event(radio, center_mhz, t, doppler_hz, radial_ms, snr_db,
               ref_locked):
        return {"v": 1, "kind": "doppler_ref", "radio": radio,
                "center_mhz": float(center_mhz),
                "doppler_hz": round(float(doppler_hz), 1),
                "radial_ms": round(float(radial_ms), 3),
                "snr_db": round(float(snr_db), 1),
                "ref_locked": bool(ref_locked), "t": float(t)}

    def observe(self, radio, center_mhz, t, x, fs_hz):
        """Feed one capture; returns a list of UDP-ready event dicts.

        Captures are accumulated per radio until a 0.5 s CPI is whole;
        each completed CPI yields at most one event. Feeding is cheap
        (a concatenate); the FFT work happens once per CPI.
        """
        x = np.asarray(x, dtype=np.complex64).ravel()
        if x.size == 0:
            return []
        fs = float(fs_hz)
        if not (math.isfinite(fs) and fs > 0):
            return []
        st = self._st.get(radio)
        if st is None or st["fs"] != fs:
            # New radio, or the sample rate changed: the buffered
            # samples are no longer time-compatible. Restart clean.
            st = {"buf": np.zeros(0, dtype=np.complex64), "fs": fs}
            self._st[radio] = st
        st["buf"] = np.concatenate([st["buf"], x])
        cpi_n = int(round(fs * CPI_S))
        events = []
        while st["buf"].size >= cpi_n:
            cpi = st["buf"][:cpi_n]
            st["buf"] = st["buf"][cpi_n:]
            events.extend(self._process_cpi(radio, float(center_mhz),
                                            float(t), cpi, fs))
            # Defensive cap: the buffer should never hold more than a
            # CPI plus one capture; if it does, drop the oldest.
            if st["buf"].size > 2 * cpi_n:
                st["buf"] = st["buf"][-2 * cpi_n:]
        return events

    def _process_cpi(self, radio, center_mhz, t, x, fs):
        n = x.size
        if n < 64 or not np.all(np.isfinite(x)):
            return []  # bad capture: never report as data
        if not (math.isfinite(center_mhz) and center_mhz > 0):
            return []
        bin_hz = fs / n  # == 2.0 for a full CPI
        freqs = np.fft.fftfreq(n, d=1.0 / fs)

        # -- reference tap: strongest static component near DC. The
        #    rectangular FFT reads an on-bin tone's exact complex
        #    amplitude, which the cancellation step needs.
        Xr = np.fft.fft(x)
        Pr = np.abs(Xr).astype(np.float64) ** 2
        in_ref = np.abs(freqs) <= REF_SEARCH_HZ
        ref_cands = np.flatnonzero(in_ref)
        if ref_cands.size == 0:
            return []
        ref_idx = int(ref_cands[int(np.argmax(Pr[in_ref]))])
        p_ref = float(Pr[ref_idx])
        med_all = float(np.median(Pr)) + 1e-30
        if p_ref <= 0.0:
            # Degenerate all-zero capture: no reference, no measurement.
            return [self._event(radio, center_mhz, t,
                                0.0, 0.0, 0.0, False)]
        ref_snr = 10.0 * math.log10(p_ref / med_all)
        if ref_snr < REF_LOCK_DB:
            # Reference lost: no coherent measurement is possible this
            # CPI, so no peak search either. The status event tells the
            # app within one CPI; the app must give it zero weight.
            return [self._event(radio, center_mhz, t,
                                0.0, 0.0, 0.0, False)]

        # -- clutter cancellation: subtract the estimated reference tone
        #    in the time domain.
        f_ref = float(freqs[ref_idx])
        amp = Xr[ref_idx] / n
        tt = np.arange(n, dtype=np.float64) / fs
        x_surv = (x - (amp * np.exp(2j * np.pi * f_ref * tt))
                  .astype(np.complex64))

        # -- Doppler spectrum across the CPI (Hann: -31 dB sidelobes so
        #    the reference residual can't fake movers elsewhere).
        win = np.hanning(n).astype(np.float32)
        Xs = np.fft.fft((x_surv * win).astype(np.complex64))
        P = np.abs(Xs).astype(np.float64) ** 2
        notch = np.abs(freqs - f_ref) <= NOTCH_BINS * bin_hz
        search = (np.abs(freqs) <= MAX_DOPPLER_HZ) & (~notch)
        sidx_all = np.flatnonzero(search)
        if sidx_all.size < 8:
            return []
        Ps = P[search]
        med = float(np.median(Ps)) + 1e-30
        ki = int(np.argmax(Ps))
        p_peak = float(Ps[ki])
        if p_peak <= 0.0:
            return []  # numerical dust only: silent
        snr = 10.0 * math.log10(p_peak / med)
        if snr < SNR_GATE_DB:
            return []  # idle: silent

        # -- sub-bin Doppler via parabolic interpolation on log power.
        sidx = int(sidx_all[ki])
        i0, i2 = (sidx - 1) % n, (sidx + 1) % n
        y0 = math.log10(float(P[i0]) + 1e-30)
        y1 = math.log10(p_peak + 1e-30)
        y2 = math.log10(float(P[i2]) + 1e-30)
        den = y0 - 2.0 * y1 + y2
        off = 0.5 * (y0 - y2) / den if den < 0.0 else 0.0
        off = max(-0.5, min(0.5, off))
        f_phys = float(freqs[sidx]) + off * bin_hz
        # Approaching = negative (app convention): the physical
        # frequency increase of an approaching echo is reported negated.
        doppler_hz = -f_phys
        radial_ms = doppler_hz * C / (2.0 * center_mhz * 1e6)
        return [self._event(radio, center_mhz, t, doppler_hz, radial_ms,
                            snr, True)]
