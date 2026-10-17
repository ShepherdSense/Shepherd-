#!/usr/bin/env python3
"""
Shepherd SDR bridge — use YOUR radio as a Shepherd sensor.

Supported SDRs (RX only -- this script never transmits; there is no TX
code path anywhere in it):

  ADALM-Pluto ......... backend=pluto  (pyadi-iio, AD9363, 70 MHz-3.8 GHz)
  Ettus USRP B200/B210 . backend=uhd    (UHD, AD9364/AD9361, 70 MHz-6 GHz)
  RTL-SDR ............. backend=rtlsdr (pyrtlsdr, ~24 MHz-1.75 GHz)
  HackRF / Airspy /      backend=soapy  (SoapySDR; --soapy-driver picks the
  LimeSDR / SDRplay /     hardware: hackrf, airspy, lime, sdrplay, bladerf)
  bladeRF .............
  (no hardware) ....... backend=simulate (scripted synthetic spectrum)

The bridge sweeps (or stares at) the drone-relevant bands, measures
per-band RF energy, and ships the readings over UDP to Shepherd, which
treats each watched band as a virtual tripwire link.

Polarity convention (shared with Shepherd's SdrDriver): the bridge
reports energy in dBFS (negative numbers, e.g. -80 for a quiet band). The
Dart driver negates it into LinkSample.snr, so an emitter APPEARING in a
band looks exactly like a link DIP to Shepherd's tripwire: baseline - snr
becomes (energy_now - energy_baseline) in dB. Absolute dBFS values are
meaningless across gain settings; only deltas matter -- keep the gain
FIXED (manual) while sensing.

Protocol (UDP JSON datagrams to the Shepherd host, default 127.0.0.1:49161):

  band packet:
    {"v":1,"kind":"band","radio":"rtlsdr0","band":"433",
     "center_mhz":433.92,"bw_mhz":1.0,
     "energy_dbfs":-52.3,"noise_dbfs":-81.2,
     "bins_dbfs":[-53.1,... 8 values ...],
     "peak_mhz":433.97,"peak_dbfs":-48.2,"span_mhz":1.0,
     "sig_hint":"fhss-2g4",
     "t":1729123456.789}

  (peak_mhz is the absolute frequency of the strongest non-DC bin in the
  measured span, peak_dbfs its level, span_mhz the width actually
  measured -- see "Band width" below. All three are optional extras;
  older Shepherd builds ignore them.)

  (sig_hint is an emitter *signature* hint: "fhss-2g4", "fhss-900m",
  "ofdm-5g", "tone-5g8", or null. It describes a PATTERN of energy over
  frequency and time -- e.g. frequency-hopping the way ELRS-style
  control links hop -- never an identification, and never a drone
  claim. It needs several observations of the band (a few seconds at
  least); null means "nothing signature-like seen". Additive: older
  Shepherd builds ignore the field.)

  beacon packet (every 3 s, lets Shepherd show bridge status):
    {"v":1,"kind":"beacon","radio":"rtlsdr0","backend":"rtlsdr",
     "bands":["433","915"],"dropped":0,"t":1729123456.789}

Band width: the measurement is limited to the central 80% of the radio's
sample rate (the edges are filter roll-off). A band wider than that is
measured over its usable centre only and span_mhz says so honestly.

Examples:
  python sdr_bridge.py --simulate
  python sdr_bridge.py --simulate --plan fpv
  python sdr_bridge.py --backend rtlsdr --plan lora
  python sdr_bridge.py --backend rtlsdr
  python sdr_bridge.py --backend soapy --soapy-driver hackrf
  python sdr_bridge.py --backend pluto --pluto-uri ip:192.168.2.1
  python sdr_bridge.py --backend uhd --uhd-args "type=b200" --stare 2437
"""

import argparse
import json
import math
import socket
import sys
import time
from collections import deque

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: pip install -r requirements.txt")

UDP_PORT_DEFAULT = 49161
SAMPLE_RATE = 4_000_000      # Pluto/USRP/Soapy-practical; RTL-SDR uses 2.4e6
CAPTURE_N = 16384
MIN_CAPTURE_N = 4096         # shorter captures are treated as a failed read
SEG_N = 2048                 # Welch segment length (averaging lowers variance)
USABLE_FRAC = 0.8            # central fraction of the sample rate we trust
BEACON_S = 3.0
TUNE_SETTLE_S = 0.15

# Drone-relevant bands: (label, center MHz, bandwidth MHz).
# The bridge skips any band above the radio's max frequency.
DEFAULT_BANDS = [
    ("433", 433.92, 1.0),    # LoRa / RC control
    ("915", 915.0, 2.0),     # LoRa / telemetry (US region; use 868 for EU)
    ("1290", 1290.0, 8.0),   # FPV video
    ("2437", 2437.0, 20.0),  # 2.4 GHz ISM center
    ("5780", 5780.0, 20.0),  # 5.8 GHz FPV video
]

