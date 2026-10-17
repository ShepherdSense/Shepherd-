#!/usr/bin/env python3
"""ELRS Gemini signature detection — RX-only DSP for the SDR bridge.

Detects LoRa chirp trains (ELRS's LoRa modes), tracks their FHSS hops,
and scores the Gemini dual-emission signature:

  * single-band Gemini: the SAME packet on TWO frequencies at once
    (~40 MHz apart @ 2.4 GHz, ~10 MHz apart @ 900 MHz)
  * GemX (xrossband): simultaneous 2.4 GHz + 900 MHz via dual LR1121s

(Verified against the official ExpressLRS docs; see
~/workspace/your_files/elrs_gemini_detection_brief.md.)

What this module is NOT:
  * It does not identify ELRS. Output language is "signature consistent
    with ELRS Gemini", never "confirmed ELRS". Any LoRa FHSS emitter in
    the detection grid can raise the score — the score is evidence, not
    identity. Tests enforce the wording.
  * It does not cover FLRC modes (ELRS 2.4 GHz 500/333 Hz packet rates
    use FLRC, not LoRa). FLRC is a documented gap (see MODES below).
  * It never transmits. There is no TX code path anywhere in this file
    or in the bridge.

How it plugs in: sdr_bridge.py feeds captures from the 2.4 GHz / 900 MHz
families to ElrsDetector.observe(). The detector emits two UDP event
kinds (via the bridge's emit()):
  * elrs_chirp: one throttled event per detected chirp train. The APP
    correlates these across radios for GemX (two bands need two
    receivers — no single SDR spans 2.4 GHz and 900 MHz).
  * elrs_signature: fired only when ONE capture contains time-correlated
    chirp trains on two frequencies ~40 MHz apart (single-band Gemini).
    This needs >= ~50 MHz instantaneous bandwidth (USRP X310 class);
    on narrower radios it simply never fires, and that is honest.

CPU: the dechirp scan is a few thousand tiny FFTs per capture (SF5/6
chirps are 32-64 symbols); measured in the low milliseconds on a
modern laptop. A narrowband-peak gate skips quiet captures entirely.
"""

import math
import time
from collections import deque

import numpy as np

# ---------------------------------------------------------------- LoRa modes
# ELRS 2.4 GHz packet rates 250/150/100/50 Hz use LoRa on the SX1280;
# 900 MHz ELRS uses LoRa on the SX127x. The 500/333 Hz 2.4 GHz rates use
# FLRC -- NOT covered (documented gap).
#
# The exact (SF, bandwidth) per packet-rate is UNVERIFIED against the
# ELRS source (it varies by rate and region). The detector therefore
# scans a candidate grid covering the plausible SX1280/SX127x space.
# Any LoRa chirp inside the grid is caught regardless of the exact
# ELRS mapping -- the grid is the honest contract, not a mode table.
ELRS_LORA_CANDIDATES = [
    (5, 406_250.0),
    (5, 812_500.0),
    (5, 1_625_000.0),
    (6, 406_250.0),
    (6, 812_500.0),
    (6, 203_125.0),   # sub-GHz SX127x narrow modes
    (7, 125_000.0),   # sub-GHz SX127x narrow modes
]

# Detection tuning. A chirp window "lights up" when its dechirped
# spectrum is CONCENTRATED: the top-3 FFT bins must hold at least half
# the window's energy. A true preamble dechirps to a pure tone
# (concentration ~0.9); a plain tone or FSK dechirped is still a sweep
# and spreads its energy (concentration ~0.04-0.08) -- even though its
# peak-to-median can look identical (~44 dB either way). Peak-to-median
# alone cannot tell them apart; concentration can. Measured: pure AWGN
# never approaches 0.5, and real chirp trains (even 5 dB above the
# noise floor) dechirp to 0.7+. A train needs MIN_TRAIN consecutive lit
# windows; ELRS preambles are 6+ back-to-back upchirps by construction.
CHIRP_MIN_CONCENTRATION = 0.5
CHIRP_PEAK_DB = 10.0  # coarse pre-filter only; concentration decides
MIN_TRAIN_WINDOWS = 6

