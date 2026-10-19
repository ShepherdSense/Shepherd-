#!/usr/bin/env python3
"""
cot_listener.py — Cursor-on-Target (CoT) probe for Shepherd / AN/PRC-163.

Listens on UDP 239.2.3.1:6969 (the standard CoT multicast group) for CoT
XML events such as the ones emitted by ATAK / WinTAK / TAK servers, parses
each event's uid, type, lat/lon and callsign, and logs them to JSONL.

Honest scope:
  * This is a LISTENER. It proves whether position data is flowing on your LAN.
  * If the PRC-163 is not configured to export situational-awareness (SA)
    traffic toward your PC's LAN (via ATAK plugin, TAK server relay, or a
    radio-side SA bridge), this script will correctly report NOTHING — that
    silence is a radio/config fact, not a bug in this script.
  * CoT carries positions only. It is NOT a substitute for per-link SNR/RSSI
    telemetry (what the Shepherd tripwire actually needs). Positions let
    Shepherd place the 163 on the tracking map; they do not feed the
    disturbance detector.

Usage:
    python cot_listener.py                 # listen on 239.2.3.1:6969
    python cot_listener.py --port 4242      # listen unicast on port 4242
    python cot_listener.py --out cot_log.jsonl --verbose

No third-party dependencies. Tested with synthetic CoT datagrams over
loopback (see self_test()).
"""

import argparse
import json
import socket
import struct
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

DEFAULT_GROUP = "239.2.3.1"
DEFAULT_PORT = 6969


def parse_cot(payload: bytes):
    """Parse one CoT XML datagram. Returns dict or None if unparseable."""
    try:
        text = payload.decode("utf-8", errors="replace").strip()
    except Exception:
        return None
    if not text.startswith("<"):
        return None
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return None
    if root.tag != "event":
        return None
    out = {
        "uid": root.get("uid"),
        "type": root.get("type"),
        "how": root.get("how"),
        "time": root.get("time"),
        "stale": root.get("stale"),
        "lat": None,
        "lon": None,
        "hae": None,
        "callsign": None,
    }
    point = root.find("point")
    if point is not None:
        try:
            out["lat"] = float(point.get("lat"))
            out["lon"] = float(point.get("lon"))
        except (TypeError, ValueError):
            pass
        out["hae"] = point.get("hae")
    detail = root.find("detail")
    if detail is not None:
        contact = detail.find("contact")
        if contact is not None:
            out["callsign"] = contact.get("callsign")
    return out