# Named band plans: (label, center MHz, bandwidth MHz).
# WHY each plan watches what it watches:
#   fpv ....... the full FPV-drone RF footprint: 1.3 GHz video,
#               2.4 GHz ELRS control link, 5.8 GHz video downlink
#   dji ....... DJI OcuSync/O4: control link (2.4 GHz ISM) + video
#               downlink (5 GHz ISM)
#   longrange . sub-GHz long-range control: 433 LoRa, 868 (EU SRD),
#               915 (US ISM) -- Crossfire / ELRS-900 country
#   lora ...... pure sub-GHz LoRa/Meshtastic watch (same bands as
#               longrange; the name says what you're looking for)
PLANS = {
    "fpv": [
        ("1290", 1290.0, 8.0),
        ("2437", 2437.0, 20.0),
        ("5780", 5780.0, 20.0),
    ],
    "dji": [
        ("2437", 2437.0, 20.0),
        ("5780", 5780.0, 20.0),
    ],
    "longrange": [
        ("433", 433.92, 1.0),
        ("868", 868.0, 1.0),
        ("915", 915.0, 2.0),
    ],
    "lora": [
        ("433", 433.92, 1.0),
        ("868", 868.0, 1.0),
        ("915", 915.0, 2.0),
    ],
}

PLUTO_MAX_MHZ = 3800.0   # AD9363 official ceiling (the 6 GHz hack is unreliable)
USRP_MAX_MHZ = 6000.0
RTLSDR_MAX_MHZ = 1766.0  # R820T2 tuner ceiling

# SoapySDR driver name -> usable ceiling, MHz. Unknown drivers get 6000
# and a printed note; the user can override with --max-mhz.
SOAPY_CAPS = {
    "rtlsdr": 1766.0,
    "hackrf": 6000.0,
    "airspy": 1800.0,
    "airspyhf": 660.0,
    "lime": 3800.0,
    "sdrplay": 2000.0,
    "bladerf": 6000.0,
    "uhd": 6000.0,
    "plutosdr": 3800.0,
}


# ---------------------------------------------------------------- backends

class RadioBackend:
    """Minimal RX surface every backend implements."""

    name = "base"
    max_mhz = 6000.0
    sample_rate = SAMPLE_RATE

    def tune(self, center_mhz, bw_mhz, gain_db):
        raise NotImplementedError

    def capture(self, n):
        """Return n complex64 samples normalized to roughly [-1, 1]."""
        raise NotImplementedError

    def close(self):
        pass


class PlutoBackend(RadioBackend):
    """ADALM-Pluto (AD9363) via pyadi-iio. RX path only."""

    name = "pluto"
    max_mhz = PLUTO_MAX_MHZ

    def __init__(self, uri, gain_db):
        try:
            import adi
        except ImportError:
            sys.exit("pyadi-iio is required for --backend pluto: "
                     "pip install pyadi-iio")
        # NOTE: only rx_* attributes are ever touched. No TX anywhere.
        self.sdr = adi.Pluto(uri=uri)
        self.sdr.rx_buffer_size = CAPTURE_N
        self.sdr.gain_control_mode_chan0 = "manual"
        try:
            self.sdr.rx_output_type = "raw"   # ADC counts, fixed scale
        except Exception:
            pass
        self.gain_db = gain_db

    def tune(self, center_mhz, bw_mhz, gain_db):
        s = self.sdr
        s.rx_lo = int(center_mhz * 1e6)
        s.rx_rf_bandwidth = int(min(bw_mhz, 20.0) * 1e6)
        s.sample_rate = self.sample_rate
        s.rx_hardwaregain_chan0 = float(gain_db)
        time.sleep(TUNE_SETTLE_S)
        s.rx()  # discard: flush stale samples after retune

    def capture(self, n):
        x = self.sdr.rx()
        x = np.asarray(x, dtype=np.complex64)
        if x.size == 0:
            return x  # USB hiccup: let the DSP clamp handle it
        # AD936x ADC is 12-bit: raw counts span +/-2048. ALWAYS apply the
        # same fixed scale. (A data-dependent "looks like counts" test
        # flips scale between quiet and loud captures -- a ~55 dB jump
        # that reads as a phantom emitter.)
        x = x / 2048.0
        if len(x) > n:
            x = x[:n]
        return x


