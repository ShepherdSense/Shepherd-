#!/usr/bin/env python3
"""EXPERIMENTAL — LoRa preamble PMR monitor (RX only, defensive detection).

Watches a staring SDR capture for LoRa preambles on the Shepherd backhaul
channel (SF7 / 125 kHz) and reports the dechirp-domain peak-to-mean ratio
(PMR) of each preamble it finds. PMR is the training-light statistic from
Herrera-Loera et al., Sensors 2026, 26(19), 6123 ("Early-Warning Margins
for Preamble-Directed Jamming in LoRa"):

  * dechirp each preamble upchirp against an ideal reference,
  * DFT, dominant-bin magnitude / mean spectral magnitude,
  * averaged over the preamble's upchirps.

Why PMR matters: under a LoRa-like preamble jammer, the dechirped
spectrum gains extra energy outside the dominant bin, so the mean rises
and PMR FALLS. A low PMR on an otherwise present preamble is therefore
consistent with preamble interference — an early-warning signal that
fires before preamble symbol errors degrade the packet itself (the
paper's "early-warning margin" is a power-domain headroom in dB, NOT
elapsed warning time).

What this module is NOT, and what it never claims:
  * It is NOT a jamming verdict. A low PMR is consistent with preamble
    interference; it is not proof of jamming, and it never identifies
    a jammer. Fading, a weak link, or an overlapping legitimate
    transmission can also lower PMR.
  * It does NOT use the paper's simulation numbers as thresholds. The
    paper is simulation-only (SF7/125 kHz, single LoRa-like jammer at a
    fixed offset, reference-sync convention). Its floors are NOT
    thresholds here: without --pmr-threshold the monitor is REPORT-ONLY
    (it logs and emits PMR values and never alerts). Any threshold an
    operator sets must be re-derived from real hardware baselines.
  * It does NOT fuse PMR with any learned score. The paper shows
    max-rule fusion destroys PMR's advantage (the fused floor follows
    the heavier-tailed CAE score). PMR is a SEPARATE decision, always.
  * It does NOT cover the CAE / OC-SVM learned detectors from the paper.
    Those need a training pipeline and are a separate future candidate.
  * It does NOT transmit. There is no TX code path anywhere in this file
    or in the bridge. It only reads IQ the bridge already captured.

Live-data contract (this is a LIVE monitor, not a simulation):
  * Input is real IQ from the bridge's stare mode (or a recorded IQ
    file via the CLI below). The SX1276 gateway chip exposes no IQ, so
    this monitor CANNOT run on the gateway itself — it runs on the SDR
    bridge staring at the backhaul channel (default 915.0 MHz US915).
  * Preamble identification is structural: a run of >= MIN_UPCHIRPS
    consecutive upchirps with a consistent dechirped tone bin,
    followed by a downchirp (the SFD). A run of data chirps does not
    qualify (data symbols jump bins; the SFD check also fails).
  * Estimated sync, honestly: the paper used true sampling-time offset.
    This monitor searches 4 symbol phases per burst, so alignment is
    within 1/8 symbol of truth. Residual misalignment biases PMR low
    by a small, consistent amount — one more reason floors must be
    re-derived on hardware, never copied from the paper.
  * One reading per burst region (the longest run; ties broken by
    higher PMR). Dense packet bursts inside one region may
    under-report; that is a known limit, not a silent fix.
  * An adversary that preserves dechirp spectral concentration (e.g.
    a jammer crafted to look like a clean preamble) defeats PMR by
    construction. PMR covers the LoRa-like preamble-injection class
    only, not adaptive or protocol-aware variants.

How it plugs in: sdr_bridge.py feeds stare captures to PmrMonitor.
observe() and emits one UDP packet per preamble (kind "pmr",
"experimental": true). The Shepherd app parses those into an
EXPERIMENTAL monitor section (readings log + alert banner when a
threshold is set and crossed). PMR readings are ALERTS ONLY: they never
feed the tripwire, never fuse into tracks, never veto anything.

CPU: the burst gate skips quiet captures entirely. Inside a burst, the
phase search is a few hundred small FFTs per block — tens of
milliseconds on a modern laptop. Stare mode only, operator opt-in
(--pmr), so the cost is paid only when the operator wants it.

Run the recorded-IQ path:  python pmr_monitor.py iq.npy --fs 4000000
  (.npy of complex samples, or raw complex64 .bin with --fs.)
"""

