#!/usr/bin/env python3
"""
l3harris_snmp_probe.py — read-only SNMP survey of an L3Harris radio (AN/PRC-163).

v2: dependency-free. SNMP (BER/DER over UDP) is implemented inline —
no pip, no pysnmp, nothing to install. Pure Python 3 standard library.

Walks the radio's SNMP agent and reports what it exposes: identity
(sysDescr/sysObjectID), network interfaces, and the vendor enterprise
subtree where link/signal metrics live if the radio publishes them.

READ-ONLY: only GET / walk operations. Nothing is changed on the radio.

Usage (PowerShell):
  python l3harris_snmp_probe.py --ip 192.168.1.50
  python l3harris_snmp_probe.py --ip 192.168.1.50 --community private

Output: prints a summary and writes l3harris_snmp_walk_<ip>_<time>.txt
in the current folder. Send that file back to Spark — it shows exactly
which OIDs exist, and the Shepherd driver gets built from the ones that
carry signal/link data.

If the radio doesn't answer at all, its SNMP agent is probably disabled:
check the management settings in CPA (or ask your comms shop) and re-run.
"""
import argparse
import random
import socket
import sys
import time

SYS_DESCR = "1.3.6.1.2.1.1.1.0"
SYS_OBJECT_ID = "1.3.6.1.2.1.1.2.0"
SYS_UPTIME = "1.3.6.1.2.1.1.3.0"
SYS_NAME = "1.3.6.1.2.1.1.5.0"
IF_TABLE = "1.3.6.1.2.1.2.2.1"
ENTERPRISES = "1.3.6.1.4.1"
MAX_OIDS = 3000
MAX_REPETITIONS = 20


# ---------------------------------------------------------------- BER codec
def _enc_length(n):
    if n < 128:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def _tlv(tag, content):
    return bytes([tag]) + _enc_length(len(content)) + content


