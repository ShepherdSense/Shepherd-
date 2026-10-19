#!/usr/bin/env python3
"""
mrsi_probe.py -- talk to a CACI Mastodon-family sensor (BEAST+) over its
MRSI JSON API and capture what it emits.

MRSI (Mastodon Remote Sensor Interface) v10.5.0, per CACI's API summary:
  - TCP 10051          : JSON command/control. {"type":"connect_req"} -> client handle
  - UDP (client-chosen): data streams (lob = line-of-bearing, hits, ...) as JSON
  - 239.2.3.27:10050   : multicast hello / discovery beacons

This probe is SUBSCRIBE-ONLY. It never sends EA (jamming) commands and never
reconfigures the sensor: no ea_*, rf_*, soi_*, scan_* or mission commands.
It connects, asks what streams exist, subscribes to receive-only data
streams, and logs every byte (timestamps + raw) to a JSONL file so the
Shepherd ingest driver can be specified from measured traffic, not guesses.

No third-party dependencies. Windows / Linux / macOS.
"""

import argparse
import json
import re
import socket
import struct
import sys
import threading
import time
from datetime import datetime, timezone

MCAST_GROUP = "239.2.3.27"
MCAST_PORT = 10050
TCP_PORT = 10051
DISCOVERY_SECS = 15
MAX_LINE = 1024 * 1024  # 1 MB cap on one TCP line before we log it raw

IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")


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


def extract_ips(text):
    return [ip for ip in dict.fromkeys(IP_RE.findall(text or ""))
            if not ip.startswith("127.")]


class JsonLines:
    """Newline-delimited JSON over a TCP socket, tolerant of objects
    split across recv() chunks. Unparseable lines are returned raw."""

    def __init__(self, sock):
        self.sock = sock
        self.carry = ""

    def send(self, obj):
        line = json.dumps(obj) + "\n"
        self.sock.sendall(line.encode("utf-8"))
        return line.strip()

    def drain(self):
        """Return list of ("json", obj) / ("raw", text) for lines
        currently available. Never blocks more than ~50 ms."""
        out = []
        self.sock.settimeout(0.05)
        while True:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                break
            except OSError:
                break
            if not chunk:
                break
            self.carry += chunk.decode("utf-8", errors="replace")
            if len(self.carry) > MAX_LINE:
                out.append(("raw", self.carry[:2000]))
                self.carry = ""
            while "\n" in self.carry:
                line, self.carry = self.carry.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(("json", json.loads(line)))
                except json.JSONDecodeError:
                    out.append(("raw", line[:2000]))
        return out