import argparse
import json
import math
import sys

import numpy as np

from elrs_detect import lora_upchirp

# ------------------------------------------------------------------ config
# Shepherd backhaul PHY (gateway + node radio.begin: 125.0 kHz, SF7,
# sync 0x12, preambleLength register 8 -> 8 programmed upchirps + 2
# sync-word upchirps + 2.25 downchirps (SFD) on the air).
SF = 7
BW_HZ = 125_000.0
T_SYM_S = (2 ** SF) / BW_HZ  # 1.024 ms

# Structural chirp-find gate (dB). This is a DETECTION gate for finding
# preambles, NOT a jamming-alert threshold (those are operator-set and
# default to unset = report-only). Noise analysis: the gate is a
# MAGNITUDE ratio (10*log10), so a noise-only window exceeds 10 dB
# with probability ~10^-32 (Rayleigh magnitudes: a 10 dB magnitude
# ratio is a 100x power ratio; the ~0.6% figure would apply to a
# POWER ratio only and is wrong here). A run of >= MIN_UPCHIRPS
# consecutive passes plus bin consistency plus the SFD check makes
# a noise false preamble negligible. A genuine upchirp at decodable
# SNR clears it with margin (SF7 dechirp processing gain is ~21 dB).
DETECT_GATE_DB = 10.0
# Minimum upchirps for a run to count (nodes send 8 programmed + 2
# sync; 6 tolerates edge clipping). Runs longer than this are averaged
# in full and reported with their true length.
MIN_UPCHIRPS = 6
# Peak-bin consistency tolerance, in 128-point DFT bins (one bin =
# BW/128 = 977 Hz), FOR SYNC 0x12 ONLY (the deployed sync word): its
# sync chirps shift by <= 2 bins; data symbols typically jump
# further, which is what breaks payload runs. Another sync word
# shifts differently (0x34 shifts 3, 4) — PmrMonitor takes a
# sync_word parameter and derives the tolerance from its nibbles,
# so a non-0x12 deployment must pass its sync word instead of
# silently rejecting its preambles.
BIN_TOL_BINS = 2  # == max nibble of 0x12; kept as the documented default
# DFT length for the per-symbol PMR statistic: 2**SF = 128 bins, exactly
# the paper's demod-domain grid. This is deliberate, NOT an oversight:
# the statistic's sensitivity to a second tone scales as 1/n_bins, so a
# zero-padded 16k-bin FFT would make a LoRa-like jammer tone invisible
# in the mean. With 128 bins, PMR saturates at 10*log10(128) = 21.1 dB
# (the paper's "bounded PMR" remark) and a second equal tone costs
# ~3 dB. Price, documented honestly: scalloping. A tone between bins
# loses up to ~3.9 dB of peak, and because CFO is constant across a
# preamble, that loss is a CONSTANT bias per preamble, not noise. So
# PMR baselines must be derived PER LINK (per node-gateway pair), not
# as one global number.
N_BINS = 2 ** SF  # 128
# Burst gate: hop energy above (noise-floor estimate x this factor).
# The noise floor is min(20th-percentile hop energy x BURST_FACTOR,
# minimum NONZERO hop energy x 30). The min() matters: when a
# preamble fills most of the block, the median IS the signal and a
# median-based gate goes blind (found by probe: a 71%-signal block
# produced zero bursts under a median gate). TWO REGIMES — do not
# quote a single floor: (a) SPARSE blocks (signal < ~80% of hops):
# the 20th percentile is still noise, so the gate is ~noise x 6
# (~+7.6 dB); (b) DENSE blocks (signal > ~80% of hops): the 20th
# percentile IS signal, so the min() selects the minimum-hop term
# and the gate becomes ~noise x 30 (~+14.4 dB) — a preamble must
# clear the HIGHER floor to be seen at all. The minimum is over
# NONZERO hops: a single exactly-zero hop must not zero the gate
# (and silently skip the whole segment). A 100%-signal block yields
# no burst (accepted limit: a continuously hot channel has no quiet
# reference; the RSS-anomaly path covers that case). A false burst
# only costs CPU, never a false reading (readings still need the
# run + SFD checks).
BURST_FACTOR = 6.0
BURST_MIN_FACTOR = 30.0
# Burst-region expansion, in symbols, each side (covers edge chirps and
# the full 2.25-symbol SFD after the upchirp run).
REGION_PAD_SYMS = 3
# Buffer kept per observe() call, in seconds (bounds re-scan cost).
KEEP_S = 0.35
# Longest run the scanner will extend (a longer constant-bin train is
# not a Shepherd preamble; capping bounds the scan, it still gets an
# SFD check and, if confirmed, a reading with its true length).
MAX_RUN_WINDOWS = 24


