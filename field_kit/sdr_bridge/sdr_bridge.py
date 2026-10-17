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
     "t":1729123456.789}

  beacon packet (every 10 s, lets Shepherd show bridge status):
    {"v":1,"kind":"beacon","radio":"rtlsdr0","backend":"rtlsdr",
     "bands":["433","915"],"t":1729123456.789}

Examples:
  python sdr_bridge.py --simulate
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

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: pip install -r requirements.txt")

UDP_PORT_DEFAULT = 49161
SAMPLE_RATE = 4_000_000      # Pluto/USRP/Soapy-practical; RTL-SDR uses 2.4e6
CAPTURE_N = 16384
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
        # pyadi-iio returns int16-scale complex; normalize to [-1, 1].
        peak = np.max(np.abs(x))
        if peak > 1.5:  # looks like raw ADC counts
            x = x / 32768.0
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

    Lets the full pipeline be verified with no hardware. An emitter on
    2437 MHz appears 20 s after start, lasts 20 s, repeats every 90 s;
    a weak always-on carrier sits on 433 MHz like a LoRa beacon.
    """

    name = "simulate"
    max_mhz = 6000.0

    def __init__(self):
        self.t0 = time.time()
        self.center = 2437.0
        self.rng = np.random.default_rng(7)

    def tune(self, center_mhz, bw_mhz, gain_db):
        self.center = center_mhz
        self.bw = bw_mhz

    def _emitter_level_db(self, now):
        """Extra dB above the noise floor right now, for the tuned band."""
        el = now - self.t0
        lvl = 0.0
        if abs(self.center - 2437.0) < 1.0:
            phase = el % 90.0
            if 20.0 <= phase < 40.0:
                lvl = max(lvl, 28.0)
        if abs(self.center - 915.0) < 1.0:
            phase = el % 47.0
            if 5.0 <= phase < 9.0:
                lvl = max(lvl, 18.0)
        if abs(self.center - 433.92) < 1.0:
            lvl = max(lvl, 12.0)  # always-on weak carrier
        return lvl

    def capture(self, n):
        now = time.time()
        # Noise floor drifts slowly, like a real front end warming up.
        floor_db = -85.0 + 1.5 * math.sin((now - self.t0) / 120.0)
        floor_lin = 10 ** (floor_db / 20.0)
        x = (self.rng.standard_normal(n) + 1j * self.rng.standard_normal(n))
        x = (x / np.sqrt(2.0)).astype(np.complex64) * floor_lin
        lvl_db = self._emitter_level_db(now)
        if lvl_db > 0:
            # A tone-ish emitter with slight FM wobble, AM flutter.
            t = np.arange(n) / self.sample_rate
            fm = 0.15 * np.sin(2 * np.pi * 37.0 * t)
            tone = np.exp(2j * np.pi * fm * t).astype(np.complex64)
            amp = floor_lin * (10 ** (lvl_db / 20.0))
            am = (0.85 + 0.15 * np.sin(2 * np.pi * 3.0 * t)).astype(np.float32)
            x = x + (tone * amp * am).astype(np.complex64)
        return x


# ---------------------------------------------------------------- DSP

def psd_dbfs(x):
    """Power spectral density in dBFS (full-scale sine == 0 dBFS).

    Only deltas matter downstream; this just needs to be self-consistent.
    """
    n = len(x)
    if n == 0:
        return np.array([], dtype=np.float32)
    w = np.hanning(n).astype(np.float32)
    # Complex input -> full FFT (rfft would discard the imaginary part).
    spec = np.fft.fft(x * w)
    mag = np.abs(spec) * 2.0 / (n * np.mean(w))
    return (20.0 * np.log10(mag + 1e-12)).astype(np.float32)


def band_measurement(x):
    """Per-band energy metrics from one capture.

    energy: median PSD across the band -- the stable wideband metric and
        the primary tripwire input (robust to spurs and narrow tones).
    noise: 10th-percentile PSD -- the band's noise floor estimate.
    bins: per-sub-band (8) PEAK PSD -- catches narrowband emitters
        (LoRa/RC tones) that the median deliberately ignores. Peak-based,
        so spur-sensitive: treat as an investigation aid, and rely on the
        tripwire's confirm-polls + adaptive threshold before alarming.
    """
    p = psd_dbfs(x)
    if p.size == 0:
        return -120.0, -120.0, [-120.0] * 8
    energy = float(np.median(p))
    noise = float(np.percentile(p, 10))
    edges = np.array_split(p, 8)
    bins = [float(np.max(e)) if e.size else -120.0 for e in edges]
    return energy, noise, bins


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

    # ---- bands (skip anything above this radio's ceiling)
    if args.bands:
        bands = []
        for item in args.bands.split(","):
            c, _, b = item.partition("/")
            bands.append((c, float(c), float(b or 4.0)))
    elif args.stare:
        bands = [(f"{args.stare:g}", args.stare, 20.0)]
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
        if args.print_only:
            print(json.dumps(pkt), flush=True)
        else:
            sock.sendto(json.dumps(pkt).encode(), (host, port))

    labels = [n for n, _, _ in bands]
    last_beacon = 0.0
    sweeps_done = 0

    try:
        while True:
            for label, center, bw in bands:
                backend.tune(center, bw, args.gain)
                x = None
                for _ in range(max(1, args.dwell)):
                    x = backend.capture(CAPTURE_N)
                energy, noise, bins = band_measurement(x)
                pkt = {"v": 1, "kind": "band", "radio": radio, "band": label,
                       "center_mhz": center, "bw_mhz": bw,
                       "energy_dbfs": round(energy, 1),
                       "noise_dbfs": round(noise, 1),
                       "bins_dbfs": [round(b, 1) for b in bins],
                       "t": time.time()}
                emit(pkt)
            sweeps_done += 1
            now = time.time()
            if now - last_beacon >= 10.0:
                last_beacon = now
                bc = {"v": 1, "kind": "beacon", "radio": radio,
                      "backend": backend.name, "bands": labels, "t": now}
                emit(bc)
            if args.sweeps and sweeps_done >= args.sweeps:
                break
    except KeyboardInterrupt:
        print("\n[bridge] stopping")
    finally:
        backend.close()


if __name__ == "__main__":
    main()