# Gemini separation table (CONFIRMED from ExpressLRS docs). Applied
# band-aware by GeminiScorer._table_for: a pair is only tested against
# its own band's row.
GEMINI_SEPS_MHZ = {
    "gemini-2g4": (35.0, 45.0),   # ~40 MHz apart @ 2.4 GHz (CONFIRMED)
    "gemini-900m": (8.0, 12.0),   # ~10 MHz apart @ 900 MHz (CONFIRMED)
}
GEMINI_SCORE_STEP = 0.25   # per coincident observation
GEMINI_SCORE_TAU_S = 30.0  # score decays with this time constant
GEMINI_EMIT_THRESH = 0.30  # don't report whispers

# elrs_chirp throttle: at most one chirp event per band per this long.
# (At 1000 packets/s the raw detection rate would flood the UDP link.)
CHIRP_EMIT_MIN_GAP_S = 2.0

# Skip the dechirp scan unless the band already shows narrowband life:
# strongest peak this far above the noise floor. Saves the CPU on
# quiet sweeps; chirp trains at ELRS link budgets clear it easily.
CHIRP_CPU_GATE_DB = 8.0


def lora_upchirp(sf, bw_hz, fs_hz):
    """Ideal LoRa upchirp: frequency sweeps -bw/2 -> +bw/2 over
    T = 2**sf / bw seconds. Returns complex64, length round(T*fs)."""
    t_sym = (2 ** sf) / bw_hz
    n = max(8, int(round(t_sym * fs_hz)))
    t = np.arange(n) / fs_hz
    phase = 2.0 * math.pi * (-bw_hz / 2.0 * t
                             + (bw_hz ** 2) / (2.0 * 2 ** sf) * t ** 2)
    return np.exp(1j * phase).astype(np.complex64)


def _next_pow2(n):
    return 1 << max(1, (n - 1).bit_length())