def _db(x):
    x = float(x)
    if not math.isfinite(x):
        # Non-finite input (NaN/Inf IQ) can never pass the 10 dB
        # detect gate: floor it instead of propagating NaN.
        return -120.0
    return 10.0 * math.log10(max(x, 1e-12))


class PmrMonitor:
    """Stateful PMR monitor over a stream of IQ captures.

    fs_hz is passed per observe() call (backends differ: 4 MSPS
    Pluto/USRP/Soapy, 2.4 MSPS RTL-SDR). threshold_db=None means
    report-only: readings are emitted, alert is always False, margin
    is always None. threshold_db set means alert when pmr_db falls
    BELOW it (jamming lowers PMR); margin_db = pmr_db - threshold_db.
    sync_word (default 0x12, the deployed sync word) sets the
    peak-bin tolerance from its nibbles (0x12 -> 2 bins, 0x34 -> 4).
    """

    def __init__(self, threshold_db=None,
                 detect_gate_db=DETECT_GATE_DB,
                 min_upchirps=MIN_UPCHIRPS,
                 sync_word=0x12):
        self.threshold_db = threshold_db
        self.detect_gate_db = float(detect_gate_db)
        self.min_upchirps = int(min_upchirps)
        sw = int(sync_word)
        if not 0 <= sw <= 0xFF:
            raise ValueError(f"sync_word must be a byte, got {sync_word!r}")
        # Sync chirp shifts are the sync word's nibbles (0x12 -> 1, 2;
        # 0x34 -> 3, 4); the tolerance must cover the larger shift.
        self.bin_tol = max(sw >> 4, sw & 0xF)
        self._buf = np.zeros(0, dtype=np.complex64)
        self._base = 0  # absolute sample index of _buf[0]
        self._total = 0  # absolute sample index one past the last seen
        self._scanned_to = 0  # absolute index the scan frontier reached
        self._emitted = set()  # absolute preamble-start indices emitted

    # ------------------------------------------------------------ helpers
    def _symbol_pmr(self, win, ref_conj, ref_up):
        """PMR (dB) + peak bin of one symbol window, upchirp and
        downchirp variants. Returns (up_db, up_bin, down_db).

        Paper-faithful grid: dechirp at native rate, then gather
        N_BINS evenly spaced samples (one per LoRa symbol bin) and
        take a 128-point DFT. The dechirped signal is a tone, so
        gathering is exact for the tone component at any rate.
        """
        w = win - np.mean(win)  # kill LO leakage / DC offset
        stride = max(1, len(w) // N_BINS)
        idx = np.arange(N_BINS) * stride
        spec = np.fft.fft((w * ref_conj)[idx])
        mag = np.abs(spec)
        up_bin = int(np.argmax(mag))
        up_db = _db(float(mag[up_bin]) / float(np.mean(mag)))
        dspec = np.fft.fft((w * ref_up)[idx])
        dmag = np.abs(dspec)
        down_db = _db(float(np.max(dmag)) / float(np.mean(dmag)))
        return up_db, up_bin, down_db

    def _scan_region(self, region, fs_hz):
        """Find preamble candidates inside one burst region.

        region: (start, end) buffer-relative sample indices.
        Returns (readings, unresolved_start) where readings is a list
        of (abs_start, pmr_db, n_chirps, tone_off_hz) and
        unresolved_start is a buffer-relative index of a run that ends
        at the buffer end (needs more data), or None.
        """
        start, end = region
        sym_f = T_SYM_S * fs_hz  # samples per symbol (float)
        n_sym = max(8, int(round(sym_f)))
        # Reference chirps at this sample rate. The template length is
        # round(T*fs); windows use the same length, stepped by the
        # fractional symbol length (fractional cursor accumulation).
        up = lora_upchirp(SF, BW_HZ, fs_hz)
        if len(up) != n_sym:  # template rounds the same way; be safe
            n_sym = len(up)
        ref_conj = np.conj(up)
        bin_hz = BW_HZ / N_BINS  # 977 Hz symbol-bin spacing

        best = None  # (score_tuple, run) ; score = (len, mean_pmr_db)
        unresolved = None
        for phase in (0.0, 0.25, 0.5, 0.75):
            # Grid windows from region start + phase, stepping 1 symbol.
            pos = float(start) + phase * sym_f
            windows = []  # (start_idx, up_db, up_bin, down_db)
            while pos + n_sym <= end:
                s = int(round(pos))
                win = self._buf[s:s + n_sym]
                if len(win) < n_sym:
                    break
                up_db, up_bin, down_db = self._symbol_pmr(
                    win, ref_conj, up)
                windows.append((s, up_db, up_bin, down_db))
                pos += sym_f
            # Run detection over this phase's windows.
            i = 0
            while i < len(windows):
                s, up_db, up_bin, _ = windows[i]
                if up_db < self.detect_gate_db:
                    i += 1
                    continue
                run = [windows[i]]
                med_bin = up_bin
                j = i + 1
                while (j < len(windows)
                       and len(run) < MAX_RUN_WINDOWS):
                    ws, wdb, wbin, _ = windows[j]
                    if (wdb < self.detect_gate_db
                            or abs(wbin - med_bin) > self.bin_tol):
                        break
                    run.append(windows[j])
                    med_bin = int(np.median([r[2] for r in run]))
                    j += 1
                # SFD check: the window AFTER the run must look like a
                # downchirp. If the run ends at the last grid window
                # and the region reaches the buffer end, the SFD may
                # not have arrived yet: hold as unresolved.
                if j >= len(windows):
                    if end >= len(self._buf):
                        if unresolved is None:
                            unresolved = run[0][0]
                        i = j
                        continue
                    # Region ended before the buffer did: the next
                    # window exists past the region only if the region
                    # was not buffer-limited. Treat a missing next
                    # window here as a failed SFD (quiet follows).
                    i = j
                    continue
                next_down = windows[j][3]
                if next_down < self.detect_gate_db:
                    i = j  # not a preamble: SFD absent
                    continue
                if len(run) < self.min_upchirps:
                    i = j
                    continue
                pmr_lin = float(np.mean(
                    [10.0 ** (r[1] / 10.0) for r in run]))
                pmr_db = _db(pmr_lin)
                peak_bin = int(np.median([r[2] for r in run]))
                # Tone offset: mixes the true frequency offset (CFO +
                # channel error) with the winning phase's symbol-
                # alignment offset (up to +/-16 bins = +/-15.6 kHz;
                # a quarter-symbol grid error alone is 32 bins).
                # It is therefore a COARSE channel identifier only
                # (own channel vs a neighbour 100 kHz away), NEVER a
                # CFO measurement. Sub-phase refinement to tighten it
                # is documented future work in pmr_monitor_spec.md.
                tone_off = (peak_bin if peak_bin <= N_BINS // 2
                            else peak_bin - N_BINS) * bin_hz
                cand = ((len(run), pmr_db),
                        (self._base + run[0][0], pmr_db, len(run),
                         float(tone_off)))
                if best is None or cand[0] > best[0]:
                    best = cand
                i = j
        if best is None:
            return [], unresolved
        return [best[1]], unresolved

    # ------------------------------------------------------------ public
    def observe(self, x, fs_hz, t_end=None):
        """Feed one IQ block; returns a list of reading dicts.

        x: complex IQ samples. t_end: wall time (epoch seconds) of the
        END of this block, or None for file-relative time (seconds
        into the file). Readings carry t = estimated preamble-start
        time in the same frame.
        """
        x = np.asarray(x, dtype=np.complex64).ravel()
        if x.size == 0:
            return []
        self._buf = np.concatenate([self._buf, x])
        self._total += int(x.size)
        fs_hz = float(fs_hz)
        sym_f = T_SYM_S * fs_hz
        n_sym = max(8, int(round(sym_f)))
        if n_sym < N_BINS:
            # Below (complex) Nyquist for the 125 kHz channel the
            # 128-bin gather would index past the window (IndexError);
            # fail loudly instead of crashing mid-scan.
            raise ValueError(
                f"sample rate {fs_hz:g} Hz too low for 125 kHz LoRa: "
                f"need >= {BW_HZ:g} Hz (n_sym {n_sym} < {N_BINS} bins)")
        hop = max(1, int(round(sym_f / 4.0)))
        buf_len = len(self._buf)

        # Scan frontier: re-scan from one preamble back so preambles
        # straddling the previous frontier are caught exactly once
        # (dedupe by absolute start index).
        preamble_samps = int(round(12.25 * sym_f))
        scan_start_abs = max(self._base,
                             self._scanned_to - preamble_samps)
        scan_start = int(scan_start_abs - self._base)
        scan_end = buf_len

        readings = []
        unresolved_rel = None
        if scan_end - scan_start >= n_sym:
            seg = self._buf[scan_start:scan_end]
            # Hop energies (vectorized): trim to a hop multiple.
            nhops = len(seg) // hop
            if nhops >= 8:
                e = np.mean(np.abs(
                    seg[:nhops * hop].reshape(nhops, hop)) ** 2, axis=1)
                p20 = float(np.percentile(e, 20))
                nz = e[e > 0]
                emin = float(np.min(nz)) if nz.size else 0.0
                gate = min(p20 * BURST_FACTOR, emin * BURST_MIN_FACTOR)
                if gate > 0:
                    hot = e > gate
                    # Merge hot hops with gaps <= 2 symbols.
                    regions = []
                    k = 0
                    while k < nhops:
                        if not hot[k]:
                            k += 1
                            continue
                        a = k
                        a_end = k
                        gap = 0
                        k += 1
                        while k < nhops:
                            if hot[k]:
                                a_end = k
                                gap = 0
                            else:
                                gap += 1
                                if gap > 8:  # > 2 symbols of quiet
                                    break
                            k += 1
                        regions.append((a, a_end))
                    pad = REGION_PAD_SYMS * n_sym
                    for (a, b) in regions:
                        r0 = max(scan_start,
                                 scan_start + a * hop - pad)
                        r1 = min(scan_end,
                                 scan_start + (b + 1) * hop + pad)
                        if r1 - r0 < n_sym:
                            continue
                        found, unres = self._scan_region((r0, r1), fs_hz)
                        if unres is not None and unresolved_rel is None:
                            unresolved_rel = unres
                        for (abs_start, pmr_db, n_ch, tone_off) in found:
                            if not math.isfinite(pmr_db):
                                # NaN/Inf IQ must never emit a NaN reading.
                                continue
                            if abs_start in self._emitted:
                                continue
                            self._emitted.add(abs_start)
                            if t_end is None:
                                t = abs_start / fs_hz
                            else:
                                t = t_end - (self._total - abs_start) / fs_hz
                            thr = self.threshold_db
                            readings.append({
                                "pmr_db": round(float(pmr_db), 2),
                                "n_chirps": int(n_ch),
                                "tone_off_hz": round(float(tone_off), 1),
                                "threshold_db": (None if thr is None
                                                else float(thr)),
                                "margin_db": (None if thr is None else
                                              round(float(pmr_db - thr), 2)),
                                "alert": bool(thr is not None
                                              and pmr_db < thr),
                                "t": float(t),
                            })
        # Advance the frontier, but never past an unresolved run.
        new_frontier = self._total - preamble_samps
        if unresolved_rel is not None:
            unres_abs = self._base + unresolved_rel
            new_frontier = min(new_frontier, unres_abs)
        if new_frontier > self._scanned_to:
            self._scanned_to = new_frontier
        # Trim the buffer: keep 0.35 s plus whatever the frontier /
        # unresolved run still needs.
        keep_from_abs = self._total - int(round(KEEP_S * fs_hz))
        keep_from_abs = min(keep_from_abs,
                            self._scanned_to - preamble_samps)
        if unresolved_rel is not None:
            keep_from_abs = min(keep_from_abs,
                                self._base + unresolved_rel - n_sym)
        if keep_from_abs > self._base:
            drop = int(keep_from_abs - self._base)
            if 0 < drop < buf_len:
                self._buf = self._buf[drop:]
                self._base += drop
            elif drop >= buf_len:
                self._buf = np.zeros(0, dtype=np.complex64)
                self._base = self._total
        # Prune emitted starts older than the buffer (they can't recur).
        if self._emitted:
            self._emitted = {s for s in self._emitted if s >= self._base}
        return readings


def read_iq_file(path, fs_hz):
    """Read a recorded IQ file: .npy (complex array) or raw complex64
    .bin. Returns (samples, fs_hz). This path reads FILES ONLY — it
    never generates signals."""
    if path.endswith(".npy"):
        x = np.load(path)
        if not np.iscomplexobj(x):
            raise ValueError(f"{path}: .npy must hold complex samples")
        return np.asarray(x, dtype=np.complex64).ravel(), float(fs_hz)
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) % 8 != 0:
        raise ValueError(f"{path}: raw .bin length not a complex64 "
                         f"multiple ({len(raw)} bytes)")
    return np.frombuffer(raw, dtype=np.complex64).copy(), float(fs_hz)


