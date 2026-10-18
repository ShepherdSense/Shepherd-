#!/usr/bin/env python3
"""WPP-IDP bridge-side per-preamble energy estimator — RX-only DSP.

This is the bridge-side half of the WPP-IDP (WiFi-Preamble-Processing,
Integrated Detection and Processing) passive-radar chain from Colone et
al., IEEE TAES 59(5), 2023 (read in full): detection and Doppler
estimation from ONE receive channel with no clean reference, no
demodulation, and no synchronization. The full STFT/CFAR chain lives in
the passive_radar workstream; this module is the bridge-side energy
estimator plus event emission. It RECEIVES ONLY -- no transmission, no
jamming, no deauthentication, no spoofing, no TX code path anywhere.

Chain (per the paper):

    capture stream
      -> per-preamble energy time series E[n]  (this module)
      -> WAVEFORM RULE (load-bearing, enforced structurally -- see below)
      -> DC removal on E[n]
      -> Doppler-line detector on the residual  (coarse bridge-side
         version; the full STFT/CFAR lives in passive_radar/)
      -> wpp_idp_doppler events

The physics: an illuminator of opportunity (e.g. a WiFi AP) reaches the
receiver directly (strong) and via a moving reflector (weak). The echo
interferes with the direct signal, impressing a slow amplitude
modulation at the Doppler difference onto the received energy. With no
reference channel, the classical cross-ambiguity function is
unavailable -- instead, per-packet (per-preamble) energy turns the slow
interference modulation into a time series, DC removal strips the
static pedestal, and the residual's spectrum reveals the Doppler line.

THE WAVEFORM RULE (Colone et al., CONFIRMED -- carried verbatim):

  * illuminator using DSSS beacons -> process ALL packets (near-ideal,
    BNR ~= 32.6 dB);
  * illuminator using OFDM (802.11n/ac/ax) -> PREAMBLE-ONLY: keep energy
    samples from the periodic, identical preamble portions and DISCARD
    the data-symbol portions. Random data symbols randomize the
    interference from symbol to symbol and destroy the coherent
    integration (BNR 52-57 dB, worsening as DNR^2 -- effectively
    unusable). Preamble-only processing restores determinism at a cost
    of ~7 dB SNR vs ideal (CONFIRMED paper result).

Enforcement: in "ofdm" mode the estimator reads only the first
preamble_frac of each energy slot (default 0.2 -> 10*log10(1/0.2) =
7.0 dB integration cost, documented not hidden); samples from the
data-symbol portion are NEVER read -- the exclusion is structural, not
a flag. Constructing the estimator in "ofdm" mode with
preamble_frac >= 1.0 raises ValueError. In "dsss" mode every slot is
used whole (preamble_frac is forced to 1.0).

Event schema (UDP JSON -> 127.0.0.1:49161):
    {"v":1,"kind":"wpp_idp_doppler","radio":"rtlsdr0","band":"2437",
     "center_mhz":2437.0,"doppler_hz":40.0,"strength":16.2,
     "t":1729123456.789,"motion_state":"static"}

  * doppler_hz: Doppler-line frequency as a MAGNITUDE (>= 0). The
    energy time series is real, so its spectrum is symmetric and the
    inbound/outbound sign is ambiguous at this stage -- it is resolved
    app-side against track geometry, and no direction is claimed here.
    WIRE-SCHEMA NOTE: passive_radar/wpp_idp.py emits the same kind with
    the same field names (radio/band/doppler_hz/strength/t/motion_state)
    -- the schema the app's WppIdpDoppler.tryParse decodes. The one
    deliberate difference is doppler_hz: magnitude here (>= 0, sign
    ambiguous from the real energy series), SIGNED there where the
    Tx-Rx baseline geometry is known (positive = inbound vs baseline).
    The app decoder accepts both.
  * strength: line peak-to-median in dB -- a disturbance strength,
    never an identity, never a position fix.
  * motion_state: this node's motion state ("static"/"moving"). The
    paper assumes a static receiver; node motion impresses its own slow
    modulation and masquerades as Doppler (open problem -- no solution
    claimed here). The app MUST NOT merge moving-node lines into track
    confidence; the state is carried so the merger can gate on it.

Output discipline: at most one event per energy window while a line
persists; silence otherwise. A wall-clock gap > GAP_RESET_S between
captures (e.g. sweep mode visiting the band every few seconds) resets
the accumulator -- the estimator is designed for --stare on the
illuminator band, where captures are back-to-back.

Honest-scope notes (do not quote beyond these):

  * Range is meters to tens of meters (the demonstrated geometry).
    This is a gap-filler inside the mesh's tripwire bubble, not a
    standoff sensor.
  * Baseline-crossing detector: sensitivity peaks when the threat
    crosses the Tx-Rx baseline. Threats outside the baseline fan are
    weakly covered or uncovered.
  * Static receiver only, until ego-motion compensation exists.
  * Needs an illuminator of opportunity in range; EM-quiet areas are
    poor terrain for this sensor.
  * Preamble-only costs ~7 dB by construction; preamble-only
    detections are inherently weaker -- the evidence text must say so.
  * Outputs are disturbances (Doppler lines + strengths), never
    identities -- and per Kozlov et al. 2026 (CONFIRMED, awareness
    only), micro-Doppler-as-identity is spoofable at PCB scale, so
    identity was never on the table regardless.
  * This module NEVER originates a track: wpp_idp_doppler events are
    detection corroboration merged upgrade-only, and never
    subtractive. Disagreement semantics live app-side.

How it plugs in: sdr_bridge.py feeds 2.4 GHz captures to
WppIdpEstimator.observe() (elrs_detect.py pattern: stateful detector
class, observe() returns UDP-ready event dicts). --wpp-waveform picks
the illuminator rule; --motion-state sets the carried node state;
--no-wpp-ids disables the module.
"""