class UsrpBackend(RadioBackend):
    """Ettus USRP B200/B210 (AD9364/AD9361) via UHD. RX streamer only."""

    name = "uhd"
    max_mhz = USRP_MAX_MHZ

    def __init__(self, args, gain_db):
        try:
            import uhd
        except ImportError:
            sys.exit("uhd is required for --backend uhd: pip install uhd")
        self.uhd = uhd
        # NOTE: RX streamer only. get_tx_stream is never called.
        self.usrp = uhd.usrp.MultiUSRP(args or "")
        self.usrp.set_rx_rate(self.sample_rate, 0)
        self.gain_db = gain_db
        st_args = uhd.usrp.StreamArgs("fc32", "sc16")
        st_args.channels = [0]
        self.streamer = self.usrp.get_rx_stream(st_args)
        self._streaming = False

    def tune(self, center_mhz, bw_mhz, gain_db):
        u = self.usrp
        u.set_rx_freq(self.uhd.types.TuneRequest(center_mhz * 1e6), 0)
        u.set_rx_bandwidth(min(bw_mhz, 56.0) * 1e6, 0)
        u.set_rx_gain(float(gain_db), 0)
        time.sleep(TUNE_SETTLE_S)
        if not self._streaming:
            self.streamer.issue_stream_cmd(
                self.uhd.types.StreamCMD(self.uhd.types.StreamMode.start_cont))
            self._streaming = True
        # discard one buffer after retune
        buf = np.empty((1, CAPTURE_N), dtype=np.complex64)
        md = self.uhd.types.RXMetadata()
        self.streamer.recv(buf, md, 1.0)

    def capture(self, n):
        buf = np.empty((1, n), dtype=np.complex64)
        md = self.uhd.types.RXMetadata()
        got = self.streamer.recv(buf, md, 2.0)
        if got < n:
            buf = buf[:, :got]
        return buf[0].astype(np.complex64)

    def close(self):
        if self._streaming:
            self.streamer.issue_stream_cmd(
                self.uhd.types.StreamCMD(self.uhd.types.StreamMode.stop_cont))
            self._streaming = False


class RtlSdrBackend(RadioBackend):
    """RTL-SDR (RTL2832U) via pyrtlsdr. RX-only hardware by design --
    the dongle has no transmitter at all."""

    name = "rtlsdr"
    max_mhz = RTLSDR_MAX_MHZ
    sample_rate = 2_400_000  # stable ceiling for most dongles

    def __init__(self, index, gain_db):
        try:
            from rtlsdr import RtlSdr
        except ImportError:
            sys.exit("pyrtlsdr is required for --backend rtlsdr: "
                     "pip install pyrtlsdr  (needs the RTL-SDR driver:\n"
                     "  Windows: zadig installs WinUSB for the dongle)")
        self.sdr = RtlSdr(index)
        self.sdr.sample_rate = self.sample_rate
        self.sdr.gain = self._nearest_gain(gain_db)

    @staticmethod
    def _nearest_gain(want):
        # R820T2 valid tuner gains, dB. pyrtlsdr raises on anything else.
        valid = [0.0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6,
                 19.7, 20.7, 22.9, 25.4, 28.0, 29.7, 32.8, 33.8, 36.4, 37.2,
                 38.6, 40.2, 42.1, 43.4, 43.9, 44.5, 48.0, 49.6]
        best = min(valid, key=lambda g: abs(g - want))
        if best != want:
            print(f"[rtlsdr] gain {want} dB not a tuner step; using {best} dB")
        return best

    def tune(self, center_mhz, bw_mhz, gain_db):
        self.sdr.center_freq = center_mhz * 1e6
        time.sleep(0.05)
        self.sdr.read_samples(2048)  # flush after retune

    def capture(self, n):
        # pyrtlsdr returns complex64 in roughly [-1, 1].
        return np.asarray(self.sdr.read_samples(n), dtype=np.complex64)

    def close(self):
        self.sdr.close()


