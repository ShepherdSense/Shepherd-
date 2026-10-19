#!/usr/bin/env python3
"""
beast_cot_capture.py -- capture what a CACI BEAST+ (or any TAK talker) emits.

Listens on UDP 239.2.3.1:6969 (the standard CoT / TAK multicast group) on
ALL local network interfaces and logs every datagram -- timestamp, source,
raw bytes, and parsed CoT fields when parseable -- to a timestamped JSONL
file in the current folder.

Why this exists: the BEAST+ integrates with ATAK via CACI's Reaper plug-in.
If it emits standard Cursor-on-Target onto the LAN, this capture reveals
the EXACT message schema Shepherd's ingest driver must parse -- measured
empirically, no CACI docs required.

If NOTHING appears after several minutes with the BEAST+ powered and
active: that is a real finding, not a script bug. It means the BEAST+ is
not putting CoT on your LAN (e.g. it talks to the Android EUD over USB or
Bluetooth, or its TAK/Reaper link isn't configured yet). Note how the
BEAST+ is connected and we take the next step (Ice Bucket export / CACI
interface docs).

No third-party dependencies. Windows / Linux / macOS.
"""

import argparse
import json
import socket
import struct
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

GROUP = "239.2.3.1"
PORT = 6969


def utcnow():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def local_ips():
    ips = set()
    try:
        _, _, iplist = socket.gethostbyname_ex(socket.gethostname())
        ips.update(iplist)
    except Exception:
        pass
    try:  # default-route interface (no traffic actually sent)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


def parse_cot(payload: bytes):
    """Parse one CoT XML datagram -> dict, or None if not CoT."""
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
    }
    pt = root.find("point")
    if pt is not None:
        out["lat"] = pt.get("lat")
        out["lon"] = pt.get("lon")
        out["hae"] = pt.get("hae")
        out["ce"] = pt.get("ce")
        out["le"] = pt.get("le")
    detail = root.find("detail")
    if detail is not None:
        contact = detail.find("contact")
        if contact is not None:
            out["callsign"] = contact.get("callsign")
        # keep any <__beast> / <sensor> style extensions verbatim
        for child in detail:
            if child.tag not in ("contact", "link", "status"):
                out["detail_" + child.tag] = (
                    child.text.strip() if child.text else ""
                )[:200]
    return out


def open_socket():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", PORT))
    except OSError as e:
        print(f"ERROR: cannot bind UDP {PORT}: {e}")
        print("Is another copy already running, or is the port blocked?")
        sys.exit(2)
    joined = 0
    for ip in local_ips() or ["0.0.0.0"]:
        try:
            mreq = struct.pack(
                "4s4s", socket.inet_aton(GROUP), socket.inet_aton(ip))
            sock.setsockopt(
                socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            joined += 1
        except OSError:
            pass
    if joined == 0:  # last resort: any interface
        mreq = struct.pack(
            "4s4s", socket.inet_aton(GROUP), socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)
    return sock


def self_test():
    full = (b'<event version="2.0" uid="BEAST-001" type="a-f-G-U-C-I" '
            b'how="m-g" time="2026-10-06T12:00:00Z">'
            b'<point lat="35.05" lon="-78.88" hae="10" ce="5" le="5"/>'
            b'<detail><contact callsign="BEAST1"/></detail></event>')
    p = parse_cot(full)
    assert p and p["uid"] == "BEAST-001", "full event"
    assert p["lat"] == "35.05" and p["callsign"] == "BEAST1", "fields"
    minimal = b'<event uid="X"><point lat="1" lon="2"/></event>'
    p2 = parse_cot(minimal)
    assert p2 and p2["uid"] == "X", "minimal event"
    assert parse_cot(b"not xml at all") is None, "garbage rejected"
    assert parse_cot(b"<foo/>") is None, "non-event rejected"
    print("self-test: 4/4 parser checks passed")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Capture BEAST+/TAK CoT traffic")
    ap.add_argument("--minutes", type=float, default=0,
                    help="auto-stop after N minutes (0 = run until Ctrl+C)")
    ap.add_argument("--out", default=None, help="output JSONL path")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    out_path = args.out or ("beast_capture_%s.jsonl"
                            % datetime.now().strftime("%Y%m%d_%H%M%S"))
    sock = open_socket()
    print(f"Listening on {GROUP}:{PORT} (all interfaces).")
    print("Power the BEAST+, put it on this LAN, let it run DF/surveillance.")
    if args.minutes > 0:
        print(f"Auto-stop in {args.minutes} minute(s). Ctrl+C stops early.")
    else:
        print("Ctrl+C to stop.")
    print(f"Logging to {out_path}\n")

    deadline = time.time() + args.minutes * 60 if args.minutes > 0 else None
    n_cot = n_other = 0
    with open(out_path, "a", encoding="utf-8") as f:
        try:
            while True:
                if deadline and time.time() >= deadline:
                    break
                try:
                    data, addr = sock.recvfrom(65535)
                except socket.timeout:
                    continue
                parsed = parse_cot(data)
                rec = {"ts": utcnow(),
                       "src": f"{addr[0]}:{addr[1]}",
                       "len": len(data)}
                if parsed:
                    n_cot += 1
                    rec["kind"] = "cot"
                    rec["parsed"] = parsed
                    uid = parsed.get("uid") or "?"
                    cs = parsed.get("callsign") or ""
                    print(f"[CoT] {uid} {cs} "
                          f"{parsed.get('lat')},{parsed.get('lon')} "
                          f"type={parsed.get('type')}")
                else:
                    n_other += 1
                    rec["kind"] = "other"
                    try:
                        rec["raw_text"] = data.decode(
                            "utf-8", errors="replace")[:2000]
                    except Exception:
                        rec["raw_hex"] = data[:512].hex()
                    print(f"[other] {addr[0]}:{addr[1]} {len(data)} bytes "
                          f"(non-CoT)")
                f.write(json.dumps(rec) + "\n")
                f.flush()
        except KeyboardInterrupt:
            pass
    print(f"\nDone: {n_cot} CoT events, {n_other} other datagrams -> {out_path}")
    if n_cot == 0 and n_other == 0:
        print("Silence. The BEAST+ is not emitting CoT onto this LAN right "
              "now -- see README.txt for what that means.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