def _enc_int(n):
    if n == 0:
        body = b"\x00"
    else:
        body = n.to_bytes((n.bit_length() + 8) // 8, "big", signed=True)
        while len(body) > 1:
            if body[0] == 0x00 and (body[1] & 0x80) == 0:
                body = body[1:]
            elif body[0] == 0xFF and (body[1] & 0x80) == 0x80:
                body = body[1:]
            else:
                break
    return _tlv(0x02, body)


def _dec_int(body):
    return int.from_bytes(body, "big", signed=True)


def _enc_subid(n):
    if n == 0:
        return b"\x00"
    groups = []
    while n > 0:
        groups.append(n & 0x7F)
        n >>= 7
    groups.reverse()
    out = bytearray()
    for i, g in enumerate(groups):
        if i < len(groups) - 1:
            g |= 0x80
        out.append(g)
    return bytes(out)


def _enc_oid(s):
    parts = [int(x) for x in s.strip(".").split(".")]
    body = bytes([40 * parts[0] + parts[1]])
    for p in parts[2:]:
        body += _enc_subid(p)
    return _tlv(0x06, body)


def _dec_oid(body):
    if not body:
        return ""
    first = body[0]
    if first < 40:
        parts = [0, first]
    elif first < 80:
        parts = [1, first - 40]
    else:
        parts = [2, first - 80]
    i = 1
    while i < len(body):
        n = 0
        while True:
            b = body[i]
            i += 1
            n = (n << 7) | (b & 0x7F)
            if not (b & 0x80):
                break
        parts.append(n)
    return ".".join(str(p) for p in parts)


def _read_tlv(buf, pos):
    if pos + 2 > len(buf):
        raise ValueError("truncated TLV")
    tag = buf[pos]
    pos += 1
    ln = buf[pos]
    pos += 1
    if ln & 0x80:
        n = ln & 0x7F
        if n == 0 or pos + n > len(buf):
            raise ValueError("bad length")
        ln = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    if pos + ln > len(buf):
        raise ValueError("truncated value")
    return tag, buf[pos:pos + ln], pos + ln


def _decode_value(tag, content):
    if tag == 0x02:
        return str(_dec_int(content))
    if tag == 0x04:
        try:
            s = content.decode("utf-8", errors="strict")
            if s and all(ch.isprintable() or ch in "\r\n\t" for ch in s):
                return '"%s"' % s
        except Exception:
            pass
        return "hex:" + content.hex()
    if tag == 0x06:
        return _dec_oid(content)
    if tag == 0x05:
        return "NULL"
    if tag == 0x40:
        return ".".join(str(b) for b in content)
    if tag in (0x41, 0x42, 0x43, 0x46):
        return str(int.from_bytes(content, "big"))
    if tag == 0x80:
        return "noSuchObject"
    if tag == 0x81:
        return "noSuchInstance"
    if tag == 0x82:
        return "endOfMibView"
    return "tag%02x:%s" % (tag, content.hex())


# ---------------------------------------------------------------- SNMP client
class SnmpClient:
    def __init__(self, ip, port=161, community="public", timeout=2.5, retries=2):
        self.ip = ip
        self.port = port
        self.community = community.encode()
        self.timeout = timeout
        self.retries = retries
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)

    def _message(self, pdu_tag, req_id, varbinds, non_rep=0, max_rep=0):
        vb_seq = b""
        for oid in varbinds:
            vb_seq += _tlv(0x30, _enc_oid(oid) + _tlv(0x05, b""))
        vbl = _tlv(0x30, vb_seq)
        pdu = _tlv(
            pdu_tag,
            _enc_int(req_id) + _enc_int(non_rep) + _enc_int(max_rep) + vbl,
        )
        return _tlv(
            0x30, _enc_int(1) + _tlv(0x04, self.community) + pdu
        )

    def _exchange(self, pdu_tag, oids, max_rep=0):
        req_id = random.randint(1, 0x7FFFFFFF)
        msg = self._message(pdu_tag, req_id, oids, max_rep=max_rep)
        last_err = "timeout"
        for _ in range(self.retries + 1):
            try:
                self.sock.sendto(msg, (self.ip, self.port))
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError as e:
                last_err = str(e)
                continue
            try:
                return self._parse_response(data, req_id), None
            except ValueError as e:
                last_err = "bad response: %s" % e
        return None, last_err

    def _parse_response(self, data, req_id):
        tag, content, pos = _read_tlv(data, 0)
        if tag != 0x30 or pos != len(data):
            raise ValueError("not a message")
        p = 0
        _t, _c, p = _read_tlv(content, p)  # version
        _t, _c, p = _read_tlv(content, p)  # community
        pdu_tag, pdu, p = _read_tlv(content, p)
        if pdu_tag != 0xA2:
            raise ValueError("not a response PDU")
        q = 0
        _t, rid_c, q = _read_tlv(pdu, q)
        if _dec_int(rid_c) != req_id:
            raise ValueError("request-id mismatch")
        _t, estat_c, q = _read_tlv(pdu, q)
        _t, _eidx_c, q = _read_tlv(pdu, q)
        if _dec_int(estat_c) != 0:
            raise ValueError("agent error status %d" % _dec_int(estat_c))
        _t, vbl, q = _read_tlv(pdu, q)
        out = []
        r = 0
        while r < len(vbl):
            _t, vb, r = _read_tlv(vbl, r)
            s = 0
            _t, oid_c, s = _read_tlv(vb, s)
            vtag, vbytes, _s = _read_tlv(vb, s)
            out.append((_dec_oid(oid_c), _decode_value(vtag, vbytes)))
        return out

    def get(self, oid):
        res, err = self._exchange(0xA0, [oid])
        if err or not res:
            return None, err or "empty"
        return res[0][1], None

    def walk(self, root, limit=MAX_OIDS):
        out = []
        cur = root
        root_dot = root + "."
        while len(out) < limit:
            res, err = self._exchange(0xA5, [cur], max_rep=MAX_REPETITIONS)
            if err:
                return out, err
            if not res:
                return out, "empty response"
            progressed = False
            for oid, val in res:
                if val in ("endOfMibView", "noSuchObject", "noSuchInstance"):
                    return out, None
                if oid == root or oid.startswith(root_dot):
                    out.append((oid, val))
                    cur = oid
                    progressed = True
                else:
                    return out, None  # walked past the subtree
            if not progressed:
                return out, "no progress"
        return out, "limit reached (%d)" % limit


