#!/usr/bin/env python3
"""End-to-end tests for the ZMeta invite-code pairing flow.

Spins up zmeta_pairing_server.py in a temp dir (throwaway openssl cert),
then exercises: health, invite format, redeem happy path, bad/expired/
used token, bad platform_id, duplicate platform_id, bad pubkey, IP
allocation increments, revoke, re-register after revoke (IP not reused),
malformed body, and the rate limiter.

Usage: python test_pairing.py
Exit 0 = all pass.
"""

import base64
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

SECURE_DIR = Path(__file__).resolve().parent
SERVER = SECURE_DIR / "zmeta_pairing_server.py"
CLI = SECURE_DIR / "zmeta_invite.py"

PASS = []
FAIL = []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("  ok  " if cond else "  FAIL") + f" {name}"
          + (f" — {detail}" if detail and not cond else ""))


def wg_pubkey():
    return base64.b64encode(os.urandom(32)).decode()  # 44 chars, std b64


def udp_loopback_works():
    """Some sandboxes block UDP sendto entirely (even loopback). Probe
    once; the datagram-content assertions degrade gracefully there."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.sendto(b"probe", ("127.0.0.1", p))
        s.settimeout(2)
        s.recvfrom(64)
        s.close()
        return True
    except OSError:
        return False


def parse_invite(code):
    """Parse Z1.<hub_host>.<pair_port>.<wg_port>.<token>.<certfp>.

    hub_host may itself contain dots (FQDN / IPv4), so parse from the
    RIGHT: certfp is 64 hex, token is 43 base64url chars, then two
    numeric ports; everything between 'Z1.' and pair_port is hub_host.
    """
    parts = code.split(".")
    assert len(parts) >= 6 and parts[0] == "Z1", code
    certfp, token, wg_port, pair_port = parts[-1], parts[-2], parts[-3], parts[-4]
    hub = ".".join(parts[1:-4])
    assert re.fullmatch(r"[0-9a-f]{64}", certfp), code
    assert len(token) == 43, code
    assert pair_port.isdigit() and wg_port.isdigit(), code
    return {"hub": hub, "pair_port": int(pair_port), "wg_port": int(wg_port),
            "token": token, "certfp": certfp}


class Client:
    def __init__(self, port):
        self.base = f"https://127.0.0.1:{port}"
        self.ctx = ssl._create_unverified_context()

    def get(self, path):
        req = urllib.request.Request(self.base + path)
        try:
            with urllib.request.urlopen(req, timeout=10, context=self.ctx) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def post(self, path, obj):
        data = json.dumps(obj).encode()
        req = urllib.request.Request(self.base + path, data=data,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10, context=self.ctx) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def post_raw(self, path, raw: bytes):
        req = urllib.request.Request(self.base + path, data=raw,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10, context=self.ctx) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def post_ingest(self, obj, token=None):
        data = json.dumps(obj).encode()
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + "/ingest", data=data,
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10, context=self.ctx) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def post_ingest_raw(self, raw: bytes, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + "/ingest", data=raw,
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10, context=self.ctx) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()


def run_cli(*argv):
    r = subprocess.run([sys.executable, str(CLI), *argv],
                       capture_output=True, text=True, timeout=30)
    return r


def main():
    tmp = Path(tempfile.mkdtemp(prefix="zmeta-pair-test-"))
    print(f"workdir: {tmp}")

    # ---- fixtures ------------------------------------------------------
    (tmp / "wg0.conf").write_text(
        "[Interface]\nPrivateKey = SERVERPRIVKEY\nAddress = 10.99.0.1/32\n"
        "ListenPort = 51820\n", encoding="utf-8")
    (tmp / "PEERS.md").write_text(
        "# Peer registry\n\n"
        "| Tunnel IP | Mesh public key (first 16 chars…) | platform_id |"
        " Party / unit | lat | lon | alt_m (MSL*) | Position updated (UTC) | Added |\n"
        "|---|---|---|---|---|---|---|---|---|\n", encoding="utf-8")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-keyout", str(tmp / "pairing.key"),
                    "-out", str(tmp / "pairing.crt"),
                    "-days", "2", "-nodes", "-subj", "/CN=test"],
                   capture_output=True, check=True)
    fp = subprocess.run(
        ["openssl", "x509", "-in", str(tmp / "pairing.crt"),
         "-outform", "DER"],
        capture_output=True, check=True).stdout
    import hashlib
    certfp = hashlib.sha256(fp).hexdigest()
    hub_pubkey = wg_pubkey()
    (tmp / "pairing.conf").write_text(
        f"hub_pubkey={hub_pubkey}\nwg_port=51820\n"
        f"wg_endpoint=127.0.0.1:51820\nwg_interface=wg0\npair_port=0\n"
        f"zmeta_target=10.99.0.1:5555\ncertfp={certfp}\n"
        f"ingest_url=https://hub.test/zmeta/ingest\n", encoding="utf-8")

    # ---- fake gateway: throwaway UDP socket standing in for the real ----
    # ---- ZMeta gateway ingest (the server forwards /ingest here)  --------
    UDP_OK = udp_loopback_works()
    if not UDP_OK:
        print("NOTE: this sandbox blocks UDP sendto — datagram-content")
        print("assertions will degrade to forward-step checks.")
    gw_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    gw_sock.bind(("127.0.0.1", 0))
    gw_sock.settimeout(5)
    gw_port = gw_sock.getsockname()[1]

    # ---- start server --------------------------------------------------
    srv = subprocess.Popen(
        [sys.executable, "-u", str(SERVER),
         "--conf", str(tmp / "pairing.conf"),
         "--pair-host", "127.0.0.1", "--pair-port", "0",
         "--wg-config", str(tmp / "wg0.conf"),
         "--peers", str(tmp / "PEERS.md"),
         "--state", str(tmp / "pairing_state.json"),
         "--invites", str(tmp / "invites.json"),
         "--cert", str(tmp / "pairing.crt"),
         "--key", str(tmp / "pairing.key"),
         "--gateway-host", "127.0.0.1", "--gateway-port", str(gw_port),
         "--log", str(tmp / "pairing.log")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        cwd=str(tmp))
    port = None
    deadline = time.time() + 15
    while time.time() < deadline and port is None:
        line = srv.stdout.readline()
        m = re.search(r"https://127\.0\.0\.1:(\d+)/", line or "")
        if m:
            port = int(m.group(1))
    if port is None:
        print("server did not start; output:")
        print(srv.stdout.read())
        srv.kill()
        sys.exit(2)
    print(f"server on 127.0.0.1:{port}")
    c = Client(port)
    time.sleep(0.3)

    try:
        # ---- health ----------------------------------------------------
        code, body = c.get("/health")
        check("GET /health -> 200 {ok:true}", code == 200 and body == {"ok": True}, f"{code} {body}")

        # ---- invite ----------------------------------------------------
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "invite", "--label", "Test Team", "--hub", "127.0.0.1",
                    "--pair-port", str(port), "--days", "7")
        m = re.search(r"Z1\.\S+", r.stdout)
        check("invite prints a code", m is not None, r.stdout[-200:] + r.stderr[-200:])
        code1 = m.group(0)
        inv1 = parse_invite(code1)
        check("invite format Z1.host.pair.wg.token(43).fp(64)",
              inv1["hub"] == "127.0.0.1" and inv1["pair_port"] == port
              and inv1["wg_port"] == 51820 and len(inv1["token"]) == 43,
              code1)
        token1 = inv1["token"]

        # ---- Cloudflare-mode invite (certfp '-') + label sanitize (S4) ----
        (tmp / "pairing-cf.conf").write_text(
            (tmp / "pairing.conf").read_text().replace(f"certfp={certfp}",
                                                       "certfp=-"),
            encoding="utf-8")
        r = run_cli("--conf", str(tmp / "pairing-cf.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "invite", "--label", "cf\nINJECT", "--hub", "pair.example.com",
                    "--pair-port", "443")
        m = re.search(r"Z1\.\S+", r.stdout)
        check("cloudflare-mode invite ends .-",
              m is not None and m.group(0).endswith(".-"),
              r.stdout[-200:] + r.stderr[-200:])
        inv = json.loads((tmp / "invites.json").read_text())
        cf_inv = [i for i in inv["invites"]
                  if i.get("label", "").startswith("cf ")]
        check("label sanitized (newline stripped, S4)",
              len(cf_inv) == 1 and cf_inv[0]["label"] == "cf INJECT",
              str([i.get("label") for i in cf_inv]))

        # ---- redeem happy path -----------------------------------------
        pk1 = wg_pubkey()
        code_, body = c.post("/redeem", {"token": token1, "pubkey": pk1,
                                         "platform_id": "test-mesh-1"})
        check("redeem happy -> 200", code_ == 200 and body.get("ok") is True,
              f"{code_} {body}")
        check("tunnel_ip 10.99.0.11", body.get("tunnel_ip") == "10.99.0.11", str(body))
        check("hub_pubkey echoed", body.get("hub_pubkey") == hub_pubkey)
        check("hub_endpoint", body.get("hub_endpoint") == "127.0.0.1:51820", str(body))
        check("zmeta_target", body.get("zmeta_target") == "10.99.0.1:5555", str(body))
        check("reload_needed true (no wg binary)", body.get("reload_needed") is True, str(body))

        wg_text = (tmp / "wg0.conf").read_text(encoding="utf-8")
        check("wg conf has [Peer] + key",
              "[Peer]" in wg_text and pk1 in wg_text, wg_text[-300:])
        check("wg conf AllowedIPs /32", "AllowedIPs = 10.99.0.11/32" in wg_text)
        peers_text = (tmp / "PEERS.md").read_text(encoding="utf-8")
        check("PEERS.md row added",
              "10.99.0.11" in peers_text and "test-mesh-1" in peers_text,
              peers_text[-300:])
        state = json.loads((tmp / "pairing_state.json").read_text())
        check("state allocated .11", state["allocated"].get("10.99.0.11", {}).get("platform_id") == "test-mesh-1")
        check("next_suffix bumped", state["next_suffix"] == 12, str(state.get("next_suffix")))
        check("redeem returns ingest_url",
              body.get("ingest_url") == "https://hub.test/zmeta/ingest", str(body.get("ingest_url")))
        check("redeem returns ingest_token (43 chars)",
              isinstance(body.get("ingest_token"), str) and len(body["ingest_token"]) == 43)
        ingest_tok1 = body["ingest_token"]
        check("only the token hash is stored hub-side",
              len(state.get("ingest_tokens", {})) == 1
              and ingest_tok1 not in json.dumps(state["ingest_tokens"]))

        # ---- ingest happy path: 202 + datagram arrives intact ------------
        event1 = {"zmeta_version": "1.0",
                  "source": {"platform_id": "test-mesh-1"},
                  "event": {"event_type": "OBSERVATION"}, "seq": 1}
        raw1 = json.dumps(event1).encode()
        code_, body = c.post_ingest(event1, ingest_tok1)
        if UDP_OK:
            check("ingest happy -> 202 {ok:true}",
                  code_ == 202 and body == {"ok": True}, f"{code_} {body}")
            data, _ = gw_sock.recvfrom(65536)
            check("gateway receives the raw datagram intact", data == raw1,
                  f"{len(data)} vs {len(raw1)} bytes")
        else:
            # Sandbox blocks UDP: auth + binding already passed if we get
            # exactly forward_failed (the forward step was reached).
            check("ingest reaches forward step (500 forward_failed, UDP blocked)",
                  code_ == 500 and body == {"ok": False, "error": "forward_failed"},
                  f"{code_} {body}")

        # ---- ingest: bad / missing token -> 401 --------------------------
        code_, body = c.post_ingest(event1, "B" * 43)
        check("ingest bad token -> 401 unauthorized",
              code_ == 401 and body == {"ok": False, "error": "unauthorized"},
              f"{code_} {body}")
        code_, body = c.post_ingest(event1, None)
        check("ingest no auth header -> 401 unauthorized",
              code_ == 401 and body == {"ok": False, "error": "unauthorized"},
              f"{code_} {body}")

        # ---- ingest: platform mismatch -> 403 ----------------------------
        event_x = dict(event1); event_x["source"] = {"platform_id": "someone-else"}
        code_, body = c.post_ingest(event_x, ingest_tok1)
        check("ingest platform mismatch -> 403 platform_mismatch",
              code_ == 403 and body == {"ok": False, "error": "platform_mismatch"},
              f"{code_} {body}")

        # top-level lookalike must NOT satisfy the binding: the gateway
        # reads source.platform_id, so only that field counts.
        event_y = {"zmeta_version": "1.0", "platform_id": "test-mesh-1",
                   "source": {"platform_id": "someone-else"}}
        code_, body = c.post_ingest(event_y, ingest_tok1)
        check("top-level platform_id cannot spoof source.platform_id -> 403",
              code_ == 403, f"{code_} {body}")
        event_z = {"zmeta_version": "1.0", "platform_id": "test-mesh-1"}
        code_, body = c.post_ingest(event_z, ingest_tok1)
        check("event without source.platform_id -> 403",
              code_ == 403, f"{code_} {body}")

        # ---- ingest: bad bodies -> 400 -----------------------------------
        code_, _ = c.post_ingest_raw(b"{not json", ingest_tok1)
        check("ingest malformed json -> 400", code_ == 400, str(code_))
        code_, _ = c.post_ingest_raw(b"[1,2,3]", ingest_tok1)
        check("ingest non-dict json -> 400", code_ == 400, str(code_))
        code_, _ = c.post_ingest_raw(b"x" * 70000, ingest_tok1)
        check("ingest oversize body -> 400", code_ == 400, str(code_))

        # ---- used token -------------------------------------------------
        code_, body = c.post("/redeem", {"token": token1, "pubkey": wg_pubkey(),
                                         "platform_id": "test-mesh-x"})
        check("reuse token -> 400 used",
              code_ == 400 and body == {"ok": False, "error": "used"}, f"{code_} {body}")

        # ---- bad token ---------------------------------------------------
        code_, body = c.post("/redeem", {"token": "A" * 43, "pubkey": wg_pubkey(),
                                         "platform_id": "nope"})
        check("bad token -> 400 bad_token",
              code_ == 400 and body == {"ok": False, "error": "bad_token"}, f"{code_} {body}")

        # ---- expired token -----------------------------------------------
        inv = json.loads((tmp / "invites.json").read_text())
        past = (time.time() - 3600)
        import datetime as dt
        exp_iso = dt.datetime.fromtimestamp(past, dt.timezone.utc).isoformat()
        tok_exp = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        inv["invites"].append({"token_hash": hashlib.sha256(tok_exp.encode()).hexdigest(),
                               "label": "old", "created_utc": exp_iso,
                               "expires_utc": exp_iso, "used": False,
                               "used_by": None, "used_utc": None})
        (tmp / "invites.json").write_text(json.dumps(inv))
        code_, body = c.post("/redeem", {"token": tok_exp, "pubkey": wg_pubkey(),
                                         "platform_id": "old-mesh"})
        check("expired token -> 400 expired",
              code_ == 400 and body == {"ok": False, "error": "expired"}, f"{code_} {body}")

        # ---- fresh token for the remaining negative tests -----------------
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "invite", "--label", "neg", "--hub", "127.0.0.1",
                    "--pair-port", str(port))
        token2 = parse_invite(re.search(r"Z1\.\S+", r.stdout).group(0))["token"]

        code_, body = c.post("/redeem", {"token": token2, "pubkey": wg_pubkey(),
                                         "platform_id": "Bad_ID!"})
        check("bad platform_id -> 400 bad_platform_id",
              code_ == 400 and body == {"ok": False, "error": "bad_platform_id"}, f"{code_} {body}")

        code_, body = c.post("/redeem", {"token": token2, "pubkey": wg_pubkey(),
                                         "platform_id": "test-mesh-1"})
        check("duplicate platform_id -> 400 platform_taken",
              code_ == 400 and body == {"ok": False, "error": "platform_taken"}, f"{code_} {body}")

        code_, body = c.post("/redeem", {"token": token2, "pubkey": "notakey",
                                         "platform_id": "test-mesh-2"})
        check("bad pubkey -> 400 bad_pubkey",
              code_ == 400 and body == {"ok": False, "error": "bad_pubkey"}, f"{code_} {body}")

        code_, raw = c.post_raw("/redeem", b"{not json")
        check("malformed body -> 400", code_ == 400, f"{code_} {raw}")

        # ---- second mesh gets .12 ----------------------------------------
        code_, body = c.post("/redeem", {"token": token2, "pubkey": wg_pubkey(),
                                         "platform_id": "test-mesh-2"})
        check("second mesh -> 10.99.0.12",
              code_ == 200 and body.get("tunnel_ip") == "10.99.0.12", f"{code_} {body}")

        # ---- revoke --------------------------------------------------------
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "--wg-config", str(tmp / "wg0.conf"),
                    "--peers", str(tmp / "PEERS.md"),
                    "revoke", "test-mesh-1")
        check("revoke exits 0", r.returncode == 0, r.stderr[-300:])
        wg_text = (tmp / "wg0.conf").read_text(encoding="utf-8")
        check("wg [Peer] block removed", pk1 not in wg_text and "10.99.0.11/32" not in wg_text)
        peers_text = (tmp / "PEERS.md").read_text(encoding="utf-8")
        check("PEERS.md row REVOKED", "REVOKED" in peers_text, peers_text[-200:])
        state = json.loads((tmp / "pairing_state.json").read_text())
        check("state marked revoked", state["allocated"]["10.99.0.11"]["revoked"] is True)

        # ---- revoke kills the HTTPS ingest token -------------------------
        code_, body = c.post_ingest(event1, ingest_tok1)
        check("ingest with revoked token -> 401 unauthorized",
              code_ == 401 and body == {"ok": False, "error": "unauthorized"},
              f"{code_} {body}")
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "list")
        check("list shows ingest token revoked",
              "[ingest:revoked]" in r.stdout, r.stdout[-400:])

        # ---- re-register same platform_id: allowed, IP NOT reused ---------
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "invite", "--label", "rejoin", "--hub", "127.0.0.1",
                    "--pair-port", str(port))
        token3 = parse_invite(re.search(r"Z1\.\S+", r.stdout).group(0))["token"]
        code_, body = c.post("/redeem", {"token": token3, "pubkey": wg_pubkey(),
                                         "platform_id": "test-mesh-1"})
        check("re-register after revoke -> 200 @ 10.99.0.13",
              code_ == 200 and body.get("tunnel_ip") == "10.99.0.13", f"{code_} {body}")
    finally:
        srv.terminate()
        srv.wait(timeout=10)
        gw_sock.close()

    # ---- rate limit (fresh server, clean counter) ---------------------------
    srv = subprocess.Popen(
        [sys.executable, "-u", str(SERVER),
         "--conf", str(tmp / "pairing.conf"),
         "--pair-host", "127.0.0.1", "--pair-port", "0",
         "--wg-config", str(tmp / "wg0.conf"),
         "--peers", str(tmp / "PEERS.md"),
         "--state", str(tmp / "pairing_state.json"),
         "--invites", str(tmp / "invites.json"),
         "--cert", str(tmp / "pairing.crt"),
         "--key", str(tmp / "pairing.key"),
         "--ingest-rate-per-min", "5",
         "--log", str(tmp / "pairing.log")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=str(tmp))
    port = None
    deadline = time.time() + 15
    while time.time() < deadline and port is None:
        line = srv.stdout.readline()
        m = re.search(r"https://127\.0\.0\.1:(\d+)/", line or "")
        if m:
            port = int(m.group(1))
    c = Client(port)
    time.sleep(0.3)
    try:
        # ---- S2: corrupt / missing expiry => expired (fail closed) --------
        inv = json.loads((tmp / "invites.json").read_text())
        bad1 = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        bad2 = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        inv["invites"].append({"token_hash": hashlib.sha256(bad1.encode()).hexdigest(),
                               "label": "corrupt-exp",
                               "created_utc": "2026-01-01T00:00:00+00:00",
                               "expires_utc": "not-a-date", "used": False,
                               "used_by": None, "used_utc": None})
        inv["invites"].append({"token_hash": hashlib.sha256(bad2.encode()).hexdigest(),
                               "label": "no-exp",
                               "created_utc": "2026-01-01T00:00:00+00:00",
                               # no expires_utc key at all
                               "used": False, "used_by": None, "used_utc": None})
        (tmp / "invites.json").write_text(json.dumps(inv))
        code_, body = c.post("/redeem", {"token": bad1, "pubkey": wg_pubkey(),
                                         "platform_id": "s2-a"})
        check("corrupt expires_utc -> 400 expired",
              code_ == 400 and body == {"ok": False, "error": "expired"},
              f"{code_} {body}")
        code_, body = c.post("/redeem", {"token": bad2, "pubkey": wg_pubkey(),
                                         "platform_id": "s2-b"})
        check("missing expires_utc -> 400 expired",
              code_ == 400 and body == {"ok": False, "error": "expired"},
              f"{code_} {body}")

        # ---- S3: failed PEERS.md write -> 500, invite stays usable -------
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "invite", "--label", "s3", "--hub", "127.0.0.1",
                    "--pair-port", str(port))
        token_s3 = parse_invite(re.search(r"Z1\.\S+", r.stdout).group(0))["token"]
        pk_s3 = wg_pubkey()
        wg_before = (tmp / "wg0.conf").read_text(encoding="utf-8")
        state_before = json.loads((tmp / "pairing_state.json").read_text())
        (tmp / "PEERS.md").unlink()
        (tmp / "PEERS.md").mkdir()  # directory: writes now fail
        code_, body = c.post("/redeem", {"token": token_s3, "pubkey": pk_s3,
                                         "platform_id": "s3-mesh"})
        check("peers write fails -> 500 provision_failed",
              code_ == 500 and body == {"ok": False, "error": "provision_failed"},
              f"{code_} {body}")
        check("failed provision rolls back the wg append",
              (tmp / "wg0.conf").read_text(encoding="utf-8") == wg_before)
        state_mid = json.loads((tmp / "pairing_state.json").read_text())
        check("failed provision leaves state untouched",
              state_mid == state_before,
              f"next_suffix={state_mid.get('next_suffix')}")
        inv_mid = json.loads((tmp / "invites.json").read_text())
        s3_inv = [i for i in inv_mid["invites"]
                  if i["token_hash"] == hashlib.sha256(token_s3.encode()).hexdigest()]
        check("invite NOT marked used after 500",
              len(s3_inv) == 1 and not s3_inv[0]["used"])
        # restore PEERS.md as a file; the same token must still redeem
        (tmp / "PEERS.md").rmdir()
        (tmp / "PEERS.md").write_text(
            "# Peer registry\n\n"
            "| Tunnel IP | Mesh public key (first 16 chars…) | platform_id |"
            " Party / unit | lat | lon | alt_m (MSL*) | Position updated (UTC) | Added |\n"
            "|---|---|---|---|---|---|---|---|---|\n", encoding="utf-8")
        code_, body = c.post("/redeem", {"token": token_s3, "pubkey": pk_s3,
                                         "platform_id": "s3-mesh"})
        check("same token redeems after hub fixed -> 200 @ .14",
              code_ == 200 and body.get("tunnel_ip") == "10.99.0.14",
              f"{code_} {body}")

        # ---- ingest rate limit (5/min on this server) --------------------
        # NOTE: runs BEFORE the redeem rate-limit burn below, so this
        # redeem still has budget.
        r = run_cli("--conf", str(tmp / "pairing.conf"),
                    "--invites", str(tmp / "invites.json"),
                    "--state", str(tmp / "pairing_state.json"),
                    "invite", "--label", "rl-ingest", "--hub", "127.0.0.1",
                    "--pair-port", str(port))
        tok_rl = parse_invite(re.search(r"Z1\.\S+", r.stdout).group(0))["token"]
        code_, body = c.post("/redeem", {"token": tok_rl, "pubkey": wg_pubkey(),
                                        "platform_id": "rl-mesh"})
        check("rl-mesh redeem -> 200", code_ == 200, f"{code_} {body}")
        itok = body["ingest_token"]
        ev = {"zmeta_version": "1.0", "source": {"platform_id": "rl-mesh"}, "event": {"event_type": "OBSERVATION"}}
        icodes = [c.post_ingest(ev, itok)[0] for _ in range(8)]
        check("ingest under limit -> 202 (500 forward_failed if UDP blocked)",
              icodes[0] in (202, 500), str(icodes))
        check("ingest over 5/min -> 429", 429 in icodes, str(icodes))

        # ---- rate limit --------------------------------------------------
        codes = []
        for _ in range(12):
            st, _ = c.post("/redeem", {"token": "B" * 43, "pubkey": wg_pubkey(),
                                       "platform_id": "rl"})
            codes.append(st)
        check("first attempts not rate-limited", codes[0] == 400, str(codes))
        check("11th+ attempt -> 429", 429 in codes, str(codes))
    finally:
        srv.terminate()
        srv.wait(timeout=10)

    # ---- B1: hub without ingest_url mints NO token -----------------------
    # A hub that never configured ingest_url must return ""/"" and mint
    # nothing — otherwise every join breaks on ingest-less hubs.
    (tmp / "pairing-noingest.conf").write_text(
        f"hub_pubkey={hub_pubkey}\nwg_port=51820\n"
        f"wg_endpoint=127.0.0.1:51820\nwg_interface=wg0\npair_port=0\n"
        f"zmeta_target=10.99.0.1:5555\ncertfp={certfp}\n",
        encoding="utf-8")
    (tmp / "invites2.json").write_text('{"invites": []}', encoding="utf-8")
    (tmp / "state2.json").write_text(
        '{"next_suffix": 11, "allocated": {}, "ingest_tokens": {}}',
        encoding="utf-8")
    srv = subprocess.Popen(
        [sys.executable, "-u", str(SERVER),
         "--conf", str(tmp / "pairing-noingest.conf"),
         "--pair-host", "127.0.0.1", "--pair-port", "0",
         "--wg-config", str(tmp / "wg0.conf"),
         "--peers", str(tmp / "PEERS.md"),
         "--state", str(tmp / "state2.json"),
         "--invites", str(tmp / "invites2.json"),
         "--cert", str(tmp / "pairing.crt"),
         "--key", str(tmp / "pairing.key"),
         "--log", str(tmp / "pairing.log")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        cwd=str(tmp))
    port = None
    deadline = time.time() + 15
    while time.time() < deadline and port is None:
        line = srv.stdout.readline()
        m = re.search(r"https://127\.0\.0\.1:(\d+)/", line or "")
        if m:
            port = int(m.group(1))
    c = Client(port)
    time.sleep(0.3)
    try:
        r = run_cli("--conf", str(tmp / "pairing-noingest.conf"),
                    "--invites", str(tmp / "invites2.json"),
                    "--state", str(tmp / "state2.json"),
                    "invite", "--label", "No Ingest Team", "--hub", "127.0.0.1",
                    "--pair-port", str(port), "--days", "7")
        m = re.search(r"Z1\.\S+", r.stdout)
        check("invite prints a code (no-ingest hub)", m is not None,
              r.stdout[-200:] + r.stderr[-200:])
        invtok = parse_invite(m.group(0))["token"]
        st2_before = json.loads((tmp / "state2.json").read_text())
        n_tok_before = len(st2_before.get("ingest_tokens", {}))
        code_, body = c.post("/redeem", {"token": invtok,
                                        "pubkey": wg_pubkey(),
                                        "platform_id": "no-ingest-mesh"})
        check("redeem on ingest-less hub -> 200", code_ == 200,
              f"{code_} {body}")
        check("ingest_url is empty string",
              body.get("ingest_url") == "", repr(body.get("ingest_url")))
        check("ingest_token is empty string",
              body.get("ingest_token") == "", repr(body.get("ingest_token")))
        st2_after = json.loads((tmp / "state2.json").read_text())
        check("no ingest token minted",
              len(st2_after.get("ingest_tokens", {})) == n_tok_before,
              str(st2_after.get("ingest_tokens", {})))
    finally:
        srv.terminate()
        srv.wait(timeout=10)

    print()
    print(f"{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("FAILED:", FAIL)
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(1)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    import urllib.error  # noqa: E402  (kept here: only needed for Client)
    main()
