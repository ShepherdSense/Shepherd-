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

  elrs_chirp packet (throttled, max ~1 per band per 2 s):
    {"v":1,"kind":"elrs_chirp","radio":"rtlsdr0","band":"2437",
     "center_mhz":2437.0,"freq_mhz":2441.23,"sf":5,"bw_khz":812.5,
     "snr_db":14.2,"t":1729123456.789}

  (One detected LoRa chirp train: the dechirp detector found a
  preamble-like train of back-to-back upchirps at freq_mhz. LoRa
  MODULATION evidence, not an ELRS identification -- any LoRa emitter
  in the (SF, BW) grid lights this up. Shepherd correlates these
  across radios/bands for the Gemini signature and treats them as
  corroboration only.)

  elrs_signature packet (bridge-local dual-frequency coincidence):
    {"v":1,"kind":"elrs_signature","radio":"usrp0","mode":"gemini-2g4",
     "score":0.62,"obs":7,"bands":["2437"],
     "freqs_mhz":[2441.2,2481.3],"t":1729123456.789}

  (mode "gemini-2g4"/"gemini-900m": time-correlated chirp trains on two
  frequencies with the documented Gemini separation, seen in ONE
  capture -- needs >= ~50 MHz instantaneous bandwidth, so most radios
  never emit this. score 0..1 grows with repeated coincidences;
  "obs" counts them. Language contract: "signature consistent with
  ELRS Gemini", NEVER "confirmed ELRS".)

  doppler_ref packet (ambient-LTE Doppler; at most ~1 per 0.5 s CPI
  while a peak persists):
    {"v":1,"kind":"doppler_ref","radio":"rtlsdr0",
     "center_mhz":1865.0,"doppler_hz":-14.2,"radial_ms":-1.14,
     "snr_db":11.3,"ref_locked":true,"t":1729123456.789}

  (Passive Doppler on the ambient LTE downlink -- the carrier transmits
  it whether or not we listen; the bridge only receives and never
  decodes payload bits. Emitted only on a --stare (Doppler mode),
  where it replaces the band-energy packet: the Doppler chain is
  STARE-ONLY -- a --bands/--plan list containing 1.8-1.9 GHz (or any
  LTE DL centre) is a sweep and emits band packets, not doppler_ref
  (see the routing note in main()). doppler_hz /
  radial_ms are signed with approaching = negative (app convention);
  radial_ms = doppler_hz * c / (2 * center_hz). snr_db is the peak over
  the clutter-canceled floor. ref_locked=false means the direct-path
  reference was lost -- no coherent measurement that CPI; Shepherd must
  give such events zero weight. Silent when the reference is locked
  and nothing clears the SNR gate.)

  lte_illuminator packet (LTE downlink illuminator presence; sweep
  mode only, at most ~1 per band per sweep while detected):
    {"v":1,"kind":"lte_illuminator","radio":"rtlsdr0","band":"465",
     "center_mhz":465.0,"dl_band":"LTE450","occupied_bw_mhz":3.1,
     "flatness_db":1.8,"snr_db":19.4,"t":1729123456.789}

  (A flat-top wideband signal occupying an LTE downlink band -- an
  illuminator-of-opportunity presence report, NOT an LTE
  identification: this DSP level cannot distinguish an LTE downlink
  from any other flat wideband energy in the band, and it never
  decodes payload bits. On an LTE-band --stare (the --stare flag;
  an explicit single-band --bands list is still a sweep) the bridge
  instead runs the existing doppler_ref chain, so no
  lte_illuminator packet is emitted there -- the Doppler events are
  the feed. ADDITIVE packet kind: older Shepherd builds ignore
  unknown kinds; every pre-existing packet schema is unchanged.)

  LTE450 HONESTY NOTE (read before quoting any range): the ~1.6 km
  bistatic figure sometimes attached to FKIE LTE450 (Demissie &
  Steffes, IET Radar Sonar & Navigation 2025, e70092) is CLAIMED,
  not validated: it reaches Shepherd through a single secondary
  source (MiGFlug blog, Oct 2025, read in full) while the paper's
  full text remains UNREAD (bot-blocked on every host tried). It is
  NOT a Shepherd capability, NOT a validated target, and must never
  be quoted as one. The bench-measurement hook in this file
  (LteBenchLog / summarize_lte_bench) exists so an operator can
  replace that claimed number with a measured detection-vs-range
  curve from their own known-range passes. LTE450 is enabled only
  by operator opt-in (--lte450, or an explicit --bands/--stare
  listing it) -- the operator's radio must cover ~465 MHz and local
  rules must allow passive reception there; the bridge only ever
  receives.

  5G NR adapter (v0.25.0): a documented, tested STUB. NR downlink
  channels are 20-100 MHz wide; the bridge pipeline runs at 4 MSPS
  (2.4 MSPS RTL-SDR), so no available radio configuration can
  practically ingest an NR channel here -- even a USRP at the
  bridge's 4 MSPS sees only a 3.2 MHz slice, which cannot identify
  NR. The Nr5gAdapter therefore gates on USRP-class hardware at
  >= 20 MSPS, and even when that gate opens it emits NOTHING: the
  interface (band table, probe/status) exists so a future wideband
  capture path can fill it in, but no NR detection runs today and
  no NR packet kind is emitted. No BSense numbers are claimed
  anywhere for Shepherd (no 1 km, no F1 95.56% -- BSense ran on a
  carrier 5G-A base station Shepherd does not control).

  wpp_idp_doppler packet (single-channel passive-radar Doppler line):
    {"v":1,"kind":"wpp_idp_doppler","radio":"rtlsdr0","band":"2437",
     "center_mhz":2437.0,"doppler_hz":40.0,"strength":16.2,
     "t":1729123456.789,"motion_state":"static"}

  (Bridge-side half of the WPP-IDP chain: per-preamble energy E[n] ->
  DC removal -> Doppler line. The full STFT/CFAR chain lives in
  passive_radar/. doppler_hz is the line frequency as a magnitude --
  the energy time series is real, so its spectrum is symmetric and the
  inbound/outbound sign is ambiguous here; direction is resolved
  app-side against track geometry. strength is the line peak-to-median
  in dB: a disturbance strength, never an identity. motion_state is
  this node's motion state; Shepherd must not merge moving-node lines
  into track confidence -- ego-motion compensation for this chain is
  an unsolved open problem.)

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
import csv
import json
import math
import socket
import sys
import time
from collections import deque

import elrs_detect
import doppler_detect
import wpp_idp_detect

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
                burst 20-40 s of each 90 s, then LoRa chirp trains
                100-108 s of each 180 s (ELRS-demo: wall-clock-gated,
                time-correlated with
                the 915 MHz chirp window so two bridge instances demo the
                app-level GemX correlation)
      915 MHz:  LoRa-like narrowband burst 5-9 s of each 47 s, plus LoRa
                chirp trains 100-108 s of each 180 s (GemX-demo partner
                to the 2437 MHz window)
      5780 MHz: DJI O4-like wideband OFDM burst (first 20 s of each
                150 s, after one quiet capture so the detector learns
                a baseline), then an analog-FPV-like static carrier
                60-80 s
      433 MHz:  weak always-on LoRa-like carrier
      1865 MHz: ambient-LTE Doppler demo band (1.8-1.9 GHz): an
                always-on direct-path tone (the tracker's reference) plus
                a wall-clock-gated mover echo at +14.2 Hz physical
                (approaching; reported doppler_hz -14.2, radial -1.14 m/s)
                15-45 s of each 90 s. Phase-continuous across captures so
                the 0.5 s CPI is genuinely coherent.
      2437 MHz: also carries an always-on ambient-WiFi-like frame train
                (identical 1 ms preamble bursts every 5 ms + random data)
                with a wall-clock-gated 40 Hz mover echo 30-60 s of each
                120 s, for the WPP-IDP estimator demo.
    """

    name = "simulate"
    max_mhz = 6000.0

    def __init__(self):
        self.t0 = time.time()
        self.center = 2437.0
        self.rng = np.random.default_rng(7)
        self._cap_n = 0            # total captures (drives the hop slot)
        self._band_caps = {}       # rounded center MHz -> completed captures
        self._dop_n = 0            # samples emitted on the Doppler band
        self._wpp_n = 0            # samples emitted on the WPP demo band

    def tune(self, center_mhz, bw_mhz, gain_db):
        self.center = center_mhz
        self.bw = bw_mhz

    def _emitter(self, now):
        """(level dB above floor, kind) for the tuned band right now.

        kind: "wide" (wideband burst), "tone" (static narrowband),
              "hop" (frequency-hopping narrowband), or None.
        """
        el = now - self.t0
        if 1800.0 <= self.center < 1900.0:
            # Ambient-LTE Doppler demo band: the direct path (strongest
            # static component = the tracker's reference) is always
            # present; the mover echo is wall-clock gated in capture().
            return 25.0, "doppler"
        # Chirp windows are gated on WALL-CLOCK epoch, not instance
        # time, so two --simulate instances (e.g. 2437 + 915 stares)
        # emit time-correlated trains for the app-level GemX demo
        # however far apart they were started.
        epoch180 = now % 180.0
        if abs(self.center - 2437.0) < 1.0:
            if 100.0 <= epoch180 < 108.0:
                return 20.0, "chirp"  # ELRS-demo chirp trains (GemX pair)
            if (el % 120.0) < 20.0:
                return 25.0, "hop"    # ELRS-like FHSS hopper
            if 20.0 <= (el % 90.0) < 40.0:
                # FPV/Wi-Fi-like wideband burst: raises the band MEDIAN.
                return 28.0, "wide"
            return 0.0, None
        if abs(self.center - 915.0) < 1.0:
            if 100.0 <= epoch180 < 108.0:
                return 20.0, "chirp"  # ELRS-demo chirp trains (GemX pair)
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
            # M14: the gate reads a MHz-normalized band key. The branch
            # above matches any center within 1 MHz of 5780 (so
            # --stare 5780.5 enters it), but the old exact-float
            # _band_caps.get(5780.0) key was never primed by such a
            # stare, silently disabling the burst.
            if (self._band_caps.get(5780, 0) >= 1
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
        if kind == "doppler":
            return self._synth_doppler(x, n, now, floor_lin)
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
            elif kind == "chirp":
                # ELRS-demo: real LoRa upchirp trains (SF5, 812.5 kHz --
                # the ELRS 2.4 GHz LoRa-mode grid), hopping offsets, at
                # a deterministic wall-clock slot so two bridge
                # instances (2.4 GHz + 900 MHz stares) emit
                # time-correlated trains for the app-level GemX demo.
                up = elrs_detect.lora_upchirp(5, 812_500.0,
                                              self.sample_rate)
                sig = np.tile(up, 6)
                hop = (self._cap_n * 3 + 2) % 6
                off_hz = (hop - 2.5) * 400e3
                tseg = np.arange(len(sig)) / self.sample_rate
                sig = (sig * np.exp(2j * np.pi * off_hz * tseg) * amp
                       ).astype(np.complex64)
                start = (self._cap_n * 7919) % (n - len(sig))
                x[start:start + len(sig)] += sig
            else:
                # Narrowband: tone 150 kHz off centre with FM wobble.
                ph = (2 * np.pi * 150e3 * t
                      + 2.0 * np.sin(2 * np.pi * 37.0 * t))
                x = x + (np.exp(1j * ph) * amp).astype(np.complex64)
        if (462.5 <= self.center <= 467.5
                and self._band_caps.get(465, 0) >= 1):
            # LTE450 demo: a flat-top wideband signal filling the
            # usable span, like an LTE downlink slice -- RX-only
            # synthetic receive data, not a transmission, and not
            # an LTE identification (shape only, like the detector).
            # Gated on one prior quiet capture of this band, like
            # the 5780 MHz OFDM demo: the LTE detector needs a
            # quiet reference before it can report, and this makes
            # the demo deterministic.
            amp = floor_lin * (10 ** (20.0 / 20.0))
            w = (self.rng.standard_normal(n)
                 + 1j * self.rng.standard_normal(n)) / np.sqrt(2.0)
            W = np.fft.fftshift(np.fft.fft(w))
            fr = np.fft.fftshift(np.fft.fftfreq(n, d=1.0 / self.sample_rate))
            W[np.abs(fr) > 1.5e6] = 0.0
            flat = np.fft.ifft(np.fft.ifftshift(W))
            # FFT/IFFT round-trip preserves RMS up to the mask
            # fraction; rescale to the intended amplitude.
            rms = float(np.sqrt(np.mean(np.abs(flat) ** 2))) or 1.0
            x = x + (flat / rms * amp).astype(np.complex64)
        if abs(self.center - 2437.0) < 1.0:
            # WPP-IDP demo: ambient WiFi-like frame train (always on)
            # + wall-clock-gated mover echo. Coexists with the band's
            # other scripted emitters, like real ambient traffic would.
            x = self._synth_wpp(x, n, now, floor_lin)
        self._cap_n += 1
        # MHz-normalized band key (round(5780.5) == 5780): a stare at any
        # center in the 5780 branch primes the same gate the burst
        # checks in _emitter (M14). Distinct real bands never collide
        # after rounding (433.92->434, 915->915, 1290->1290, ...).
        key = round(self.center)
        self._band_caps[key] = self._band_caps.get(key, 0) + 1
        return x

    def _synth_doppler(self, x, n, now, floor_lin):
        """Ambient-LTE Doppler demo band (1.8-1.9 GHz).

        The direct path is modeled as its strongest static component --
        a tone at DC, always present -- not a full LTE waveform; the
        tracker only needs the phase reference, and the simplification
        is documented. The mover echo sits 15 dB below the reference at
        +14.2 Hz physical (approaching), wall-clock gated 15-45 s of
        each 90 s epoch. Sample-continuous across capture() calls via
        self._dop_n, so the tracker's 0.5 s CPI is genuinely coherent.
        RX-only: this is synthetic receive data, not a transmission.
        """
        tg = (self._dop_n + np.arange(n)) / self.sample_rate
        a_ref = floor_lin * 10 ** (25.0 / 20.0)
        x = x + np.complex64(a_ref)
        if 15.0 <= (now % 90.0) < 45.0:
            a_echo = floor_lin * 10 ** (10.0 / 20.0)
            x = x + (a_echo * np.exp(2j * np.pi * 14.2 * tg)
                     ).astype(np.complex64)
        self._dop_n += n
        self._cap_n += 1
        key = round(self.center)
        self._band_caps[key] = self._band_caps.get(key, 0) + 1
        return x

    def _synth_wpp(self, x, n, now, floor_lin):
        """WPP-IDP demo: ambient WiFi-like frame train on 2.4 GHz.

        200 frames/s; each frame = 1 ms IDENTICAL wideband preamble
        burst (fixed prototype, tapered -- wideband like a real 802.11
        preamble, so its energy spreads across the band instead of
        sitting hot in one spectral bin) + 4 ms random data symbols at
        constant amplitude (ambient traffic). The mover echo (0.35x,
        +40 Hz physical) is wall-clock gated 30-60 s of each 120 s
        epoch: it impresses the slow 40 Hz amplitude modulation on the
        per-preamble energy that the WPP-IDP estimator detects.
        Sample-continuous across captures. RX-only: synthetic receive
        data, not a transmission.
        """
        fs = self.sample_rate
        tg = (self._wpp_n + np.arange(n)) / fs
        frame_hz = 200.0
        ph = (tg * frame_hz) % 1.0
        is_pre = ph < 0.2
        a = floor_lin * 10 ** (8.0 / 20.0)
        # Fixed prototype: identical every frame, every capture.
        pre_len = max(16, int(round(fs * 0.2 / frame_hz)))
        prng = np.random.default_rng(1234)
        proto = ((prng.standard_normal(pre_len)
                  + 1j * prng.standard_normal(pre_len))
                 / np.sqrt(2.0)).astype(np.complex64)
        pre_pos = np.clip(ph / 0.2, 0.0, 1.0)
        taper = (np.sin(np.pi * pre_pos) ** 2) * is_pre
        pre_idx = np.minimum((pre_pos * pre_len).astype(np.int64),
                             pre_len - 1)
        pre = (a * proto[pre_idx] * taper * is_pre).astype(np.complex64)
        d = (((self.rng.standard_normal(n)
               + 1j * self.rng.standard_normal(n)) / np.sqrt(2.0))
             * (a * (~is_pre))).astype(np.complex64)
        s = pre + d
        if 30.0 <= (now % 120.0) < 60.0:
            s = s + (0.35 * s * np.exp(2j * np.pi * 40.0 * tg)
                     ).astype(np.complex64)
        self._wpp_n += n
        return x + s


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


# Noise-floor estimator: the 20th percentile of the in-band PSD,
# recomputed from every capture, so the estimate -- and every
# threshold derived from it -- continuously adapts to the band.
#
# Design follows the adaptive detector in Sorecău et al., "SDR System
# for Real-Time FHSS Communications Detection and Jamming," Int.
# Conf. Knowledge-Based Organization XXXI(3), 2025,
# DOI 10.2478/kbo-2025-0093: noise floor = 20th percentile of the
# spectrum, detection threshold = floor + a dB offset (SIG_HOT_DB in
# the signature scorer below). Defensive detection only: just the
# detector design is borrowed -- Shepherd is RX-only and has no
# transmit path of any kind.
#
# Why 20th, replacing the old 10th percentile: on a flat AWGN floor
# the two differ by only ~0.8 dB, but the 10th percentile is fragile
# against low-side outliers -- when >10% of bins sit in a fade or a
# filter notch it collapses toward the notch (measured ~11 dB under
# the true floor on a synthetic notched spectrum), dragging the
# SIG_HOT_DB threshold down with it and inviting false FHSS calls.
# The 20th percentile stayed within ~1 dB of the true floor in the
# same test. A genuinely wideband emitter still lifts it (any
# percentile would move) -- that case is the median/energy metric's
# job, and the OFDM scorer compares against the calmest floor seen
# in its window, not the current one.
NOISE_FLOOR_PCT = 20.0


def noise_floor_dbfs(ps_dbfs):
    """Adaptive noise-floor estimate: the NOISE_FLOOR_PCT percentile
    of an in-band PSD array in dBFS. See the note above the constant."""
    return float(np.percentile(ps_dbfs, NOISE_FLOOR_PCT))


def band_measurement(x, sample_rate=SAMPLE_RATE, bw_mhz=None):
    """Per-band energy metrics from one capture, or None if unusable.

    Only the part of the spectrum inside the requested band (clipped to
    the central USABLE_FRAC of the sample rate) is measured:

    energy: median PSD across the band -- the stable wideband metric and
        the primary tripwire input (robust to spurs and narrow tones).
    noise: adaptive noise floor -- 20th-percentile PSD, recomputed per
        capture (see NOISE_FLOOR_PCT; Sorecău et al. 2025 detector
        design, defensive detection only).
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
    noise = noise_floor_dbfs(ps)
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
# the band's own adaptive noise floor (20th-percentile PSD, recomputed
# per capture -- see NOISE_FLOOR_PCT; Sorecău et al. 2025 detector
# design, defensive detection only). Self-calibrating per band and per
# capture, so it survives gain differences and tracks a drifting floor:
# a slow broadband rise lifts bins and floor together and never reads
# as hopping, while a real hopper's sub-band peaks stand tens of dB
# over the floor -- far above the gate under either percentile.
SIG_WINDOW_S = 30.0     # how far back the statistics look, per band
SIG_MIN_OBS = 3         # observations needed before any hint is emitted
SIG_HOT_DB = 12.0       # sub-band "hot" threshold above the noise floor
                      # (measured: the worst single-bin noise excursion on
                      # pure AWGN is ~7.6 dB over 200 trials, leaving only
                      # ~2.4 dB headroom under 10 dB; 12 dB buys margin
                      # against front-end spurs without touching any
                      # scripted emitter -- the weakest, the 915 MHz
                      # LoRa-like tone, still sits 18 dB up. Against the
                      # 20th-percentile floor the worst excursion measures
                      # ~6.7 dB over 30 trials: the gate is unchanged, its
                      # margin grew by ~1 dB.)
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

    Thresholding is percentile-adaptive: each observation's sub-bands
    are judged against that same capture's 20th-percentile noise floor
    + SIG_HOT_DB (see NOISE_FLOOR_PCT), never against a fixed level,
    so a rising or drifting floor does not false-alarm.
    """

    def __init__(self, window_s=SIG_WINDOW_S, min_obs=SIG_MIN_OBS):
        self.window_s = window_s
        self.min_obs = min_obs
        self._hist = {}  # band label -> deque of (t, bins[8], energy, noise)
        # M3: ofdm-5g latch, label -> pre-burst quiet reference. A burst
        # that outlives the rolling window purges its own quiet
        # reference, so the hint latches at trigger time and releases
        # only when the band median falls back near that reference.
        self._ofdm_latch = {}

    def observe(self, label, center_mhz, t, bins, energy, noise):
        """Record one band measurement; return this band's sig_hint.

        The wall-clock `t` is accepted for API compatibility (tests and
        callers may drive synthetic timelines) but no longer drives the
        window: bookkeeping runs on the monotonic clock, so a forward
        NTP step cannot flush the history (detector blind for seconds)
        and a backward step cannot linger stale hints (LOW-N). The
        packet "t" field keeps using wall-clock time, set by the caller.
        """
        dq = self._hist.setdefault(label, deque())
        now = time.monotonic()
        dq.append((now, list(bins), float(energy), float(noise)))
        while dq and now - dq[0][0] > self.window_s:
            dq.popleft()
        return self._classify(label, center_mhz, dq)

    @staticmethod
    def _family(center_mhz):
        if 2400.0 <= center_mhz < 2500.0:
            return "2g4"
        if 850.0 <= center_mhz < 960.0:
            return "900m"
        if 5000.0 <= center_mhz < 6000.0:
            return "5g"
        return None

    def _classify(self, label, center_mhz, dq):
        if len(dq) < self.min_obs:
            return None
        family = self._family(center_mhz)
        if family is None:
            return None
        # hot[i][k]: sub-band k hot in observation i. Each observation
        # is judged against its OWN contemporaneous floor (n, the
        # capture's 20th-percentile estimate), so the hot threshold
        # adapts capture-to-capture -- percentile + offset, per
        # Sorecău et al.'s detector design (defensive detection only).
        hots = [[b > n + SIG_HOT_DB for b in bins]
                for _, bins, _, n in dq]
        n = len(hots)
        duty = [sum(h[k] for h in hots) / n for k in range(8)]
        distinct = sum(1 for k in range(8) if duty[k] > 0)

        if family == "5g":
            _, _, energy, _ = dq[-1]  # LOW-O: was unpacked for all families
            latch_quiet = self._ofdm_latch.get(label)
            if latch_quiet is not None:
                if energy < latch_quiet + SIG_OFDM_RISE_DB:
                    # Burst over: the median fell back near the pre-burst
                    # reference. Release the latch and classify fresh.
                    del self._ofdm_latch[label]
                    latch_quiet = None
                else:
                    return "ofdm-5g"
            if latch_quiet is None:
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
                    # M3: latch the hint against the PRE-burst quiet. A
                    # burst persisting past the window purges its own
                    # reference and would otherwise self-extinguish
                    # mid-burst. Releases when the median falls back.
                    self._ofdm_latch[label] = quiet
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


# ------------------------------------------------- LTE / 5G NR adapters
#
# RX-ONLY illuminators of opportunity. Both adapters RECEIVE ONLY:
# no TX code, no transmit-adjacent code (no attach, no RACH, no
# paging, no decoding of user payload bits -- the LTE detector reads
# only the SHAPE of the spectrum, the NR adapter reads nothing).
# They feed the existing Doppler-only track-refinement layer
# (doppler_ref, 0.5 s CPI -> ~2 Hz / ~0.16 m/s at 1.86 GHz): on an
# LTE-band stare the existing DopplerTracker runs; on sweeps the
# LTE detector reports illuminator presence per band. Neither
# adapter identifies a network, a handset, or a target, and neither
# produces a position.

# LTE downlink bands the adapter recognises: (name, low MHz, high MHz,
# is_lte450). FDD downlink only -- TDD bands are excluded because a
# shared uplink/downlink channel cannot be claimed as a downlink
# illuminator from spectrum shape alone. Matching is by tuned centre
# falling inside the DL range, so any stare inside a DL band works.
# FIRST-MATCH RULE (load-bearing for overlapping bands): the table
# is scanned in order and the first band containing the centre wins.
# B28 (758-803 MHz) and B20 (791-821 MHz) OVERLAP on 791-803 MHz, so
# a centre at e.g. 800 MHz is labelled B28 even where it is also B20
# -- the label is a table-lookup result, not a band identification,
# and downstream code must not treat it as one.
LTE_DL_BANDS = [
    ("LTE450", 462.5, 467.5, True),   # Band 31 DL; FKIE test freq
                                      # 467.37 MHz sits inside it.
                                      # Opt-in only (see --lte450).
    ("B28", 758.0, 803.0, False),
    ("B20", 791.0, 821.0, False),
    ("B12", 729.0, 746.0, False),
    ("B5", 869.0, 894.0, False),
    ("B8", 925.0, 960.0, False),
    ("B3", 1805.0, 1880.0, False),
    ("B2", 1930.0, 1990.0, False),
    ("B1", 2110.0, 2170.0, False),
    ("B7", 2620.0, 2690.0, False),
]

# 5G NR downlink bands, for the FUTURE real adapter. The v0.25.0
# Nr5gAdapter is a stub and never uses this table for detection;
# it is recorded here so the interface's band coverage is explicit
# and reviewable, not invented later under time pressure.
NR_DL_BANDS = [
    ("n28", 758.0, 803.0),
    ("n3", 1805.0, 1880.0),
    ("n1", 2110.0, 2170.0),
    ("n41", 2496.0, 2690.0),
    ("n77", 3300.0, 4200.0),
    ("n78", 3300.0, 3800.0),
]


def lte_band_for_center(center_mhz):
    """LTE DL band name for a tuned centre, or None if it is not
    inside any recognised downlink band. Returns (name, is_lte450).
    First match wins in LTE_DL_BANDS order: overlapping bands
    (B28/B20 on 791-803 MHz) resolve to the earlier entry, so
    800 MHz labels B28, not B20."""
    for name, low, high, is450 in LTE_DL_BANDS:
        if low <= center_mhz <= high:
            return name, is450
    return None


def nr_band_for_center(center_mhz):
    """NR DL band name for a tuned centre, or None. (Interface only;
    the stub adapter never calls this for detection.)"""
    for name, low, high in NR_DL_BANDS:
        if low <= center_mhz <= high:
            return name
    return None


# LTE illuminator-presence thresholds. A flat-top wideband signal
# fills the usable span nearly uniformly: most bins sit near the
# peak, and the span median sits near the peak too. A tone fails
# the median test (median stays at the noise floor); quiet fails
# the SNR test; a narrowband burst fails the fill test.
LTE_MIN_SNR_DB = 10.0     # peak over the bounded-window quiet floor
                          # (minimum 20th-percentile floor over the
                          # last LTE_QUIET_WINDOW captures at the
                          # centre -- NOT the current capture's floor)
LTE_QUIET_WINDOW = 20     # captures retained per centre for the
                          # quiet reference; a transient low floor
                          # (gain drop, antenna disconnect) expires
                          # after this many later captures instead
                          # of permanently inflating snr_db
LTE_MIN_FILL_FRAC = 0.70  # fraction of usable-span bins within 6 dB
                          # of the peak
LTE_FILL_DB = 6.0
LTE_MEDIAN_GAP_DB = 6.0   # span median must sit within this of peak


class LteIlluminatorDetector:
    """Spectrum-shape detector for LTE downlink illuminator presence.

    Input: one raw capture + sample rate + tuned centre. Output: a
    dict, or None when nothing illuminator-like is present (idle =
    silent, like every other bridge detector). The detection is a
    SHAPE claim only -- "flat-top wideband energy in an LTE DL band"
    -- never "this is LTE", never an identification, never a
    position. No payload bits are touched: psd_dbfs gives power per
    bin, and that is all this detector reads.

    Quiet-reference subtlety (load-bearing): a flat-top signal
    filling ~94% of the span lifts the CURRENT capture's own
    20th-percentile floor into the signal itself (measured: only
    ~6 dB of apparent SNR on a 20 dB signal), so SNR is measured
    against the CALMEST floor recently seen at this centre (same
    pattern as SigHistory's OFDM quiet reference), not the
    current capture's floor. The quiet reference is the
    BOUNDED-WINDOW minimum: the minimum 20th-percentile floor
    over the last LTE_QUIET_WINDOW captures at the centre, NOT
    an all-time minimum. A flat-top capture's floor is always
    HIGHER than a true quiet floor, so min-updating can never
    calibrate a real emitter away, and a later quiet capture
    repairs a reference seeded during an active emitter -- but
    the window is what keeps a TRANSIENT low floor honest: one
    gain drop or antenna disconnect used to permanently lower
    the reference and inflate every later snr_db (potentially
    pushing a genuinely sub-gate flat signal over the 10 dB
    gate); now that floor expires after LTE_QUIET_WINDOW
    later captures at the centre. Consequences, stated
    plainly: a centre whose emitter has NEVER been quiet reads
    only its own lifted floor (~6 dB apparent SNR, below the
    10 dB gate) and reports nothing -- at startup with an
    already-active full-span emitter the detector stays silent
    until one quiet capture arrives. White noise itself is
    spectrally flat, so shape alone cannot separate "signal" from
    "floor": the 10 dB SNR gate against the quiet reference is
    what does that (pure noise measures only ~7 dB peak-to-floor).
    Quiet references are keyed per (radio, centre) when the
    caller passes a key, else per centre.
    """

    def __init__(self, quiet_window=LTE_QUIET_WINDOW):
        if not isinstance(quiet_window, int) or quiet_window < 1:
            raise ValueError("quiet_window must be a positive int")
        self.quiet_window = quiet_window
        # key -> deque of the last `quiet_window` floors; _quiet
        # mirrors the current window minimum for inspection.
        self._quiet_hist = {}
        self._quiet = {}  # key -> window-minimum floor seen recently

    def detect(self, x, sample_rate, center_mhz, key=None):
        band = lte_band_for_center(center_mhz)
        if band is None:
            return None
        freqs, p = psd_dbfs(x)
        if p.size == 0 or not np.all(np.isfinite(p)):
            return None
        f_hz = freqs * float(sample_rate)
        half = USABLE_FRAC * float(sample_rate) / 2.0
        sel = np.abs(f_hz) <= half
        if int(sel.sum()) < 16:
            return None
        ps = p[sel].copy()
        fs = f_hz[sel]
        dc = np.abs(fs) <= 3.0 * float(sample_rate) / SEG_N
        if dc.any() and (~dc).any():
            ps[dc] = np.median(ps[~dc])
        noise = noise_floor_dbfs(ps)
        peak = float(np.max(ps))
        median = float(np.median(ps))
        fill = float(np.mean(ps > peak - LTE_FILL_DB))
        qkey = key if key is not None else round(float(center_mhz))
        # Bounded-window quiet reference (see the class docstring):
        # updated on EVERY capture; the reference is the minimum
        # over the last `quiet_window` floors, so a transient low
        # floor expires instead of permanently inflating snr_db.
        hist = self._quiet_hist.setdefault(
            qkey, deque(maxlen=self.quiet_window))
        hist.append(noise)
        quiet = min(hist)
        self._quiet[qkey] = quiet
        if fill < LTE_MIN_FILL_FRAC or peak - median > LTE_MEDIAN_GAP_DB:
            return None
        snr = peak - quiet
        if snr < LTE_MIN_SNR_DB:
            return None
        # Occupied bandwidth: central 99% of linear power in-span.
        lin = 10.0 ** (ps.astype(np.float64) / 10.0)
        order = np.argsort(fs)
        cum = np.cumsum(lin[order])
        total = cum[-1]
        if total <= 0:
            return None
        lo = fs[order][int(np.searchsorted(cum, 0.005 * total))]
        hi = fs[order][int(min(len(cum) - 1,
                               np.searchsorted(cum, 0.995 * total)))]
        flatness = float(np.std(ps))
        return {
            "dl_band": band[0],
            "is_lte450": bool(band[1]),
            "occupied_bw_mhz": round((hi - lo) / 1e6, 3),
            "flatness_db": round(flatness, 1),
            "snr_db": round(snr, 1),
            "fill_frac": round(fill, 3),
        }

    def event(self, radio, label, center_mhz, t, det):
        """UDP-ready lte_illuminator packet for a detection dict."""
        return {"v": 1, "kind": "lte_illuminator", "radio": radio,
                "band": label, "center_mhz": float(center_mhz),
                "dl_band": det["dl_band"],
                "occupied_bw_mhz": det["occupied_bw_mhz"],
                "flatness_db": det["flatness_db"],
                "snr_db": det["snr_db"],
                "t": float(t)}


class LteBenchLog:
    """Bench-measurement hook: the honest replacement for the
    CLAIMED FKIE LTE450 ~1.6 km figure.

    The operator runs known-range passes (or a known-range static
    reflector) with the bridge sweeping an LTE DL band, and the
    main loop records ONE ROW PER LTE-BAND SWEEP VISIT -- a
    detection (detected=1) AND a miss (detected=0, snr_db 0.0).
    Logging detections only would make every bin's fraction 1.0
    by construction and defeat the hook's purpose. The `range_m`
    column is left for the operator's ground truth (GPS / surveyed
    range) -- the bridge cannot know range, and inventing it would
    be exactly the overclaim this hook exists to prevent.
    summarize_lte_bench() then turns filled-in rows into a measured
    detection-fraction-vs-range curve. Until such a curve exists,
    there is NO Shepherd LTE detection-range number to quote.
    Rows are written with the csv module, so a comma or newline
    in a free-text field (e.g. range_m) is quoted, never a
    broken row.
    """

    HEADER = "t,radio,center_mhz,dl_band,snr_db,range_m,detected\n"

    def __init__(self, path):
        self.path = path
        try:
            with open(path, "r") as f:
                exists = bool(f.read(1))
        except OSError:
            exists = False
        if not exists:
            with open(path, "w", newline="") as f:
                f.write(self.HEADER)

    def record(self, t, radio, center_mhz, dl_band, snr_db,
               range_m="", detected=True):
        with open(self.path, "a", newline="") as f:
            csv.writer(f).writerow(
                [float(t), radio, float(center_mhz), dl_band,
                 float(snr_db), range_m, 1 if detected else 0])


def summarize_lte_bench(rows, bin_width_m=100.0):
    """Measured detection fraction per range bin from bench rows.

    rows: iterable of dicts with numeric `range_m` and boolean-ish
    `detected`. Returns a list of (bin_low_m, n, detection_fraction)
    sorted by range. Rows without a usable range are ignored -- a
    bench curve with no ground truth is no curve at all.
    bin_width_m must be finite and > 0 (anything else raises
    ValueError instead of a ZeroDivisionError or a nonsense bin).
    """
    try:
        bin_width_m = float(bin_width_m)
    except (TypeError, ValueError):
        raise ValueError("bin_width_m must be a finite number > 0")
    if not math.isfinite(bin_width_m) or bin_width_m <= 0:
        raise ValueError("bin_width_m must be a finite number > 0")
    bins = {}
    for r in rows:
        try:
            rng = float(r["range_m"])
            det = bool(int(r["detected"])) if not isinstance(
                r["detected"], bool) else r["detected"]
        except (KeyError, TypeError, ValueError):
            continue
        if not math.isfinite(rng) or rng < 0:
            continue
        key = math.floor(rng / bin_width_m) * bin_width_m
        n, d = bins.get(key, (0, 0))
        bins[key] = (n + 1, d + (1 if det else 0))
    return [(low, n, (d / n if n else 0.0))
            for low, (n, d) in sorted(bins.items())]


class Nr5gAdapter:
    """5G NR downlink signal-of-opportunity adapter -- v0.25.0 STUB.

    WHY A STUB, STATED PLAINLY: a real NR adapter must ingest an NR
    channel (20-100 MHz wide, n78/n77 up to 100 MHz) to recognise
    its structure. The bridge pipeline runs at 4 MSPS (2.4 MSPS
    RTL-SDR) with a 3.2 MHz usable span; even a USRP at the bridge's
    rate sees only a 3.2 MHz slice of a 20-100 MHz channel, and a
    flat slice of NR is indistinguishable from a flat slice of LTE
    or Wi-Fi at this DSP level. Claiming NR detection on that slice
    would be faking a capability. So:

    * probe(backend) gates on USRP-class hardware
      (backend.name "uhd" / "soapy-uhd") at >= 20 MSPS;
    * observe() ALWAYS returns [] -- no NR packet kind is emitted,
      in any configuration, in v0.25.0;
    * when the gate opens, status() says "stub" explicitly so a
      future wideband capture path knows exactly what to fill in:
      a >= 20 MSPS capture path + SSB/structure recognition, then
      the same doppler_ref feed as the LTE adapter.

    No BSense numbers are claimed: BSense (Meng et al.) ran on a
    carrier 5G-A base station (4.9 GHz, 100 MHz, 128 channels) that
    Shepherd does not control; its 1 km / F1 95.56% figures are
    that system's results, not Shepherd's, and appear nowhere as
    Shepherd capabilities.
    """

    MIN_SAMPLE_RATE_HZ = 20_000_000
    USRP_BACKEND_NAMES = ("uhd", "soapy-uhd")

    def probe(self, backend):
        """Gate check. Returns a dict; `active` is True only for
        USRP-class hardware at >= 20 MSPS, and even then `stub`
        stays True -- active means "the interface is armed", not
        "detection runs"."""
        name = getattr(backend, "name", "?")
        fs = float(getattr(backend, "sample_rate", 0) or 0)
        is_usrp = name in self.USRP_BACKEND_NAMES
        wide_enough = fs >= self.MIN_SAMPLE_RATE_HZ
        if is_usrp and wide_enough:
            reason = ("USRP-class + wideband capture present, but the "
                      "v0.25.0 adapter is a STUB: interface only, no NR "
                      "detection runs and no NR packets are emitted.")
        elif is_usrp:
            reason = (f"USRP-class but sample rate {fs / 1e6:g} MSPS < "
                      f"20 MSPS: the bridge pipeline cannot ingest an "
                      f"NR channel -- adapter inert.")
        else:
            reason = (f"backend '{name}' is not USRP-class -- 5G NR "
                      f"adapter inert; everything else unchanged.")
        return {"active": bool(is_usrp and wide_enough), "stub": True,
                "backend": name, "sample_rate_hz": fs, "reason": reason}

    def observe(self, *args, **kwargs):
        """Stub: never emits. Kept signature-compatible with the
        other detectors so the main loop can call it uniformly."""
        return []

    def status_line(self, backend):
        p = self.probe(backend)
        state = "ARMED-STUB" if p["active"] else "inert"
        return f"[bridge] 5g-nr: {state} ({p['reason']})"


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
    ap.add_argument("--no-elrs", action="store_true",
                    help="disable the ELRS chirp/Gemini signature detector "
                    "(runs by default on 2.4 GHz / 900 MHz captures)")
    ap.add_argument("--no-doppler", action="store_true",
                    help="disable the ambient-LTE Doppler tracker "
                    "(runs by default on --stare only, incl. 1.8-1.9 "
                    "GHz stares; a --bands list containing 1.8-1.9 GHz "
                    "is a sweep, not a Doppler stare)")
    ap.add_argument("--no-lte", action="store_true",
                    help="disable the LTE downlink illuminator detector "
                    "(runs by default on LTE DL bands; LTE450 still "
                    "needs --lte450 or an explicit --bands/--stare)")
    ap.add_argument("--lte450", action="store_true",
                    help="opt in to the LTE450 downlink band (~465 MHz): "
                    "only enable where the operator's radio covers it "
                    "and local rules allow passive reception there")
    ap.add_argument("--lte-bench-out", default="",
                    help="CSV path for the LTE bench-measurement hook: "
                    "one row per LTE-band sweep visit (detected 0/1); "
                    "fill in the range_m column from ground truth "
                    "afterwards (see LteBenchLog)")
    ap.add_argument("--no-wpp-ids", action="store_true",
                    help="disable the WPP-IDP per-preamble energy estimator "
                    "(runs by default on 2.4 GHz captures)")
    ap.add_argument("--wpp-waveform", default="ofdm",
                    choices=["dsss", "ofdm"],
                    help="illuminator waveform for the WPP-IDP chain: dsss "
                    "(beacons -- every packet usable) or ofdm "
                    "(preamble-only; data symbols are never processed)")
    ap.add_argument("--motion-state", default="static",
                    choices=["static", "moving"],
                    help="node motion state carried on wpp_idp_doppler "
                    "events (Shepherd must not merge moving-node lines "
                    "into track confidence)")
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
    # LTE450 gate: a plan or custom list that includes ~465 MHz
    # stays off without an explicit operator opt-in (--lte450, or
    # an explicit --bands/--stare listing of the band itself).
    _pre = len(bands)
    bands = [b for b in bands
             if not (lte_band_for_center(b[1])
                     and lte_band_for_center(b[1])[1]
                     and not (args.lte450 or args.bands or args.stare))]
    if len(bands) < _pre:
        print("[bridge] LTE450 band skipped: needs --lte450 or an "
              "explicit --bands/--stare listing (operator opt-in)")
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
    elrs = None if args.no_elrs else elrs_detect.ElrsDetector()
    doppler = None if args.no_doppler else doppler_detect.DopplerTracker()
    wpp = (None if args.no_wpp_ids
           else wpp_idp_detect.WppIdpEstimator(waveform=args.wpp_waveform,
                                               motion_state=args.motion_state))
    lte = None if args.no_lte else LteIlluminatorDetector()
    nr = Nr5gAdapter()
    print(nr.status_line(backend))
    # LTE450 gate: default sweeps never include it, but if a plan or
    # custom list ever does, it stays off without an explicit
    # operator opt-in (flag, or an explicit --bands/--stare listing).
    lte450_ok = bool(args.lte450 or args.bands or args.stare)
    if args.lte450:
        print("[bridge] lte450: operator opt-in -- passive RX only; "
              "check local rules for ~465 MHz reception")
    bench = LteBenchLog(args.lte_bench_out) if args.lte_bench_out else None
    print(f"[bridge] doppler={'off' if args.no_doppler else 'on '
          '(--stare only, incl. 1.8-1.9 GHz stares)'} "
          f"wpp_idp={'off' if args.no_wpp_ids
                         else args.wpp_waveform + ' ' + args.motion_state}")

    def finite_all(vals):
        return all(math.isfinite(v) for v in vals)

    try:
        while True:
            for label, center, bw in bands:
                backend.tune(center, bw, args.gain)
                _lte_band = lte_band_for_center(center)
                # Doppler routing is STARE-ONLY (unified rule, fixed
                # v0.25.0 review): the Doppler chain runs only when
                # the band list itself came from --stare. That means
                # (a) an explicit single-band --bands list is still a
                # sweep: it keeps band-energy packets and gets
                # lte_illuminator presence reports instead -- the
                # earlier len(bands)==1 version misrouted single-band
                # sweeps into the Doppler branch and silently
                # suppressed the illuminator reports; (b) combined
                # --bands + --stare: --bands wins band selection,
                # so the list is NOT stare-derived and stays a sweep;
                # (c) the old unconditional 1800-1900 MHz branch is
                # GONE as a sweep route: a --bands list containing
                # e.g. 1865 is now a sweep (band + lte_illuminator
                # packets), while --stare 1865 still runs Doppler.
                # LTE450 stares additionally need the opt-in gate.
                _stare_derived = bool(args.stare) and not args.bands
                _lte_stare = (
                    doppler is not None and _stare_derived
                    and _lte_band is not None
                    and (not _lte_band[1] or lte450_ok))
                if doppler is not None and _stare_derived and (
                        1800.0 <= center < 1900.0 or _lte_stare):
                    # Doppler stare: a DSP chain instead of the
                    # band-energy chain. Consecutive captures (no retune
                    # between them) are assembled into 0.5 s CPIs by the
                    # tracker; the band emits doppler_ref, not band
                    # packets.
                    n_cpi = max(1, math.ceil(doppler_detect.CPI_S
                                             * backend.sample_rate
                                             / CAPTURE_N))
                    for _ in range(n_cpi):
                        x = backend.capture(CAPTURE_N)
                        if x is None or len(x) < MIN_CAPTURE_N:
                            dropped += 1
                            continue
                        now = time.time()
                        try:
                            for p in doppler.observe(
                                    radio, center, now, x,
                                    backend.sample_rate):
                                emit(p)
                        except Exception as ex:  # DSP never kills the loop
                            if now - last_warn > 60.0:
                                last_warn = now
                                print(f"[bridge] doppler detector error: {ex}")
                    continue
                ms = []
                x_last = None
                for _ in range(max(1, args.dwell)):
                    x = backend.capture(CAPTURE_N)
                    if x is None or len(x) < MIN_CAPTURE_N:
                        continue  # failed/short read: never report as data
                    m = band_measurement(x, backend.sample_rate, bw)
                    if m is not None:
                        ms.append(m)
                        x_last = x
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
                # LTE downlink illuminator presence (RX-only spectrum
                # shape; sweep mode -- stares run the doppler_ref
                # chain instead and `continue` above). LTE450 needs
                # the opt-in gate; other DL bands run by default
                # unless --no-lte. Silent when nothing is present.
                if (lte is not None and x_last is not None
                        and _lte_band is not None
                        and (not _lte_band[1] or lte450_ok)):
                    try:
                        det = lte.detect(x_last, backend.sample_rate,
                                         center)
                    except Exception as ex:  # DSP never kills the sweep
                        det = None
                        if now - last_warn > 60.0:
                            last_warn = now
                            print(f"[bridge] lte detector error: {ex}")
                    if det is not None:
                        emit(lte.event(radio, label, center, now, det))
                    # Bench hook: one row per LTE-band sweep visit,
                    # detection AND miss -- detections-only logging
                    # would force every bin's fraction to 1.0.
                    if bench is not None:
                        bench.record(now, radio, center,
                                     _lte_band[0],
                                     det["snr_db"] if det is not None
                                     else 0.0,
                                     detected=det is not None)
                # ELRS chirp / Gemini-signature detection (RX-only DSP;
                # corroboration, never an identification). Runs on the
                # 2.4 GHz and 900 MHz families only; the detector gates
                # itself on narrowband activity.
                if elrs is not None and x_last is not None:
                    meas = {"peak_dbfs": top["peak_dbfs"], "noise": noise}
                    try:
                        chirps, sigs = elrs.observe(
                            radio, label, center, now, x_last,
                            backend.sample_rate, meas)
                    except Exception as ex:  # DSP must never kill the sweep
                        chirps, sigs = [], []
                        if now - last_warn > 60.0:
                            last_warn = now
                            print(f"[bridge] elrs detector error: {ex}")
                    for p in chirps + sigs:
                        emit(p)
                # WPP-IDP per-preamble energy estimator (RX-only DSP;
                # detection corroboration, never an identification).
                # Runs on 2.4 GHz captures; designed for --stare on the
                # illuminator band (the estimator resets on wall-clock
                # gaps, so sweep visits accumulate nothing).
                if (wpp is not None and x_last is not None
                        and 2400.0 <= center < 2500.0):
                    try:
                        for p in wpp.observe(
                                radio, label, center, now, x_last,
                                backend.sample_rate,
                                motion_state=args.motion_state):
                            emit(p)
                    except Exception as ex:  # DSP must never kill the sweep
                        if now - last_warn > 60.0:
                            last_warn = now
                            print(f"[bridge] wpp-idp detector error: {ex}")
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