class SoapyBackend(RadioBackend):
    """HackRF / Airspy / LimeSDR / SDRplay / bladeRF via SoapySDR.

    One uniform API for everything PothosSDR (Windows) or SoapySDR
    modules (Linux) expose. Manual gain mode, RX stream only.
    """

    def __init__(self, driver, extra_args, gain_db, sample_rate):
        try:
            import SoapySDR
            from SoapySDR import SOAPY_SDR_RX
        except ImportError:
            sys.exit("SoapySDR python bindings required for --backend soapy.\n"
                     "  Windows: install PothosSDR (includes bindings + "
                     "hardware modules).\n"
                     "  Linux:   apt install python3-soapysdr soapysdr-module-all")
        self.SoapySDR = SoapySDR
        self.RX = SOAPY_SDR_RX
        self.driver = driver
        self.sample_rate = sample_rate
        dev_args = dict(driver=driver)
        dev_args.update(extra_args)
        # NOTE: RX stream only. No TX stream is ever set up.
        self.dev = SoapySDR.Device(dev_args)
        self.dev.setSampleRate(SOAPY_SDR_RX, 0, float(sample_rate))
        if self.dev.hasGainMode(SOAPY_SDR_RX, 0):
            self.dev.setGainMode(SOAPY_SDR_RX, 0, False)  # manual, fixed
        self.dev.setGain(SOAPY_SDR_RX, 0, float(gain_db))
        self.stream = self.dev.setupStream(SOAPY_SDR_RX,
                                           SoapySDR.SOAPY_SDR_CF32, [0])
        self.dev.activateStream(self.stream)
        self.max_mhz = SOAPY_CAPS.get(driver, 6000.0)
        if driver not in SOAPY_CAPS:
            print(f"[soapy] unknown driver '{driver}'; assuming 6000 MHz "
                  f"ceiling (override with --max-mhz)")

    @property
    def name(self):
        return f"soapy-{self.driver}"

    def tune(self, center_mhz, bw_mhz, gain_db):
        self.dev.setFrequency(self.RX, 0, center_mhz * 1e6)
        if self.dev.hasBandwidth(self.RX, 0):
            try:
                self.dev.setBandwidth(self.RX, 0, min(bw_mhz, 28.0) * 1e6)
            except Exception:
                pass  # some modules reject manual bandwidth; ignore
        time.sleep(TUNE_SETTLE_S)
        # flush after retune
        self.capture(1024)

    def capture(self, n):
        out = np.empty(n, dtype=np.complex64)
        got = 0
        while got < n:
            buff = np.empty(n - got, dtype=np.complex64)
            sr = self.dev.readStream(self.stream, [buff], n - got,
                                     timeoutUs=3_000_000)
            if sr.ret <= 0:
                break
            out[got:got + sr.ret] = buff[:sr.ret]
            got += sr.ret
        return out[:got]

    def close(self):
        try:
            self.dev.deactivateStream(self.stream)
            self.dev.closeStream(self.stream)
        except Exception:
            pass


class SimBackend(RadioBackend):
    """Synthetic spectrum: scripted emitters over a drifting noise floor.

    Lets the full pipeline be verified with no hardware:
      2437 MHz: ELRS-like FHSS hopper (first 20 s of each 2 min;
                new sub-band every capture), then a wideband FPV/Wi-Fi-like
                burst 20-40 s of each 90 s
      915 MHz:  LoRa-like narrowband burst 5-9 s of each 47 s
      5780 MHz: DJI O4-like wideband OFDM burst (first 20 s of each
                150 s, after one quiet capture so the detector learns
                a baseline), then an analog-FPV-like static carrier
                60-80 s
      433 MHz:  weak always-on LoRa-like carrier
    """

    name = "simulate"
    max_mhz = 6000.0

    def __init__(self):
        self.t0 = time.time()
        self.center = 2437.0
        self.rng = np.random.default_rng(7)
        self._cap_n = 0            # total captures (drives the hop slot)
        self._band_caps = {}       # center MHz -> completed captures

    def tune(self, center_mhz, bw_mhz, gain_db):
        self.center = center_mhz
        self.bw = bw_mhz

    def _emitter(self, now):
        """(level dB above floor, kind) for the tuned band right now.

        kind: "wide" (wideband burst), "tone" (static narrowband),
              "hop" (frequency-hopping narrowband), or None.
        """
        el = now - self.t0
        if abs(self.center - 2437.0) < 1.0:
            if (el % 120.0) < 20.0:
                return 25.0, "hop"    # ELRS-like FHSS hopper
            if 20.0 <= (el % 90.0) < 40.0:
                # FPV/Wi-Fi-like wideband burst: raises the band MEDIAN.
                return 28.0, "wide"
            return 0.0, None
        if abs(self.center - 915.0) < 1.0:
            if 5.0 <= (el % 47.0) < 9.0:
                # LoRa-like narrowband burst: visible in sub-band peaks
                # and peak_mhz, deliberately NOT in the median.
                return 18.0, "tone"
            return 0.0, None
        if abs(self.center - 5780.0) < 1.0:
            # DJI O4-like wideband OFDM burst. Gated on one prior quiet
            # capture of this band: the OFDM detector needs a calm
            # reference to recognize the lift, and this makes the
            # demo deterministic on any machine speed.
            if (self._band_caps.get(5780.0, 0) >= 1
                    and (el % 150.0) < 20.0):
                return 22.0, "wide"
            if 60.0 <= (el % 150.0) < 80.0:
                return 20.0, "tone"   # analog-FPV-like static carrier
            return 0.0, None
        if abs(self.center - 433.92) < 1.0:
            return 12.0, "tone"       # always-on weak narrowband carrier
        return 0.0, None

    def capture(self, n):
        now = time.time()
        # Noise floor drifts slowly, like a real front end warming up.
        floor_db = -85.0 + 1.5 * math.sin((now - self.t0) / 120.0)
        floor_lin = 10 ** (floor_db / 20.0)
        x = (self.rng.standard_normal(n) + 1j * self.rng.standard_normal(n))
        x = (x / np.sqrt(2.0)).astype(np.complex64) * floor_lin
        lvl_db, kind = self._emitter(now)
        if lvl_db > 0:
            amp = floor_lin * (10 ** (lvl_db / 20.0))
            t = np.arange(n) / self.sample_rate
            if kind == "wide":
                # Wideband: extra noise-like power across the whole span.
                w = (self.rng.standard_normal(n)
                     + 1j * self.rng.standard_normal(n)) / np.sqrt(2.0)
                x = x + (w * amp).astype(np.complex64)
            elif kind == "hop":
                # FHSS: narrow tone, new sub-band every capture (hop slot
                # advances per capture, so the hop pattern is
                # deterministic whatever the sweep rate).
                hop = (self._cap_n * 5 + 1) % 8
                off_hz = (hop - 3.5) * 350e3
                ph = 2 * np.pi * off_hz * t
                x = x + (np.exp(1j * ph) * amp).astype(np.complex64)
            else:
                # Narrowband: tone 150 kHz off centre with FM wobble.
                ph = (2 * np.pi * 150e3 * t
                      + 2.0 * np.sin(2 * np.pi * 37.0 * t))
                x = x + (np.exp(1j * ph) * amp).astype(np.complex64)
        self._cap_n += 1
        self._band_caps[self.center] = self._band_caps.get(self.center, 0) + 1
        return x