# ---------------------------------------------------------------- probe
def local_route_info(ip, port):
    """Which local interface would carry traffic to the target.
    UDP connect() sends nothing; it just resolves the route."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((ip, port))
        return s.getsockname()[0]
    except OSError as e:
        return "UNREACHABLE (%s)" % e
    finally:
        s.close()


COMMUNITY_FALLBACKS = ["public", "private", "admin", "harris"]


def main():
    ap = argparse.ArgumentParser(description="Read-only SNMP survey of an L3Harris radio.")
    ap.add_argument("--ip", required=True, help="Radio IP address")
    ap.add_argument("--port", type=int, default=161)
    ap.add_argument("--community", default="public", help="SNMPv2c community")
    args = ap.parse_args()

    stamp = time.strftime("%Y%m%d_%H%M%S")
    fname = "l3harris_snmp_walk_%s_%s.txt" % (args.ip.replace(".", "_"), stamp)
    log = open(fname, "w", encoding="utf-8")

    def say(msg):
        print(msg, flush=True)
        log.write(msg + "\n")

    say("L3Harris SNMP probe v2 (dependency-free) | target %s:%d | %s"
        % (args.ip, args.port, stamp))
    say("=" * 70)
    say("[*] Local interface for this target: %s"
        % local_route_info(args.ip, args.port))

    # Try the requested community first, then common fallbacks.
    communities = [args.community] + [
        c for c in COMMUNITY_FALLBACKS if c != args.community
    ]
    cli = None
    descr = None
    working_community = None
    for comm in communities:
        attempt = SnmpClient(args.ip, args.port, comm)
        descr, err = attempt.get(SYS_DESCR)
        if not err:
            cli = attempt
            working_community = comm
            break
    if descr is None:
        say("[!] No SNMP answer on any community %s" % communities)
        say("    Either this PC can't reach %s, or the radio's SNMP agent" % args.ip)
        say("    is disabled / restricted.")
        say("")
        say("    30-second check: run  ping %s" % args.ip)
        say("    - ping FAILS  -> network problem, not SNMP. Check the cable,")
        say("      and that this PC has an address on the same subnet")
        say("      (compare with the 'Local interface' line above).")
        say("    - ping WORKS  -> the SNMP agent is off or locked down.")
        say("      Check the management settings in CPA (or ask your")
        say("      comms shop), then re-run.")
        log.close()
        return 2
    if working_community != args.community:
        say("[*] Answered on community '%s'" % working_community)
    objid, _ = cli.get(SYS_OBJECT_ID)
    uptime, _ = cli.get(SYS_UPTIME)
    name, _ = cli.get(SYS_NAME)
    say("[*] sysDescr    : %s" % descr)
    say("[*] sysObjectID : %s" % objid)
    say("[*] sysName     : %s" % name)
    say("[*] sysUpTime   : %s" % uptime)
    say("")

    say("[*] Interfaces:")
    rows, err = cli.walk(IF_TABLE, limit=200)
    if err:
        say("    walk error: %s" % err)
    else:
        descrs = {}
        for oid, val in rows:
            if oid.startswith(IF_TABLE + ".2."):
                descrs[oid.split(".")[-1]] = val
        for oid, val in rows:
            if oid.startswith(IF_TABLE + ".8."):
                idx = oid.split(".")[-1]
                say("    ifIndex %s : %-28s oper=%s"
                    % (idx, descrs.get(idx, "?"), val))
    say("")

    enterprise = None
    if objid:
        parts = objid.strip().strip('"').split(".")
        if parts[:6] == ["1", "3", "6", "1", "4", "1"] and len(parts) > 6:
            enterprise = ".".join(parts[:7])
    if not enterprise:
        say("[!] Could not derive the vendor enterprise OID from sysObjectID.")
        say("    Send this file back anyway — the interfaces above still help.")
        log.close()
        return 0

    say("[*] Vendor enterprise subtree: %s" % enterprise)
    say("[*] Walking it (cap %d OIDs; full dump goes to %s)..." % (MAX_OIDS, fname))
    rows, err = cli.walk(enterprise)
    say("[*] OIDs found: %d%s" % (len(rows), " (%s)" % err if err else ""))
    log.write("\n--- enterprise walk: %s ---\n" % enterprise)
    for oid, val in rows:
        log.write("%s = %s\n" % (oid, val))
    say("")
    say("[*] First 30 enterprise OIDs (preview — full list is in the file):")
    for oid, val in rows[:30]:
        say("    %s = %s" % (oid, val))
    if len(rows) > 30:
        say("    ... %d more in %s" % (len(rows) - 30, fname))

    say("")
    say("DONE. Send %s back to Spark." % fname)
    say("The Shepherd L3Harris driver gets built from whichever of these")
    say("OIDs carry per-link signal data (RSSI/SNR/neighbor quality).")
    log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