def make_socket(port: int, group: str | None):
    """Create the UDP listener socket (multicast group or plain unicast)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass  # not all Windows builds allow it; REUSEADDR is enough
    sock.bind(("", port))
    if group:
        # Join the multicast group on the default interface.
        mreq = struct.pack("4s4s", socket.inet_aton(group), socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    return sock


def listen(port: int, group: str | None, out_path: str, verbose: bool):
    where = f"multicast {group}:{port}" if group else f"UDP *:{port}"
    print(f"[*] Listening for CoT on {where} — Ctrl+C to stop", flush=True)
    print("[*] If the 163 isn't exporting SA to your LAN, expect silence (that's a config fact, not a bug).", flush=True)
    sock = make_socket(port, group)
    n = 0
    start = time.time()
    try:
        with open(out_path, "a", encoding="utf-8") as fh:
            while True:
                data, addr = sock.recvfrom(65535)
                evt = parse_cot(data)
                n += 1
                if evt is None:
                    if verbose:
                        print(f"[!] non-CoT datagram from {addr[0]}:{addr[1]} ({len(data)} bytes)", flush=True)
                    continue
                evt["received_at"] = datetime.now(timezone.utc).isoformat()
                evt["from"] = f"{addr[0]}:{addr[1]}"
                fh.write(json.dumps(evt) + "\n")
                fh.flush()
                label = evt.get("callsign") or evt.get("uid")
                pos = f"{evt['lat']:.6f},{evt['lon']:.6f}" if evt["lat"] is not None else "no-fix"
                print(f"[+] {label} ({evt['type']}) @ {pos}  from {addr[0]}", flush=True)
    except KeyboardInterrupt:
        elapsed = time.time() - start
        print(f"\n[*] Stopped. {n} datagram(s) in {elapsed:.0f}s -> {out_path}", flush=True)


SYNTHETIC_EVENTS = [
    b'<event version="2.0" uid="PRC163-TEST" type="a-f-G-U-C-I" how="m-g" '
    b'time="2026-10-05T21:00:00.000Z" start="2026-10-05T21:00:00.000Z" stale="2026-10-05T21:10:00.000Z">'
    b'<point lat="35.139000" lon="-79.006000" hae="45.0" ce="10.0" le="10.0"/>'
    b'<detail><contact callsign="EAGLE-1" endpoint="*:-1:stcp"/></detail></event>',
    b'<event version="2.0" uid="NO-FIX" type="a-f-G-U-C-I" how="m-g" '
    b'time="2026-10-05T21:00:01.000Z" start="2026-10-05T21:00:01.000Z" stale="2026-10-05T21:10:01.000Z">'
    b'<point lat="9999999.0" lon="9999999.0" hae="9999999.0" ce="9999999.0" le="9999999.0"/>'
    b'<detail/></event>',
    b'not xml at all',
    b'<event version="2.0" uid="NOPOINT" type="a-f-G" how="m-g"/>',
]


def self_test():
    """Unit-check the parser, then an end-to-end loopback UDP round-trip."""
    failures = 0

    # 1) parser unit checks
    e = parse_cot(SYNTHETIC_EVENTS[0])
    if not (e and e["callsign"] == "EAGLE-1" and abs(e["lat"] - 35.139) < 1e-9 and abs(e["lon"] + 79.006) < 1e-9):
        print("FAIL: normal event parse"); failures += 1
    e = parse_cot(SYNTHETIC_EVENTS[1])
    if not (e and e["lat"] == 9999999.0 and e["callsign"] is None):
        print("FAIL: no-fix event parse"); failures += 1
    if parse_cot(SYNTHETIC_EVENTS[2]) is not None:
        print("FAIL: garbage should not parse"); failures += 1
    e = parse_cot(SYNTHETIC_EVENTS[3])
    if not (e and e["lat"] is None and e["uid"] == "NOPOINT"):
        print("FAIL: missing point parse"); failures += 1

    # 2) loopback round-trip: sender thread -> listener socket.
    #    Skipped gracefully where the sandbox blocks UDP (e.g. CI runners);
    #    the parser checks above are the hard gate.
    import threading
    port = 50961
    got = []
    try:
        srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        srv.bind(("127.0.0.1", port))
        srv.settimeout(5.0)
        srv.sendto(b"ping", ("127.0.0.1", port))
        srv.recvfrom(64)
    except OSError as e:
        srv.close()
        print(f"SELF-TEST: loopback UDP unavailable in this environment ({e}); "
              "parser checks passed, socket path unverified here")
        if failures:
            print(f"SELF-TEST: {failures} parser failure(s)")
            return 1
        print("SELF-TEST: 4/4 parser checks passed")
        return 0

    def sender():
        time.sleep(0.3)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for dat in SYNTHETIC_EVENTS:
            s.sendto(dat, ("127.0.0.1", port))
            time.sleep(0.05)
        s.close()

    t = threading.Thread(target=sender, daemon=True)
    t.start()
    deadline = time.time() + 5.0
    while len(got) < len(SYNTHETIC_EVENTS) and time.time() < deadline:
        try:
            data, _ = srv.recvfrom(65535)
        except socket.timeout:
            break
        got.append(parse_cot(data))
    srv.close()
    t.join(timeout=2)
    ok_parsed = [g for g in got if g is not None]
    if len(ok_parsed) != 3:
        print(f"FAIL: loopback parsed {len(ok_parsed)}/3 CoT events"); failures += 1
    uids = {g["uid"] for g in ok_parsed}
    if uids != {"PRC163-TEST", "NO-FIX", "NOPOINT"}:
        print(f"FAIL: loopback uids {uids}"); failures += 1

    if failures:
        print(f"SELF-TEST: {failures} failure(s)")
        return 1
    print("SELF-TEST: all parser + loopback checks passed (4 parser, 2 loopback)")
    return 0


def main():
    ap = argparse.ArgumentParser(description="CoT multicast listener / PRC-163 SA probe")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--group", default=DEFAULT_GROUP,
                    help="multicast group (empty string = plain unicast listen)")
    ap.add_argument("--out", default="cot_log.jsonl")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--self-test", action="store_true", help="run parser + loopback tests and exit")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test())
    group = args.group.strip() or None
    listen(args.port, group, args.out, args.verbose)


if __name__ == "__main__":
    main()
