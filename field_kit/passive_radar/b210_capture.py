#!/usr/bin/env python3
"""
Shepherd passive-radar capture -- RECEIVE ONLY. This script never transmits.

Grabs phase-coherent reference + surveillance channels from a USRP B210 and
saves them for offline processing by passive_radar.py (--ref/--surv).

Setup: two antennas.
  CH0 (reference)    -> pointed AT the broadcast illuminator (FM/DVB-T tower)
  CH1 (surveillance) -> pointed at the sky / area under watch

The B210's two RX channels share one local oscillator, so they are phase
coherent -- the requirement passive coherent location actually needs. A
single Pluto or RTL-SDR cannot do this.

NEEDS HARDWARE: a USRP B210 (or B200 with... no -- dual RX needs the B210),
the UHD driver, and the `uhd` Python package. Without them this script
explains what's missing and exits.
"""

import argparse
import json
import sys
import time

try:
    import uhd
    import numpy as np
except ImportError as e:
    sys.exit(
        "b210_capture needs hardware support that isn't installed here.\n"
        f"  ({e})\n"
        "To use it you need, on the capture machine:\n"
        "  1. a USRP B210 plugged in over USB 3\n"
        "  2. the UHD driver (Windows: Ettus installer; Linux: apt install uhd-host)\n"
        "  3. pip install uhd numpy\n"
        "Then run:  python b210_capture.py --freq 600e6 --duration 10\n"
        "For a hardware-free test of the processing chain, run instead:\n"
        "  python passive_radar.py --demo"
    )


def main():
    ap = argparse.ArgumentParser(description="B210 dual-RX passive-radar "
                                 "capture (RX only)")
    ap.add_argument("--freq", type=float, default=600e6,
                    help="illuminator centre frequency, Hz (e.g. 600e6 for "
                         "DVB-T, 98e6 for FM)")
    ap.add_argument("--rate", type=float, default=2e6,
                    help="sample rate, Hz (default 2000000)")
    ap.add_argument("--gain", type=float, default=40.0,
                    help="RX gain dB, both channels (default 40)")
    ap.add_argument("--duration", type=float, default=10.0,
                    help="capture length, seconds (default 10)")
    ap.add_argument("--args", default="",
                    help='UHD device args, e.g. "type=b200"')
    ap.add_argument("--out", default="capture",
                    help="output file prefix (writes <prefix>.npy + .json)")
    args = ap.parse_args()

    print("[capture] RECEIVE ONLY -- no TX stream is ever opened by "
          "this script.")
    usrp = uhd.usrp.MultiUSRP(args.args or "")
    if usrp.get_rx_num_channels() < 2:
        sys.exit("[capture] this USRP exposes fewer than 2 RX channels; "
                 "passive radar needs dual coherent RX (B210).")

    usrp.set_rx_rate(args.rate, 0)
    usrp.set_rx_rate(args.rate, 1)
    # One shared LO: both channels tune together -> phase coherent.
    usrp.set_rx_freq(uhd.types.TuneRequest(args.freq), 0)
    usrp.set_rx_freq(uhd.types.TuneRequest(args.freq), 1)
    usrp.set_rx_gain(args.gain, 0)
    usrp.set_rx_gain(args.gain, 1)
    for ch in (0, 1):
        try:
            usrp.set_rx_antenna("RX2", ch)
        except Exception:
            pass  # not all daughterboards name it; default is fine

    n_samps = int(args.rate * args.duration)
    st_args = uhd.usrp.StreamArgs("fc32", "sc16")
    st_args.channels = [0, 1]
    # NOTE: get_rx_stream only. get_tx_stream is never called anywhere.
    streamer = usrp.get_rx_stream(st_args)
    buf = np.zeros((2, n_samps), dtype=np.complex64)
    md = uhd.types.RXMetadata()

    print(f"[capture] {args.duration:.0f}s @ {args.rate/1e6:.1f} MSPS, "
          f"{args.freq/1e6:.1f} MHz, gain {args.gain} dB ...")
    streamer.issue_stream_cmd(
        uhd.types.StreamCMD(uhd.types.StreamMode.start_cont))
    got = 0
    t_end = time.time() + args.duration + 5.0
    while got < n_samps and time.time() < t_end:
        n = streamer.recv(buf[:, got:], md, 2.0)
        if n <= 0:
            break
        got += n
    streamer.issue_stream_cmd(
        uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont))
    buf = buf[:, :got]
    print(f"[capture] got {got} samples/channel "
          f"({got/args.rate:.2f}s)")

    np.save(args.out + ".npy", buf)
    # Split single-channel files too, so passive_radar.py can take them
    # directly with --ref/--surv and nobody hand-slices arrays.
    np.save(args.out + "_ref.npy", np.ascontiguousarray(buf[0]))
    np.save(args.out + "_surv.npy", np.ascontiguousarray(buf[1]))
    with open(args.out + ".json", "w") as f:
        json.dump({
            "freq_hz": args.freq,
            "rate_hz": args.rate,
            "gain_db": args.gain,
            "channels": ["reference", "surveillance"],
            "samples_per_channel": got,
            "t": time.time(),
        }, f, indent=1)
    print(f"[capture] wrote {args.out}.npy (+ _ref/_surv splits) and "
          f"{args.out}.json")
    print("[capture] process offline with:")
    print(f"  python passive_radar.py --ref {args.out}_ref.npy "
          f"--surv {args.out}_surv.npy --fs {args.rate:g} "
          f"--fc {args.freq:g}")


if __name__ == "__main__":
    main()