def detect_chirp_trains(x, fs_hz, candidates=ELRS_LORA_CANDIDATES,
                        peak_db=CHIRP_PEAK_DB,
                        min_train=MIN_TRAIN_WINDOWS,
                        min_conc=CHIRP_MIN_CONCENTRATION):
    """Find LoRa preamble-like chirp trains in complex baseband `x`.

    For each (SF, BW) candidate: multiply each chirp-length window by the
    conjugate ideal upchirp (dechirp), FFT, and look for a strong peak.
    Consecutive lit windows group into trains. Returns a list of dicts:
    {t0_s, dur_s, freq_off_hz, sf, bw_hz, snr_db}. Empty list = none.
    Two window phases (0 and half-chirp offset) so a train straddling
    window boundaries is still caught.
    """
    x = np.asarray(x, dtype=np.complex64)
    # (t_w, bin_hz, snr) for every lit window, all candidates/phases.
    # One peak per window: the concentration gate already rejects
    # tones/FSK/noise, and a second peak here would mostly catch
    # sidelobes of the first. Two genuinely simultaneous trains (the
    # bridge-local Gemini case) are separated by splitting wide
    # captures into sub-bands first -- see ElrsDetector.observe().
    lits = []
    for sf, bw in candidates:
        n = int(round((2 ** sf) / bw * fs_hz))
        if n < 8 or n > len(x) // min_train:
            continue
        ref_conj = np.conj(lora_upchirp(sf, bw, fs_hz))
        fft_n = _next_pow2(n)
        bin_hz = fs_hz / fft_n
        for phase in (0, n // 2):
            w = phase
            wi = 0
            while w + n <= len(x):
                seg = x[w:w + n] * ref_conj
                spec = np.fft.fft(seg, n=fft_n)
                mag = np.abs(spec)
                med = float(np.median(mag)) + 1e-12
                pwr = mag * mag
                pwr_sum = float(pwr.sum()) + 1e-12
                # Concentration gate (see tuning comment): top-3 bins
                # must hold half the window's energy.
                if float(np.sort(pwr)[-3:].sum()) / pwr_sum < min_conc:
                    w += n
                    wi += 1
                    continue
                t_w = (phase + wi * n) / fs_hz
                b = int(np.argmax(mag))
                snr = 20.0 * math.log10(float(mag[b]) / med)
                if snr >= peak_db:
                    bhz = (b if b < fft_n // 2 else b - fft_n) * bin_hz
                    lits.append((t_w, bhz, snr, sf, bw, n))
                w += n
                wi += 1
    # Cluster lit windows by frequency (1 MHz): one cluster per train,
    # even when two trains run concurrently (the Gemini case).
    lits.sort(key=lambda e: e[1])
    clusters = []
    for e_ in lits:
        if clusters and abs(e_[1] - clusters[-1][0][1]) <= 1e6:
            clusters[-1].append(e_)
        else:
            clusters.append([e_])
    trains = []
    for cl in clusters:
        cl.sort(key=lambda e_: e_[0])
        # Longest run of windows close in time (allows the two
        # half-offset phases to interleave: step <= 1.5 chirps).
        best_run, run = [], []
        for e_ in cl:
            if run and e_[0] - run[-1][0] > 1.5 * run[-1][5] / fs_hz:
                if len(run) > len(best_run):
                    best_run = run
                run = []
            run.append(e_)
        if len(run) > len(best_run):
            best_run = run
        if len(best_run) >= min_train:
            t0 = best_run[0][0]
            dur = best_run[-1][0] - t0 + best_run[-1][5] / fs_hz
            off = float(np.median([e_[1] for e_ in best_run]))
            snr = float(np.median([e_[2] for e_ in best_run]))
            sf, bw = best_run[0][3], best_run[0][4]
            trains.append({"t0_s": t0, "dur_s": dur, "freq_off_hz": off,
                           "sf": sf, "bw_hz": bw, "snr_db": snr})
    # One train per time slot: the candidate grid catches the same
    # physical train on several (SF, BW) rows with slightly different
    # frequency estimates. Merge those (same time, <1 MHz apart),
    # keeping the strongest -- but never merge two genuinely separated
    # trains (the Gemini dual-frequency case is 40 MHz apart).
    trains.sort(key=lambda d: -d["snr_db"])
    kept = []
    for tr in trains:
        dupe = False
        for k in kept:
            if (abs(tr["t0_s"] - k["t0_s"]) < 0.5 * max(tr["dur_s"], k["dur_s"])
                    and abs(tr["freq_off_hz"] - k["freq_off_hz"]) < 1e6):
                dupe = True
                break
        if not dupe:
            kept.append(tr)
    return kept


class HopTracker:
    """Observed FHSS hop sequence: (t, freq_mhz) of chirp trains."""

    def __init__(self, maxlen=512):
        self._hops = deque(maxlen=maxlen)

    def note(self, t, freq_mhz):
        self._hops.append((float(t), float(freq_mhz)))

    def hop_count(self):
        return len(self._hops)

    def distinct_channels(self, eps_mhz=0.5, window_s=30.0, now=None):
        """Distinct channels hopped in the recent window."""
        now = time.time() if now is None else now
        freqs = [f for t, f in self._hops if now - t <= window_s]
        chans = []
        for f in freqs:
            if not any(abs(f - c) <= eps_mhz for c in chans):
                chans.append(f)
        return len(chans)


class GeminiScorer:
    """Bridge-local Gemini coincidence scorer.

    Scores the single-band Gemini signature: TIME-CORRELATED chirp
    trains on two frequencies with the documented Gemini separation, in
    ONE capture. Time correlation is load-bearing, not decorative:
    Gemini transmits the same packet on both chains simultaneously, so
    the two trains must overlap in time. A single FHSS emitter hopping
    sequentially across the pair's frequencies scores nothing, however
    close the frequencies (regression-tested). Score grows 0.25 per
    coincident observation (several coincidences to matter), decays with
    a 30 s time constant, caps at 1.0. A lone coincidence is weak
    evidence by construction.
    """

    def __init__(self):
        self.score = 0.0
        self.obs = 0
        self.mode = None
        self._last_t = None
        self._last_freqs = ()

    @property
    def last_freqs(self):
        """Frequencies (MHz) of the most recent coincidence, or ()."""
        return self._last_freqs

    @staticmethod
    def _table_for(fa_mhz, fb_mhz):
        """Separation table for the pair's band family, or None when the
        pair spans families (can't happen in one capture) or sits
        outside the ELRS bands. Band-aware: a sub-GHz pair is never
        labeled with the 2.4 GHz separation."""
        in_2g4 = lambda f: 2400.0 <= f < 2500.0
        in_900 = lambda f: 850.0 <= f < 960.0
        if in_2g4(fa_mhz) and in_2g4(fb_mhz):
            return {"gemini-2g4": GEMINI_SEPS_MHZ["gemini-2g4"]}
        if in_900(fa_mhz) and in_900(fb_mhz):
            return {"gemini-900m": GEMINI_SEPS_MHZ["gemini-900m"]}
        return None

    def observe(self, t, trains):
        """Feed (t0_abs_s, dur_s, freq_mhz) triples from one capture.
        Returns (mode, score) with mode None when no time-correlated
        coincidence was found."""
        if self._last_t is not None:
            if t <= self._last_t:
                # Stale or duplicate timestamp: never add score on it.
                return (self.mode
                        if self.score >= GEMINI_EMIT_THRESH else None,
                        self.score)
            self.score *= math.exp(-(t - self._last_t) / GEMINI_SCORE_TAU_S)
        self._last_t = t
        found = None
        for i in range(len(trains)):
            a0, ad, af = trains[i]
            for j in range(i + 1, len(trains)):
                b0, bd, bf = trains[j]
                # TIME CORRELATION: the trains must substantially
                # overlap in time (>= 50% of the shorter train).
                # Gemini transmits the same packet on both chains
                # simultaneously (~100% overlap). A single FHSS emitter
                # hopping sequentially across the pair's frequencies
                # never overlaps itself; window quantization can make
                # sequential trains *touch* at edges, but never reach
                # 50% overlap. This is what the headline claim rests on.
                ov = min(a0 + ad, b0 + bd) - max(a0, b0)
                if ov < 0.5 * min(ad, bd):
                    continue
                table = self._table_for(af, bf)
                if table is None:
                    continue
                sep = abs(bf - af)
                for mode, (lo, hi) in table.items():
                    if lo <= sep <= hi:
                        found = mode
                        break
                if found:
                    break
            if found:
                break
        if found:
            self.obs += 1
            self.mode = found
            self.score = min(1.0, self.score + GEMINI_SCORE_STEP)
            self._last_freqs = (trains[i][2], trains[j][2])
        return self.mode if found else None, self.score


def _split_halves(x):
    """Split a wide capture into lower/upper frequency halves (time
    domain, same center). Lets one detector pass find two simultaneous
    trains far apart -- the bridge-local Gemini case -- without the
    sidelobe phantoms a two-peak-per-window search produces."""
    X = np.fft.fftshift(np.fft.fft(np.asarray(x, dtype=np.complex64)))
    n = len(X)
    lo = np.fft.ifft(np.fft.ifftshift(
        X * (np.arange(n) < n // 2))).astype(np.complex64)
    hi = np.fft.ifft(np.fft.ifftshift(
        X * (np.arange(n) >= n // 2))).astype(np.complex64)
    return lo, hi


# Instantaneous bandwidth at/above which one capture can hold both
# Gemini frequencies (~40 MHz apart): split into halves first.
WIDEBAND_SPLIT_HZ = 45e6


class ElrsDetector:
    """Per-bridge ELRS chirp + Gemini-signature detector.

    Feed band captures via observe(); collect throttled elrs_chirp
    events (for app-level cross-radio correlation) and elrs_signature
    events (bridge-local dual-frequency coincidence).
    """

    def __init__(self, time_fn=time.time):
        self._time = time_fn
        self._trackers = {}    # band label -> HopTracker
        self._scorers = {}     # radio -> GeminiScorer
        self._last_chirp_emit = {}   # (radio, label) -> t
        self._last_sig_emit = {}     # radio -> t
        self._last_sig_score = {}    # radio -> last emitted score

    @staticmethod
    def _family(center_mhz):
        if 2400.0 <= center_mhz < 2500.0:
            return "2g4"
        if 850.0 <= center_mhz < 960.0:
            return "900m"
        return None

    def observe(self, radio, label, center_mhz, t, x, fs_hz, meas):
        """Process one band capture. Returns (chirp_events, sig_events):
        lists of dicts ready for the bridge's emit() (minus radio/t,
        which observe() fills in)."""
        chirps_out, sigs_out = [], []
        if self._family(center_mhz) is None:
            return chirps_out, sigs_out
        # CPU gate: no narrowband life, no dechirp scan.
        if meas.get("peak_dbfs", -200) - meas.get("noise", 0) < CHIRP_CPU_GATE_DB:
            return chirps_out, sigs_out
        trains = detect_chirp_trains(np.asarray(x, dtype=np.complex64),
                                     float(fs_hz))
        if float(fs_hz) >= WIDEBAND_SPLIT_HZ:
            # One capture can hold both Gemini frequencies: search each
            # half separately so the stronger chain can't mask the
            # weaker one (single-peak-per-window only sees the max).
            lo, hi = _split_halves(x)
            trains = trains + detect_chirp_trains(
                lo, float(fs_hz)) + detect_chirp_trains(hi, float(fs_hz))
            # The full-span pass and the half passes overlap: merge
            # duplicates (same time, <1 MHz apart), keep strongest.
            trains.sort(key=lambda d: -d["snr_db"])
            merged = []
            for tr in trains:
                if not any(abs(tr["t0_s"] - k["t0_s"])
                           < 0.5 * max(tr["dur_s"], k["dur_s"])
                           and abs(tr["freq_off_hz"] - k["freq_off_hz"]) < 1e6
                           for k in merged):
                    merged.append(tr)
            trains = merged
        if not trains:
            # No trains: still decay the scorer so stale scores die.
            sc = self._scorers.get(radio)
            if sc is not None:
                sc.observe(t, [])
            return chirps_out, sigs_out
        tr = self._trackers.setdefault(label, HopTracker())
        for trn in trains:
            tr.note(t + trn["t0_s"], center_mhz + trn["freq_off_hz"] / 1e6)
        # Throttled chirp event: report the strongest train.
        key = (radio, label)
        if t - self._last_chirp_emit.get(key, 0.0) >= CHIRP_EMIT_MIN_GAP_S:
            self._last_chirp_emit[key] = t
            best = max(trains, key=lambda d: d["snr_db"])
            chirps_out.append({
                "v": 1, "kind": "elrs_chirp", "radio": radio,
                "band": label, "center_mhz": center_mhz,
                "freq_mhz": round(center_mhz + best["freq_off_hz"] / 1e6, 3),
                "sf": best["sf"], "bw_khz": round(best["bw_hz"] / 1e3, 1),
                "snr_db": round(best["snr_db"], 1), "t": t,
            })
        # Bridge-local Gemini coincidence scoring. FHSS gate: the hop
        # tracker must show real hopping (>= 3 distinct channels in
        # 30 s) before a dual-tone coincidence counts -- two fixed
        # tones 40 MHz apart are not Gemini, and the gate is what
        # tells them apart. A genuine ELRS link hops hundreds of
        # times per second, so the gate opens within a few captures.
        sc = self._scorers.setdefault(radio, GeminiScorer())
        triples = [(t + trn["t0_s"], trn["dur_s"],
                    center_mhz + trn["freq_off_hz"] / 1e6)
                   for trn in trains]
        if tr.distinct_channels(window_s=30.0, now=t) >= 3:
            mode, score = sc.observe(t, triples)
        else:
            mode, score = sc.observe(t, [])
        last_emit = self._last_sig_emit.get(radio, 0.0)
        if (score >= GEMINI_EMIT_THRESH
                and (mode is not None or t - last_emit >= 15.0)
                and (t - last_emit >= 15.0
                     or abs(score - self._last_sig_score.get(radio, 0.0)) >= 0.2)):
            self._last_sig_emit[radio] = t
            self._last_sig_score[radio] = score
            sigs_out.append({
                "v": 1, "kind": "elrs_signature", "radio": radio,
                "mode": sc.mode or "gemini-2g4",
                "score": round(score, 2), "obs": sc.obs,
                "bands": [label],
                "freqs_mhz": [round(f, 3) for f in sc.last_freqs],
                "t": t,
            })
        return chirps_out, sigs_out