# ---------------------------------------------------------------- DSP

def psd_dbfs(x, seg=SEG_N):
    """Welch-averaged, FFT-shifted power spectral density in dBFS.

    Returns (freqs, p): freqs in cycles/sample (-0.5..0.5), p in dBFS
    (full-scale sine == 0 dBFS per bin). Averaging SEG_N-point segments
    in the power domain cuts the variance of the band metrics so the
    tripwire sees fewer phantom wobbles. Only deltas matter downstream.
    """
    n = len(x)
    if n < 256:
        return np.array([]), np.array([], dtype=np.float32)
    seg = min(seg, 1 << (n.bit_length() - 1))  # largest power of two <= n
    nseg = n // seg
    w = np.hanning(seg).astype(np.float32)
    xs = np.asarray(x[:nseg * seg], dtype=np.complex64).reshape(nseg, seg) * w
    # Complex input -> full FFT (rfft would discard the imaginary part).
    spec = np.fft.fftshift(np.fft.fft(xs, axis=1), axes=1)
    mag = np.abs(spec) * 2.0 / (seg * np.mean(w))
    p = np.mean(mag.astype(np.float64) ** 2, axis=0)
    freqs = np.fft.fftshift(np.fft.fftfreq(seg))
    return freqs, (10.0 * np.log10(p + 1e-24)).astype(np.float32)


def band_measurement(x, sample_rate=SAMPLE_RATE, bw_mhz=None):
    """Per-band energy metrics from one capture, or None if unusable.

    Only the part of the spectrum inside the requested band (clipped to
    the central USABLE_FRAC of the sample rate) is measured:

    energy: median PSD across the band -- the stable wideband metric and
        the primary tripwire input (robust to spurs and narrow tones).
    noise: 10th-percentile PSD -- the band's noise floor estimate.
    bins: 8 contiguous sub-bands, LOW to HIGH frequency, PEAK PSD each --
        catches narrowband emitters (LoRa/RC tones) that the median
        deliberately ignores. Peak-based, so spur-sensitive: treat as an
        investigation aid, and rely on the tripwire's confirm-polls +
        adaptive threshold before alarming.
    peak: frequency offset (MHz from centre) and level of the strongest
        bin, ignoring the DC-spike region.
    span_mhz: the width actually measured (<= requested bw).
    """
    freqs, p = psd_dbfs(x)
    if p.size == 0 or not np.all(np.isfinite(p)):
        return None
    f_hz = freqs * float(sample_rate)
    half = USABLE_FRAC * sample_rate / 2.0
    if bw_mhz:
        half = min(half, bw_mhz * 1e6 / 2.0)
    sel = np.abs(f_hz) <= half
    if int(sel.sum()) < 16:
        return None
    ps = p[sel].copy()
    fs = f_hz[sel]
    # Mask the DC spike (LO leakage / DC offset) so it can't pose as an
    # emitter in the peaks. The median/percentile barely notice it.
    dc = np.abs(fs) <= 3.0 * float(sample_rate) / SEG_N
    if dc.any() and (~dc).any():
        ps[dc] = np.median(ps[~dc])
    energy = float(np.median(ps))
    noise = float(np.percentile(ps, 10))
    bins = [float(np.max(e)) for e in np.array_split(ps, 8) if e.size]
    while len(bins) < 8:
        bins.append(noise)
    k = int(np.argmax(ps))
    return {
        "energy": energy, "noise": noise, "bins": bins,
        "peak_off_mhz": float(fs[k]) / 1e6, "peak_dbfs": float(ps[k]),
        "span_mhz": 2.0 * half / 1e6,
    }


# ---------------------------------------------------------------- signature hints