import math

import numpy as np

E_RATE_HZ = 200.0        # energy samples per second (5 ms slots)
PREAMBLE_FRAC_OFDM = 0.2  # ofdm mode: use only the first 20% of each slot
# The preamble-only integration cost, stated not hidden:
# 10*log10(1/0.2) = 6.99 dB ~= the paper's CONFIRMED ~7 dB.
OFDM_PREAMBLE_ONLY_COST_DB = 10.0 * math.log10(1.0 / PREAMBLE_FRAC_OFDM)
WINDOW_SLOTS = 256       # slots per Doppler estimate (1.28 s at 200 Hz)
MAX_DOPPLER_HZ = 90.0    # line search ceiling (~5.6 m/s radial at 2.4 GHz)
SNR_GATE_DB = 12.0       # line peak-to-median gate
GAP_RESET_S = 2.0        # wall-clock gap that resets the accumulator


class WppIdpEstimator:
    """Bridge-side per-preamble energy estimator + Doppler-line emitter.

    Feed captures via observe(); collect wpp_idp_doppler events.
    """

    def __init__(self, e_rate_hz=E_RATE_HZ, preamble_frac=None,
                 window_slots=WINDOW_SLOTS, waveform="ofdm",
                 max_doppler_hz=MAX_DOPPLER_HZ, snr_gate_db=SNR_GATE_DB,
                 motion_state="static"):
        if waveform not in ("dsss", "ofdm"):
            raise ValueError(f"waveform must be 'dsss' or 'ofdm', "
                             f"got {waveform!r}")
        self.waveform = waveform
        if waveform == "dsss":
            # DSSS beacons: every packet fully usable.
            self.preamble_frac = 1.0
        else:
            pf = (PREAMBLE_FRAC_OFDM if preamble_frac is None
                  else float(preamble_frac))
            if not (0.0 < pf < 1.0):
                # The WAVEFORM RULE: ofdm mode with preamble_frac >= 1
                # would ingest data symbols -- structurally forbidden.
                raise ValueError(
                    "ofdm mode requires 0 < preamble_frac < 1 "
                    f"(got {pf}); data symbols must never be processed")
            self.preamble_frac = pf
        self.e_rate_hz = float(e_rate_hz)
        self.window_slots = int(window_slots)
        self.max_doppler_hz = float(max_doppler_hz)
        self.snr_gate_db = float(snr_gate_db)
        if motion_state not in ("static", "moving"):
            raise ValueError(f"motion_state must be 'static'/'moving', "
                             f"got {motion_state!r}")
        self.motion_state = motion_state
        self._st = {}  # radio -> per-stream accumulation state

    @staticmethod
    def _new_state(fs):
        return {"fs": fs, "spos": 0, "acc": 0.0, "cnt": 0,
                "E": [], "last_t": None}

    def observe(self, radio, band, center_mhz, t, x, fs_hz,
                motion_state=None):
        """Feed one capture; returns a list of UDP-ready event dicts.

        Samples are accumulated into fixed energy slots (sample-exact
        across captures); in ofdm mode only the preamble fraction of
        each slot is ever read. Each completed window of WINDOW_SLOTS
        slots yields at most one event.
        """
        x = np.asarray(x, dtype=np.complex64).ravel()
        if x.size == 0:
            return []
        fs = float(fs_hz)
        if not (math.isfinite(fs) and fs > 0):
            return []
        t = float(t)
        st = self._st.get(radio)
        if st is None or st["fs"] != fs:
            st = self._new_state(fs)
            self._st[radio] = st
        if st["last_t"] is not None and t - st["last_t"] > GAP_RESET_S:
            # Time base broke (sweep mode, paused capture, ...): the
            # energy series is no longer uniformly sampled, so restart
            # the window rather than FFT garbage.
            st.update(self._new_state(fs))
        st["last_t"] = t

        slot_len = max(1, int(round(fs / self.e_rate_hz)))
        pre_len = max(1, int(round(slot_len * self.preamble_frac)))
        events = []
        pos, n = 0, x.size
        while pos < n:
            in_slot = st["spos"]
            take = min(slot_len - in_slot, n - pos)
            # The WAVEFORM RULE, structurally: only samples [0, pre_len)
            # of each slot are ever read. In ofdm mode the data-symbol
            # portion [pre_len, slot_len) is discarded unread.
            lo = max(in_slot, 0)
            hi = min(in_slot + take, pre_len)
            if hi > lo:
                seg = x[pos + (lo - in_slot):pos + (hi - in_slot)]
                seg64 = seg.astype(np.complex128)
                st["acc"] += float(
                    np.sum(seg64.real ** 2 + seg64.imag ** 2))
                st["cnt"] += (hi - lo)
            st["spos"] = (in_slot + take) % slot_len
            pos += take
            if st["spos"] == 0:
                e = st["acc"] / st["cnt"] if st["cnt"] > 0 else 0.0
                st["E"].append(e)
                st["acc"], st["cnt"] = 0.0, 0
                if len(st["E"]) >= self.window_slots:
                    window = st["E"][:self.window_slots]
                    st["E"] = st["E"][self.window_slots:]
                    ev = self._detect(radio, band, center_mhz, t,
                                      window, motion_state)
                    if ev is not None:
                        events.append(ev)
        return events

    def _detect(self, radio, band, center_mhz, t, window, motion_state):
        # DC removal: strip the static direct-path pedestal (plus
        # stationary clutter) from the energy series.
        Ew = np.asarray(window, dtype=np.float64)
        if Ew.size < 8 or not np.all(np.isfinite(Ew)):
            return None
        r = Ew - Ew.mean()
        if float(np.max(np.abs(r))) == 0.0:
            return None
        # Doppler-line detector (bridge-side coarse version of the
        # paper's STFT -> CFAR chain).
        win = np.hanning(r.size).astype(np.float64)
        S = np.fft.rfft(r * win)
        P = np.abs(S).astype(np.float64) ** 2
        freqs = np.fft.rfftfreq(r.size, d=1.0 / self.e_rate_hz)
        bin_hz = self.e_rate_hz / r.size
        search = (freqs > 0.5 * bin_hz) & (freqs <= self.max_doppler_hz)
        sidx_all = np.flatnonzero(search)
        if sidx_all.size < 4:
            return None
        Ps = P[search]
        med = float(np.median(Ps)) + 1e-30
        if not math.isfinite(med) or med <= 0:
            return None
        ki = int(np.argmax(Ps))
        p_peak = float(Ps[ki])
        if p_peak <= 0.0:
            return None  # numerical dust only: silent
        snr = 10.0 * math.log10(p_peak / med)
        if snr < self.snr_gate_db:
            return None
        # Sub-bin line frequency via parabolic interpolation on log
        # power. Reported as a magnitude: the real-valued energy series
        # has a symmetric spectrum, so inbound/outbound sign is
        # ambiguous here (resolved app-side against track geometry).
        sidx = int(sidx_all[ki])
        if 0 < sidx < P.size - 1:
            y0 = math.log10(float(P[sidx - 1]) + 1e-30)
            y1 = math.log10(p_peak + 1e-30)
            y2 = math.log10(float(P[sidx + 1]) + 1e-30)
            den = y0 - 2.0 * y1 + y2
            off = 0.5 * (y0 - y2) / den if den < 0.0 else 0.0
            off = max(-0.5, min(0.5, off))
        else:
            off = 0.0
        doppler_hz = abs(float(freqs[sidx]) + off * bin_hz)
        return {"v": 1, "kind": "wpp_idp_doppler", "radio": radio,
                "band": band, "center_mhz": float(center_mhz),
                "doppler_hz": round(doppler_hz, 1),
                "strength": round(snr, 1), "t": float(t),
                "motion_state": (motion_state if motion_state in
                                 ("static", "moving") else
                                 self.motion_state)}