def main(argv=None):
    """Recorded-IQ CLI: print PMR readings as JSON lines.

    Example: python pmr_monitor.py capture.npy --fs 4000000
    """
    ap = argparse.ArgumentParser(
        description="EXPERIMENTAL PMR monitor — recorded-IQ path. "
                    "Reads a real IQ capture file and prints one JSON "
                    "reading per LoRa preamble found. RX-only; reads "
                    "files, generates nothing.")
    ap.add_argument("file", help=".npy (complex) or raw complex64 .bin")
    ap.add_argument("--fs", type=float, default=4_000_000,
                    help="sample rate Hz (default 4000000)")
    ap.add_argument("--threshold", type=float, default=None,
                    help="optional alert threshold dB (PMR below it "
                         "alerts; unset = report-only, never alerts)")
    ap.add_argument("--sync-word", type=lambda s: int(s, 0), default=0x12,
                    help="LoRa sync word (default 0x12); sets the "
                         "peak-bin tolerance from its nibbles")
    ap.add_argument("--block", type=int, default=65536,
                    help="samples per observe() call (default 65536)")
    args = ap.parse_args(argv)
    try:
        x, fs_hz = read_iq_file(args.file, args.fs)
        mon = PmrMonitor(threshold_db=args.threshold,
                         sync_word=args.sync_word)
        for off in range(0, len(x), args.block):
            for r in mon.observe(x[off:off + args.block], fs_hz):
                print(json.dumps(r), flush=True)
    except (ValueError, OSError) as ex:
        print(f"pmr_monitor: error: {ex}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