# Emitter-signature detection tuning. A "hot" sub-band is this far above
# the band's own noise floor (10th percentile -- self-calibrating per
# band, so it survives gain differences).
SIG_WINDOW_S = 30.0     # how far back the statistics look, per band
SIG_MIN_OBS = 3         # observations needed before any hint is emitted
SIG_HOT_DB = 10.0       # sub-band "hot" threshold above the noise floor
SIG_FHSS_MIN_BINS = 3   # distinct hot sub-bands => hopping, not a tone
SIG_FHSS_MAX_DUTY = 0.6  # no single sub-band may dominate (else: static)
SIG_FHSS_MIN_ACTIVE = 0.3  # fraction of observations showing any hop
SIG_OFDM_MIN_BINS = 6   # hot sub-bands at once => wideband OFDM-like
SIG_OFDM_RISE_DB = 6.0  # ...with the median up this far (else: spurs)
SIG_TONE_MIN_DUTY = 0.7  # one sub-band persistently hot => carrier-like


class SigHistory:
    """Rolling per-band sub-band activity -> emitter *signature* hints.

    A signature is a pattern of energy over frequency and time, NOT an
    identification: "fhss-2g4" means "something is frequency-hopping in
    the 2.4 GHz ISM band the way ELRS-style control links hop", never
    "this is an ELRS drone" and never a drone claim of any kind.

    Hints (else None):
      fhss-2g4 .. 2.4 GHz band, energy hopping between sub-bands
                   (ELRS-style FHSS control link)
      fhss-900m . 900 MHz band, same hopping behaviour
                   (ELRS-900 / Crossfire-style)
      ofdm-5g ... 5 GHz band, energy elevated across most sub-bands at
                   once with the median lifted (DJI O4-style OFDM video)
      tone-5g8 .. 5.8 GHz band, one sub-band persistently hot
                   (analog-FPV-style video carrier)

    Needs several observations of the band (a few seconds at least);
    returns None until then and for anything that matches no pattern.
    """

    def __init__(self, window_s=SIG_WINDOW_S, min_obs=SIG_MIN_OBS):
        self.window_s = window_s
        self.min_obs = min_obs
        self._hist = {}  # band label -> deque of (t, bins[8], energy, noise)

    def observe(self, label, center_mhz, t, bins, energy, noise):
        """Record one band measurement; return this band's sig_hint."""
        dq = self._hist.setdefault(label, deque())
        dq.append((t, list(bins), float(energy), float(noise)))
        while dq and t - dq[0][0] > self.window_s:
            dq.popleft()
        return self._classify(center_mhz, dq)

    @staticmethod
    def _family(center_mhz):
        if 2400.0 <= center_mhz < 2500.0:
            return "2g4"
        if 850.0 <= center_mhz < 960.0:
            return "900m"
        if 5000.0 <= center_mhz < 6000.0:
            return "5g"
        return None

    def _classify(self, center_mhz, dq):
        if len(dq) < self.min_obs:
            return None
        family = self._family(center_mhz)
        if family is None:
            return None
        # hot[i][k]: sub-band k hot in observation i.
        hots = [[b > n + SIG_HOT_DB for b in bins]
                for _, bins, _, n in dq]
        n = len(hots)
        duty = [sum(h[k] for h in hots) / n for k in range(8)]
        distinct = sum(1 for k in range(8) if duty[k] > 0)
        _, _, energy, _ = dq[-1]

        if family == "5g":
            # Quiet reference: the calmest floor seen in the window. A
            # wideband burst is only recognizable against quiet the
            # bridge has actually observed -- at startup with an
            # already-active emitter there is no reference yet (None).
            quiet = min(n for _, _, _, n in dq)
            bins_now = dq[-1][1]
            wide_hot = sum(1 for b in bins_now if b > quiet + SIG_HOT_DB)
            # DJI O4-like: wideband OFDM lifts the whole band -- median
            # up against the quiet floor, most sub-bands hot with it.
            if (energy > quiet + SIG_OFDM_RISE_DB
                    and wide_hot >= SIG_OFDM_MIN_BINS):
                return "ofdm-5g"
            # Analog-FPV-like: one carrier sitting in the 5.8 GHz video
            # band, present most of the time.
            if (center_mhz >= 5650.0 and distinct <= 2
                    and max(duty) >= SIG_TONE_MIN_DUTY):
                return "tone-5g8"
            return None
        # ELRS/Crossfire-like: the energy hops between sub-bands --
        # several visited, none dominant, activity sustained.
        active_frac = sum(1 for h in hots if any(h)) / n
        if (distinct >= SIG_FHSS_MIN_BINS
                and max(duty) < SIG_FHSS_MAX_DUTY
                and active_frac >= SIG_FHSS_MIN_ACTIVE):
            return "fhss-" + family
        return None


# ---------------------------------------------------------------- main

def parse_dest(s):
    host, _, port = s.rpartition(":")
    if not host:
        host = s
        port = ""
    return host, int(port or UDP_PORT_DEFAULT)


