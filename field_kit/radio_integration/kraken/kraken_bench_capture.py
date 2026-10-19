#!/usr/bin/env python3
"""
kraken_bench_capture.py -- bench-test capture for a KrakenSDR on the LAN.

Polls http://<pi-ip>:8081/DOA_value.html once per second and logs every
NEW bearing line -- wall-clock time plus the raw DSP fields -- to a
timestamped JSONL file in the current folder. The file is what locks the
bearing convention (360-theta vs theta, true vs magnetic) in the Shepherd
Kraken driver before it is merged.

Classic krakensdr_doa image path (Pi, incl. v1.8.1). Line format per the
driver spec, parsed POSITIONALLY from the last non-empty line:

    timestamp, bearing, confidence, power, frequency

States, all logged, none fatal:
  - empty file      -> squelch closed (no signal). Valid state, no alert.
  - same DSP ts     -> stale, DSP has not updated. Emit nothing.
  - malformed line  -> skipped and counted.

For the newer krakensdr_suite (Heimdall v2, C++ rewrite) generation the
live stream is a WebSocket on port 8021, not this file -- this script
detects that generation (heimdall web UI on :8070) and still records
whatever :8081/DOA_value.html serves, which V2 keeps. Note: on V2 the
:8021 broadcast is OPT-IN -- enable it in the Kraken web UI's Web Mapper
panel -> Local Network WS broadcast. A closed 8021 on V2 therefore means
"toggle not enabled", not "something is broken".

No third-party dependencies. Windows / Linux / macOS.
"""

import argparse
import json
import socket
import sys
import time
import urllib.request
from datetime import datetime, timezone

POLL_SECS = 1.0
HTTP_TIMEOUT = 4.0


def utcnow():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def parse_doa_line(line):
    """Parse one DOA_value.html line positionally.

    Expected: timestamp, bearing, confidence, power, frequency
    Returns dict or None (empty / malformed).
    """
    line = (line or "").strip()
    if not line:
        return None  # squelch closed / empty file
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 5:
        return None  # malformed
    try:
        return {
            "dsp_ts": parts[0],
            "bearing_deg": float(parts[1]),
            "confidence": float(parts[2]),
            "power_db": float(parts[3]),
            "frequency_hz": float(parts[4]),
        }
    except ValueError:
        return None  # malformed


def fetch_doa_page(ip):
    """Return the raw text of DOA_value.html, or an error tag string."""
    url = "http://%s:8081/DOA_value.html" % ip
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as r:
            return r.read().decode("utf-8", errors="replace")
    except Exception as e:
        return "ERROR:" + type(e).__name__