def listen_hello(secs):
    """Listen for MRSI multicast hellos. Returns [(src, text)]."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM,
                         socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", MCAST_PORT))
    except OSError as e:
        print(f"NOTE: cannot bind UDP {MCAST_PORT} ({e}); skipping discovery")
        return []
    for ip in local_ips() or ["0.0.0.0"]:
        try:
            mreq = struct.pack("4s4s", socket.inet_aton(MCAST_GROUP),
                               socket.inet_aton(ip))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                            mreq)
        except OSError:
            pass
    sock.settimeout(1.0)
    found = []
    end = time.time() + secs
    while time.time() < end:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        src = f"{addr[0]}:{addr[1]}"
        try:
            text = data.decode("utf-8", errors="replace").strip()
        except Exception:
            text = ""
        found.append((src, text[:2000] if text else f"<{len(data)} binary bytes>"))
        print(f"[hello] {src}: {(text[:100] if text else '<binary>')}")
    sock.close()
    return found


def record_datagram(data, addr):
    """Parse one UDP datagram into a log record (no I/O)."""
    rec = {"dir": "udp-in", "src": f"{addr[0]}:{addr[1]}",
           "len": len(data)}
    try:
        txt = data.decode("utf-8")
        try:
            rec["json"] = json.loads(txt)
        except json.JSONDecodeError:
            rec["text"] = txt[:2000]
    except Exception:
        rec["hex"] = data[:256].hex()
    return rec


def probe(host, minutes, out_path, tcp_port=TCP_PORT, skip_discovery=False):
    n_udp = n_tcp = 0
    with open(out_path, "a", encoding="utf-8") as f:
        def log(rec):
            rec["ts"] = utcnow()
            f.write(json.dumps(rec) + "\n")
            f.flush()

        # ---- 1. discovery ----
        if not skip_discovery and not host:
            print(f"Listening for MRSI hellos on {MCAST_GROUP}:{MCAST_PORT} "
                  f"({DISCOVERY_SECS}s)...")
            hellos = listen_hello(DISCOVERY_SECS)
            cands = []
            for src, text in hellos:
                log({"dir": "mcast-in", "src": src, "hello": text,
                     "ips": extract_ips(text)})
                cands += extract_ips(text)
                cands.append(src.split(":")[0])
            cands = [c for c in dict.fromkeys(cands)
                     if not c.startswith("127.")]
            if cands:
                host = cands[0]
                print(f"Using unit IP from discovery: {host}")
                if len(cands) > 1:
                    print(f"(also saw: {', '.join(cands[1:])})")
        if not host:
            try:
                host = input("No MRSI hello heard. Enter the BEAST+ IP: "
                             ).strip()
            except EOFError:
                host = ""
            if not host:
                print("No host given. Exiting.")
                return 2

        # ---- 2. TCP session ----
        print(f"Connecting TCP {host}:{tcp_port} ...")
        try:
            s = socket.create_connection((host, tcp_port), timeout=8)
        except OSError as e:
            print(f"ERROR: cannot reach TCP {host}:{tcp_port}: {e}")
            print("Is the unit powered, on this LAN, and is its MRSI "
                  "service enabled?")
            return 2
        js = JsonLines(s)
        my_ip = s.getsockname()[0]
        log({"dir": "tcp", "event": "connected", "host": host,
             "port": tcp_port, "my_ip": my_ip})
        print(f"Connected. Our IP as seen by the unit: {my_ip}")

        line = js.send({"type": "connect_req"})
        log({"dir": "tcp-out", "raw": line})
        handle = None
        for kind, msg in js.drain():
            if kind == "json":
                log({"dir": "tcp-in", "msg": msg})
                n_tcp += 1
                for k in ("id", "handle", "client_id", "clientHandle",
                          "client_handle"):
                    if isinstance(msg.get(k), str):
                        handle = msg[k]
                        break
            else:
                log({"dir": "tcp-in", "raw": msg})
        # one more drain in case the reply was slow
        time.sleep(0.5)
        for kind, msg in js.drain():
            if kind == "json":
                log({"dir": "tcp-in", "msg": msg})
                n_tcp += 1
                if handle is None:
                    for k in ("id", "handle", "client_id", "clientHandle",
                              "client_handle"):
                        if isinstance(msg.get(k), str):
                            handle = msg[k]
                            break
            else:
                log({"dir": "tcp-in", "raw": msg})
        print(f"Client handle: {handle}")
        if handle is None:
            print("WARNING: no handle found in connect reply -- continuing "
                  "with id=null; the reply is logged for analysis.")

        # ---- 3. available streams ----
        js.send({"type": "available_streams_req", "id": handle})
        log({"dir": "tcp-out", "raw": '{"type":"available_streams_req"}'})
        time.sleep(0.5)
        streams = []
        for kind, msg in js.drain():
            if kind == "json":
                log({"dir": "tcp-in", "msg": msg})
                n_tcp += 1
                for k in ("streams", "available_streams", "data",
                          "stream_list"):
                    v = msg.get(k)
                    if isinstance(v, list):
                        streams = v
                        break
            else:
                log({"dir": "tcp-in", "raw": msg})
        print(f"Advertised streams: {len(streams)}")
        for st in streams:
            print("   ", json.dumps(st)[:160])

        # ---- 4. subscribe (receive-only) ----
        want = ("lob", "hits", "compass", "psd", "meta")
        udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp_sock.bind(("", 0))
        udp_sock.settimeout(1.0)
        udp_port = udp_sock.getsockname()[1]
        targets = []
        for st in streams:
            if not isinstance(st, dict):
                continue
            sid = st.get("stream_id")
            blob = json.dumps(st).lower()
            if sid and any(w in blob for w in want):
                targets.append((sid, st.get("data_type") or "lob"))
        if not targets:
            targets = [("simple.lob.0.0", "lob"),
                       ("simple.hits.0.0", "hits")]
            print("No matching advertised streams; trying conventional ids.")
        for sid, dt in targets:
            req = {"type": "subscribe_req", "id": handle, "endpoint": 0,
                   "stream_id": sid, "data_type": dt,
                   "ip": my_ip, "port": udp_port}
            line = js.send(req)
            log({"dir": "tcp-out", "raw": line})
            time.sleep(0.3)
            for kind, msg in js.drain():
                log({"dir": "tcp-in", "msg": msg} if kind == "json"
                    else {"dir": "tcp-in", "raw": msg})
                n_tcp += 1
            print(f"Subscribed {sid} -> {my_ip}:{udp_port}")

        # ---- 5. read-only GPS query (position anchor for the driver) ----
        try:
            line = js.send({"type": "command_req", "id": handle,
                            "command": "info.gps", "endpoint": 0,
                            "args": {}})
            log({"dir": "tcp-out", "raw": line})
            time.sleep(0.5)
            for kind, msg in js.drain():
                log({"dir": "tcp-in", "msg": msg} if kind == "json"
                    else {"dir": "tcp-in", "raw": msg})
                n_tcp += 1
        except Exception as e:
            log({"dir": "local", "warn": f"gps query failed: {e}"})

        # ---- 6. capture ----
        print(f"\nCapturing for {minutes} minute(s): UDP :{udp_port} + TCP. "
              "Ctrl+C stops early.")
        deadline = time.time() + minutes * 60
        try:
            while time.time() < deadline:
                try:
                    data, addr = udp_sock.recvfrom(65535)
                except socket.timeout:
                    pass
                else:
                    n_udp += 1
                    rec = record_datagram(data, addr)
                    log(rec)
                    if n_udp % 25 == 1:
                        print(f"[udp] {n_udp} datagrams so far "
                              f"(last {len(data)}B from {addr[0]})")
                for kind, msg in js.drain():
                    n_tcp += 1
                    log({"dir": "tcp-in", "msg": msg} if kind == "json"
                        else {"dir": "tcp-in", "raw": msg})
        except KeyboardInterrupt:
            pass

        # ---- 7. polite cleanup ----
        for sid, _ in targets:
            try:
                line = js.send({"type": "unsubscribe_req", "id": handle,
                                "endpoint": 0, "stream_id": sid})
                log({"dir": "tcp-out", "raw": line})
            except Exception:
                pass
        try:
            line = js.send({"type": "disconnect_req", "id": handle})
            log({"dir": "tcp-out", "raw": line})
        except Exception:
            pass
        s.close()
        udp_sock.close()

    print(f"\nDone: {n_udp} UDP datagrams, {n_tcp} TCP messages -> {out_path}")
    if n_udp == 0:
        print("No UDP data arrived. The session handshake is logged -- send "
              "the file; it shows how far the unit got.")
    return 0


# --------------------------------------------------------------------------
# Self-test: fake MRSI server on loopback, full client run against it.
# --------------------------------------------------------------------------

def _mock_server(tcp_port, ready_evt, seen):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", tcp_port))
    srv.listen(1)
    ready_evt.set()
    conn, _ = srv.accept()
    buf = ""

    def udp_burst(ip, port):
        time.sleep(0.4)
        try:
            us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            for i in range(3):
                us.sendto(json.dumps(
                    {"type": "lob", "bearing_deg": 137.2 + i,
                     "freq_hz": 462000000, "confidence": 0.87}).encode(),
                    (ip, port))
            us.sendto(json.dumps(
                {"type": "hits", "freq_hz": 462000000,
                 "power_dbm": -71}).encode(), (ip, port))
            us.close()
        except PermissionError:
            # sandboxed CI: UDP send blocked; the datagram path is
            # unit-tested separately via record_datagram().
            seen["udp_blocked"] = True

    def reply(obj):
        conn.sendall((json.dumps(obj) + "\n").encode())

    conn.settimeout(10)
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk.decode("utf-8", errors="replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = msg.get("type")
                if t == "connect_req":
                    reply({"type": "command_rep", "id": "MOCK1",
                           "result": "ok"})
                elif t == "available_streams_req":
                    reply({"type": "command_rep", "id": "MOCK1",
                           "result": "ok",
                           "streams": [
                               {"stream_id": "simple.lob.0.0",
                                "data_type": "lob"},
                               {"stream_id": "simple.hits.0.0",
                                "data_type": "hits"}]})
                elif t == "subscribe_req":
                    reply({"type": "command_rep", "id": "MOCK1",
                           "result": "ok"})
                    seen.setdefault("subscribes", []).append(msg)
                    threading.Thread(
                        target=udp_burst,
                        args=(msg["ip"], msg["port"]),
                        daemon=True).start()
                elif t == "command_req":
                    reply({"type": "command_rep", "id": "MOCK1",
                           "result": "ok", "lat": 35.05, "lon": -78.88})
                elif t in ("unsubscribe_req", "disconnect_req"):
                    reply({"type": "command_rep", "id": "MOCK1",
                           "result": "ok"})
    except (OSError, socket.timeout):
        pass
    finally:
        conn.close()
        srv.close()


def self_test():
    # unit: hello IP extraction
    assert extract_ips("hello from 192.168.1.50 port 10051") == \
        ["192.168.1.50"], "hello ip"
    assert extract_ips("no ip here") == [], "no ip"

    # unit: JsonLines tolerates a JSON object split across recvs
    a, b = socket.socketpair()
    js = JsonLines(a)
    b.sendall(b'{"type":"command_rep","id":"X"')
    assert js.drain() == [], "split object not yet complete"
    b.sendall(b'}\n{"second":1}\n')
    got = js.drain()
    assert len(got) == 2 and got[0][1]["id"] == "X" \
        and got[1][1]["second"] == 1, f"reassembly: {got}"
    a.close()
    b.close()

    # unit: datagram recording (no sockets needed)
    r = record_datagram(
        json.dumps({"type": "lob", "bearing_deg": 137.2}).encode(),
        ("10.0.0.5", 10051))
    assert r["json"]["bearing_deg"] == 137.2 and r["len"] > 0, "json datagram"
    r = record_datagram(b"plain text, not json", ("10.0.0.5", 10051))
    assert r["text"] == "plain text, not json", "text datagram"
    r = record_datagram(b"\x00\x01\x02\xff", ("10.0.0.5", 10051))
    assert r["hex"] == "000102ff", "binary datagram"

    # integration: full client run against the mock server
    port = 10051
    ready = threading.Event()
    seen = {}
    th = threading.Thread(target=_mock_server, args=(port, ready, seen),
                          daemon=True)
    th.start()
    assert ready.wait(5), "mock server did not start"
    out = "/tmp/mrsi_selftest.jsonl"
    try:
        import os
        os.remove(out)
    except OSError:
        pass
    rc = probe("127.0.0.1", minutes=0.08, out_path=out,
               tcp_port=port, skip_discovery=True)
    assert rc == 0, "probe exit code"
    recs = [json.loads(l) for l in open(out, encoding="utf-8")]
    assert any(r.get("dir") == "tcp-in"
               and isinstance(r.get("msg"), dict)
               and r["msg"].get("result") == "ok" for r in recs), \
        "no ok reply logged"
    subs = seen.get("subscribes", [])
    assert len(subs) == 2, f"expected 2 subscribes, got {len(subs)}"
    for s in subs:
        assert s["ip"] == "127.0.0.1" and s["port"] > 0, \
            f"bad subscribe target: {s}"
        assert s["endpoint"] == 0 and s["stream_id"].startswith("simple."), \
            f"bad subscribe fields: {s}"
    assert any(r.get("dir") == "tcp-out"
               and "unsubscribe_req" in r.get("raw", "") for r in recs), \
        "no unsubscribe logged"
    assert any(r.get("dir") == "tcp-out"
               and "disconnect_req" in r.get("raw", "") for r in recs), \
        "no disconnect logged"
    if not seen.get("udp_blocked"):
        udps = [r for r in recs if r.get("dir") == "udp-in"]
        lobs = [r for r in udps
                if isinstance(r.get("json"), dict)
                and r["json"].get("type") == "lob"]
        assert len(lobs) >= 3, \
            f"expected >=3 lob datagrams, got {len(lobs)}"
        print(f"self-test: all checks passed "
              f"({len(recs)} records, {len(lobs)} lob datagrams)")
    else:
        print(f"self-test: all checks passed "
              f"({len(recs)} records; UDP send blocked in this sandbox, "
              f"datagram path covered by unit tests)")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="MRSI probe: subscribe-only capture from a CACI "
                    "Mastodon-family sensor (BEAST+)")
    ap.add_argument("--host", default=None,
                    help="unit IP (skips multicast discovery)")
    ap.add_argument("--minutes", type=float, default=5,
                    help="auto-stop after N minutes")
    ap.add_argument("--out", default=None, help="output JSONL path")
    ap.add_argument("--self-test", action="store_true",
                    help="run mock-server self-test")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    out_path = args.out or ("mrsi_probe_%s.jsonl"
                            % datetime.now().strftime("%Y%m%d_%H%M%S"))
    return probe(args.host, args.minutes, out_path)


if __name__ == "__main__":
    sys.exit(main())