def parse_kv(s):
    out = {}
    for item in s.split(","):
        item = item.strip()
        if not item:
            continue
        k, _, v = item.partition("=")
        out[k.strip()] = v.strip()
    return out


def make_backend(name, args):
    if name == "pluto":
        return PlutoBackend(args.pluto_uri, args.gain)
    if name == "uhd":
        return UsrpBackend(args.uhd_args, args.gain)
    if name == "rtlsdr":
        return RtlSdrBackend(args.rtlsdr_index, args.gain)
    if name == "soapy":
        if not args.soapy_driver:
            sys.exit("--backend soapy needs --soapy-driver "
                     "(e.g. hackrf, airspy, lime, sdrplay, bladerf)")
        return SoapyBackend(args.soapy_driver, parse_kv(args.soapy_args),
                            args.gain, args.soapy_rate)
    if name == "simulate":
        return SimBackend()
    raise ValueError(f"unknown backend {name}")


def auto_backend(args):
    """First working backend wins: pluto -> uhd -> rtlsdr -> any Soapy."""
    for cand in ("pluto", "uhd", "rtlsdr"):
        try:
            return make_backend(cand, args), cand
        except SystemExit:
            continue  # missing library: try the next one
        except Exception as e:
            print(f"[{cand}] not usable: {e}")
    try:
        import SoapySDR
        for dev in SoapySDR.Device.enumerate():
            drv = dev.get("driver", "")
            if drv in SOAPY_CAPS:
                args.soapy_driver = drv
                return make_backend("soapy", args), f"soapy-{drv}"
        print("[soapy] enumerated devices: "
              + ", ".join(str(d.get("driver", "?"))
                          for d in SoapySDR.Device.enumerate()))
    except Exception as e:
        print(f"[soapy] not usable: {e}")
    sys.exit("No SDR backend found. Install a backend library "
             "(pyadi-iio, uhd, pyrtlsdr, or SoapySDR+PothosSDR),\n"
             "or run with --simulate to test without hardware.")