def port_open(ip, port, timeout=2.0):
    try:
        s = socket.create_connection((ip, port), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False


def self_test():
    """4 fixtures: normal line, empty file, stale timestamp, malformed."""
    ok = 0
    total = 4

    # 1. normal line parses positionally
    p = parse_doa_line("2026-10-06 12:00:01, 123.4, 0.87, -42.1, 2440000000")
    if p and p["bearing_deg"] == 123.4 and p["frequency_hz"] == 2440000000.0:
        print("[PASS] normal line parses positionally")
        ok += 1
    else:
        print("[FAIL] normal line:", p)

    # 2. empty file = squelch closed, not an error
    if parse_doa_line("   \n") is None:
        print("[PASS] empty file -> squelch closed (no emit)")
        ok += 1
    else:
        print("[FAIL] empty file should parse to None")

    # 3. stale timestamp detection: same dsp_ts twice -> no new observation
    seen = set()
    a = parse_doa_line("2026-10-06 12:00:01, 123.4, 0.87, -42.1, 2440000000")
    b = parse_doa_line("2026-10-06 12:00:01, 123.4, 0.87, -42.1, 2440000000")
    fresh_a = a["dsp_ts"] not in seen
    seen.add(a["dsp_ts"])
    fresh_b = b["dsp_ts"] not in seen
    if fresh_a and not fresh_b:
        print("[PASS] stale timestamp detected (no double emit)")
        ok += 1
    else:
        print("[FAIL] stale logic broken")

    # 4. malformed line skipped
    if parse_doa_line("garbage, not, csv") is None and \
            parse_doa_line("12:00:01, abc, 0.5, -40, 2.4e9") is None:
        print("[PASS] malformed lines skipped")
        ok += 1
    else:
        print("[FAIL] malformed line handling broken")

    print("self-test: %d/%d passed" % (ok, total))
    return 0 if ok == total else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", required=False,
                    help="Kraken Pi IP address on your LAN")
    ap.add_argument("--minutes", type=float, default=5,
                    help="how long to poll (default 5)")
    ap.add_argument("--station", default="bench",
                    help="station id tag for the JSONL")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    ip = args.ip or input("Kraken Pi IP address: ").strip()
    if not ip:
        print("No IP given -- quitting.")
        return 1

    print("Probing %s ..." % ip)
    gen_8081 = port_open(ip, 8081)
    gen_8021 = port_open(ip, 8021)
    gen_8070 = port_open(ip, 8070)  # heimdall v2 web UI -- V2 suite only
    if gen_8070:
        print("V2 suite detected (heimdall on :8070).")
        print("  - Web UI is at https://%s:8080 (client) / http://%s:8070 (heimdall)" % (ip, ip))
        print("  - The :8021 doapost broadcast is OPT-IN on V2: enable it in the")
        print("    web UI's Web Mapper panel -> Local Network WS broadcast.")
        if not gen_8021:
            print("  - :8021 is closed: expected until that toggle is enabled,")
            print("    not a failure. This capture uses :8081 anyway.")
        print("  - :8081/DOA_value.html is still served on V2 -- polling it now.")
    elif gen_8021 and not gen_8081:
        print("NOTE: port 8021 open, 8081 closed -- the live stream here is a")
        print("WebSocket on 8021, not the :8081 CSV file.")
        print("Recording whatever :8081 serves anyway; if it stays empty,")
        print("watch bearings in the Kraken web UI directly.")
    elif not gen_8081 and not gen_8021:
        print("WARNING: neither 8081 nor 8021 answered on %s." % ip)
        print("Check the IP and that the Kraken software is running.")
    else:
        print("Classic image path reachable (:8081 open).")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    out_path = "kraken_bench_%s.jsonl" % stamp
    deadline = time.time() + args.minutes * 60
    last_ts = None
    counts = {"emitted": 0, "stale": 0, "squelch_closed": 0,
              "malformed": 0, "http_error": 0}

    print("Polling http://%s:8081/DOA_value.html every %.0fs for %.1f min."
          % (ip, POLL_SECS, args.minutes))
    print("Writing %s  (Ctrl+C stops early)" % out_path)

    with open(out_path, "w", encoding="utf-8") as f:
        while time.time() < deadline:
            body = fetch_doa_page(ip)
            if body.startswith("ERROR:"):
                counts["http_error"] += 1
                print("[http-error] %s" % body[6:])
            else:
                lines = [ln for ln in body.splitlines() if ln.strip()]
                if not lines:
                    counts["squelch_closed"] += 1
                    print("[squelch closed] empty file -- no signal right now")
                else:
                    obs = parse_doa_line(lines[-1])
                    if obs is None:
                        counts["malformed"] += 1
                        print("[malformed] skipped: %s" % lines[-1][:80])
                    elif obs["dsp_ts"] == last_ts:
                        counts["stale"] += 1
                    else:
                        last_ts = obs["dsp_ts"]
                        obs["wall_ts"] = utcnow()
                        obs["station"] = args.station
                        obs["raw_line"] = lines[-1].strip()
                        f.write(json.dumps(obs) + "\n")
                        f.flush()
                        counts["emitted"] += 1
                        print("[bearing] %s deg  conf %.2f  pwr %.1f dB  %s Hz"
                              % (obs["bearing_deg"], obs["confidence"],
                                 obs["power_db"], obs["frequency_hz"]))
            time.sleep(POLL_SECS)

    print("\nDone. %s" % out_path)
    print("emitted=%d stale=%d squelch_closed=%d malformed=%d http_error=%d"
          % (counts["emitted"], counts["squelch_closed"], counts["stale"],
             counts["malformed"], counts["http_error"]))
    print("Send the newest kraken_bench_*.jsonl back with the KNOWN bearing")
    print("of your test emitter -- that is what locks the convention.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