def main():
    ap = argparse.ArgumentParser(description="Shepherd SDR bridge (RX only)")
    ap.add_argument("--backend", default="auto",
                    choices=["auto", "pluto", "uhd", "rtlsdr", "soapy",
                             "simulate"])
    ap.add_argument("--pluto-uri", default="ip:192.168.2.1",
                    help="Pluto URI (default ip:192.168.2.1; use 'usb:' for USB)")
    ap.add_argument("--uhd-args", default="",
                    help='UHD device args, e.g. "type=b200"')
    ap.add_argument("--rtlsdr-index", type=int, default=0,
                    help="RTL-SDR device index (default 0)")
    ap.add_argument("--soapy-driver", default="",
                    help="SoapySDR driver: hackrf, airspy, lime, sdrplay, bladerf...")
    ap.add_argument("--soapy-args", default="",
                    help='extra SoapySDR device args, e.g. "serial=1234"')
    ap.add_argument("--soapy-rate", type=float, default=4e6,
                    help="SoapySDR sample rate (default 4000000)")
    ap.add_argument("--simulate", action="store_true",
                    help="synthetic spectrum, no hardware needed")
    ap.add_argument("--max-mhz", type=float, default=0.0,
                    help="override the radio's frequency ceiling in MHz")
    ap.add_argument("--name", default="",
                    help="radio name in packets (default: backend-based)")
    ap.add_argument("--dest", default="127.0.0.1:49161",
                    help="where Shepherd listens (host:port)")
    ap.add_argument("--gain", type=float, default=40.0,
                    help="manual RX gain dB (FIXED while sensing)")
    ap.add_argument("--stare", type=float, default=0.0,
                    help="stare at one band center in MHz instead of sweeping")
    ap.add_argument("--dwell", type=int, default=1,
                    help="extra captures per band per sweep (default 1)")
    ap.add_argument("--bands", default="",
                    help="custom band list like 433.92/1,915/2,2437/20")
    ap.add_argument("--plan", default="", choices=["", "fpv", "dji",
                    "longrange", "lora"],
                    help="named band plan: fpv (drone FPV footprint), dji "
                    "(OcuSync/O4), longrange (sub-GHz RC), lora (LoRa watch). "
                    "Explicit --bands/--stare win over --plan.")
    ap.add_argument("--print", dest="print_only", action="store_true",
                    help="print packets as JSON lines instead of sending UDP")
    ap.add_argument("--sweeps", type=int, default=0,
                    help="run N sweeps then exit (0 = run forever)")
    args = ap.parse_args()

    # ---- backend
    if args.simulate:
        backend, bname = SimBackend(), "simulate"
    elif args.backend == "auto":
        backend, bname = auto_backend(args)
    else:
        backend, bname = make_backend(args.backend, args), args.backend

    if args.max_mhz > 0:
        backend.max_mhz = args.max_mhz
    radio = args.name or f"{backend.name}0"
    print(f"[bridge] backend={bname} radio={radio} "
          f"gain={args.gain} dB (manual, fixed) dest={args.dest} -- RX ONLY")

    # ---- bands (skip anything above this radio's ceiling).
    # Precedence: explicit --bands > --stare > --plan > default sweep.
    if args.bands:
        bands = []
        for item in args.bands.split(","):
            item = item.strip()
            if not item:
                continue
            c, _, b = item.partition("/")
            try:
                bands.append((c, float(c), float(b or 4.0)))
            except ValueError:
                sys.exit(f"bad --bands item {item!r}: use centerMHz[/bwMHz], "
                         "e.g. 433.92/1,915/2,2437/20")
    elif args.stare:
        bands = [(f"{args.stare:g}", args.stare, 20.0)]
    elif args.plan:
        bands = list(PLANS[args.plan])
    else:
        bands = list(DEFAULT_BANDS)
    kept = [b for b in bands if b[1] <= backend.max_mhz]
    skipped = len(bands) - len(kept)
    bands = kept
    if not bands:
        sys.exit("No bands within this radio's frequency range. "
                 "Use --bands to pick lower ones or --stare <mhz>.")
    print(f"[bridge] bands: {', '.join(f'{n}@{c:g}MHz' for n, c, _ in bands)}"
          + (f" ({skipped} above {backend.max_mhz:g} MHz skipped)"
             if skipped else ""))

    host, port = parse_dest(args.dest)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def emit(pkt):
        # allow_nan=False: NaN/Infinity are not valid JSON and Shepherd's
        # decoder would drop the whole datagram. Callers pre-check finite.
        data = json.dumps(pkt, allow_nan=False)
        if args.print_only:
            print(data, flush=True)
            return
        try:
            sock.sendto(data.encode(), (host, port))
        except OSError as e:  # unreachable host, buffer full, etc.
            now = time.time()
            if now - emit.last_err > 30.0:
                emit.last_err = now
                print(f"[bridge] send failed ({e}); will keep trying")
    emit.last_err = 0.0

    labels = [n for n, _, _ in bands]
    last_beacon = 0.0
    sweeps_done = 0
    dropped = 0
    last_warn = 0.0
    sig_hist = SigHistory()  # emitter-signature hints, per band

    def finite_all(vals):
        return all(math.isfinite(v) for v in vals)

    try:
        while True:
            for label, center, bw in bands:
                backend.tune(center, bw, args.gain)
                ms = []
                for _ in range(max(1, args.dwell)):
                    x = backend.capture(CAPTURE_N)
                    if x is None or len(x) < MIN_CAPTURE_N:
                        continue  # failed/short read: never report as data
                    m = band_measurement(x, backend.sample_rate, bw)
                    if m is not None:
                        ms.append(m)
                if not ms:
                    # Reporting a fake "-120 dBFS" here would poison
                    # Shepherd's baseline and cause a phantom emitter on
                    # the next good read. Stay silent instead; Shepherd
                    # treats missing data as missing data.
                    dropped += 1
                    now = time.time()
                    if now - last_warn > 30.0:
                        last_warn = now
                        print(f"[bridge] band {label}: capture failed "
                              f"({dropped} dropped so far)")
                    continue
                energy = sum(m["energy"] for m in ms) / len(ms)
                noise = sum(m["noise"] for m in ms) / len(ms)
                bins = [sum(m["bins"][i] for m in ms) / len(ms)
                        for i in range(8)]
                top = max(ms, key=lambda m: m["peak_dbfs"])
                peak_mhz = center + top["peak_off_mhz"]
                vals = [energy, noise, top["peak_dbfs"], peak_mhz] + bins
                if not finite_all(vals):
                    dropped += 1
                    continue
                now = time.time()
                sig_hint = sig_hist.observe(label, center, now,
                                            bins, energy, noise)
                pkt = {"v": 1, "kind": "band", "radio": radio, "band": label,
                       "center_mhz": center, "bw_mhz": bw,
                       "energy_dbfs": round(energy, 1),
                       "noise_dbfs": round(noise, 1),
                       "bins_dbfs": [round(b, 1) for b in bins],
                       "peak_mhz": round(peak_mhz, 3),
                       "peak_dbfs": round(top["peak_dbfs"], 1),
                       "span_mhz": round(top["span_mhz"], 3),
                       "sig_hint": sig_hint,
                       "t": now}
                emit(pkt)
            sweeps_done += 1
            now = time.time()
            if now - last_beacon >= BEACON_S:
                last_beacon = now
                bc = {"v": 1, "kind": "beacon", "radio": radio,
                      "backend": backend.name, "bands": labels,
                      "dropped": dropped, "t": now}
                emit(bc)
            if args.sweeps and sweeps_done >= args.sweeps:
                break
    except KeyboardInterrupt:
        print("\n[bridge] stopping")
    finally:
        backend.close()


if __name__ == "__main__":
    main()
