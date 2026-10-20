#!/usr/bin/env python3
"""ZMeta pairing server — hub side of the invite-code pairing flow.

A Shepherd mesh redeems a single-use invite code here; the server
validates it and auto-provisions the WireGuard peer + PEERS.md row.

Security controls (unchanged from the manual flow):
  - Invite codes are single-use, expire, and are issued only by the
    hub operator (issuance IS the authorization).
  - Only the sha256 of each token is stored (invites.json).
  - WireGuard still authenticates every peer cryptographically.
  - The gateway must still enforce platform binding
    (tunnel-IP <-> platform_id) on ingest.

Standard library only. Run next to the WireGuard hub:
    python zmeta_pairing_server.py --conf pairing.conf

Redeem API:
    POST https://<hub>:<pair_port>/redeem   {"token","pubkey","platform_id"}
    -> 200 {ok:true, tunnel_ip, hub_pubkey, hub_endpoint,
            zmeta_target, reload_needed, ingest_url, ingest_token}
       (ingest_token is shown ONCE — the mesh stores it; only its
       sha256 is kept hub-side)
    -> 400 {ok:false, error: bad_token|expired|used|bad_platform_id|
                               platform_taken|bad_pubkey|bad_request}
    -> 429 {ok:false, error:"rate_limited"}
    -> 500 {ok:false, error:"provision_failed"}   (invite stays usable)
    -> 500 {ok:false, error:"state_corrupt"}      (pairing_state.json bad)

HTTPS ingest API (no WireGuard needed — for forward-deployed meshes
whose networks allow HTTPS but block UDP / app installs):
    POST <ingest_url>   (same server, path /ingest)
      Authorization: Bearer <ingest_token>
      body: one ZMeta 1.0 event (JSON dict, <=64KB)
    -> 202 {ok:true}   (auth + platform binding passed; forwarded to
                        the gateway's UDP ingest for schema/policy
                        validation)
    -> 401 {ok:false, error:"unauthorized"}  (unknown/revoked token)
    -> 403 {ok:false, error:"platform_mismatch"}
         (event source.platform_id != the token's registered platform_id —
          this is the platform binding for the HTTPS path)
    -> 400 {ok:false, error:"bad_request"}
    -> 429 {ok:false, error:"rate_limited"}  (per token, 120/min)
    -> 500 {ok:false, error:"forward_failed"|"state_corrupt"}
    GET /health -> {"ok":true}

Cloudflare mode: run behind cloudflared with --no-tls (plain HTTP on
loopback only — the server refuses --no-tls on any other interface).
In pairing.conf set certfp=- and hand out invites for the public domain;
the Shepherd app then uses normal public-CA verification instead of
cert pinning. See PAIRING.md "Cloudflare deployment".
"""

import argparse
import base64
import binascii
import datetime as _dt
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import threading
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent

PLATFORM_RE = re.compile(r"^[a-z0-9-]{1,32}$")
BASE_NET = ipaddress.ip_network("10.99.0.0/24")
FIRST_SUFFIX = 11
MAX_SUFFIX = 254
MAX_BODY = 8192
INGEST_BODY_MAX = 65507  # max UDP payload: anything bigger can never
# be forwarded as one datagram, so refuse it up front (N2).

# Rate limit: redeem attempts per source IP per window.
RL_MAX = 10
RL_WINDOW_S = 60.0

# Rate limit: ingest POSTs per token per window (separate bucket so a
# chatty mesh can never starve redeems, and vice versa).
_ingest_rate = {}  # "tok:<hash>" or "ip:<addr>" -> deque[timestamps]
_ingest_rl_lock = threading.Lock()

_state_lock = threading.Lock()
_rl_lock = threading.Lock()
_rate = {}  # ip -> deque[timestamps]


def utcnow():
    return _dt.datetime.now(_dt.timezone.utc)


def utcstamp():
    return utcnow().isoformat(timespec="seconds")


def log_line(log_path, msg):
    line = f"{utcstamp()} {msg}"
    print(line, flush=True)
    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def read_conf(path):
    """Parse simple KEY=VALUE config (ignores # comments / blanks)."""
    cfg = {}
    p = Path(path)
    if not p.is_file():
        return cfg
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def load_json(path, default):
    p = Path(path)
    if not p.is_file():
        return default
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, ValueError):
        return default


def save_json(path, obj):
    tmp = str(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def valid_pubkey(pubkey):
    """WireGuard public key: 44 chars, standard base64, decodes to 32 bytes."""
    if not isinstance(pubkey, str) or len(pubkey) != 44:
        return False
    try:
        raw = base64.b64decode(pubkey, validate=True)
    except (binascii.Error, ValueError):
        return False
    return len(raw) == 32


def valid_ingest_token(token):
    """HTTPS ingest bearer: 43 chars, base64url, no padding (32 bytes)."""
    if not isinstance(token, str) or len(token) != 43:
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9_-]{43}", token))


RL_MAX_KEYS = 10000


def _prune_buckets(table, now):
    """Drop idle buckets so a spray of source IPs / well-formed random
    tokens cannot grow the table without bound. Caller holds the lock."""
    for k in [k for k, dq in table.items()
              if not dq or now - dq[-1] > RL_WINDOW_S]:
        del table[k]


def check_rate(ip):
    now = utcnow().timestamp()
    with _rl_lock:
        if len(_rate) > RL_MAX_KEYS:
            _prune_buckets(_rate, now)
        dq = _rate.get(ip)
        if dq is None:
            dq = _rate[ip] = deque()
        while dq and now - dq[0] > RL_WINDOW_S:
            dq.popleft()
        if not dq:
            # Idle past the window: drop the bucket so a spray of source
            # IPs can't grow memory unboundedly.
            _rate.pop(ip, None)
            dq = _rate[ip] = deque()
        if len(dq) >= RL_MAX:
            return False
        dq.append(now)
        return True


def check_ingest_rate(key, max_per_min):
    """Per-token (or per-IP fallback) ingest rate limit. Separate bucket
    from redeem so a chatty mesh can never starve pairings."""
    now = utcnow().timestamp()
    with _ingest_rl_lock:
        if len(_ingest_rate) > RL_MAX_KEYS:
            _prune_buckets(_ingest_rate, now)
        dq = _ingest_rate.get(key)
        if dq is None:
            dq = _ingest_rate[key] = deque()
        while dq and now - dq[0] > RL_WINDOW_S:
            dq.popleft()
        if not dq:
            _ingest_rate.pop(key, None)
            dq = _ingest_rate[key] = deque()
        if len(dq) >= max_per_min:
            return False
        dq.append(now)
        return True


def event_platform_id(body):
    """The platform_id the GATEWAY will attribute an event to:
    ZMeta 1.0 events carry it at source.platform_id. Binding is checked
    against exactly this field (never a top-level lookalike), so a mesh
    cannot pass the check with one value while the gateway reads another."""
    src = body.get("source") if isinstance(body, dict) else None
    if isinstance(src, dict):
        pid = src.get("platform_id")
        if isinstance(pid, str):
            return pid
    return None


def bearer_token(auth_header):
    """Extract a Bearer token from an Authorization header (or None)."""
    if not isinstance(auth_header, str):
        return None
    scheme, _, cred = auth_header.partition(" ")
    if scheme.lower() == "bearer" and cred.strip():
        return cred.strip()
    return None


def mint_ingest_token():
    """A long-lived HTTPS-ingest credential: 32 random bytes, base64url
    no padding (43 chars). Only its sha256 is ever stored."""
    raw = secrets.token_bytes(32)
    token = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    return token, token_hash(token)


# --------------------------------------------------------------------------
# Cross-process file lock (S1)
# --------------------------------------------------------------------------

def lock_path_for(state_path):
    """Lockfile shared by the server and the CLI: <state>.lock.

    Both programs default --state to the same path, so they serialize
    on the same lockfile."""
    return str(state_path) + ".lock"


def _is_loopback(host):
    """True when host parses as an IP loopback address (127.0.0.1, ::1,
    or the rest of 127/8). Used to gate --no-tls."""
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class FileLock:
    """Exclusive cross-process lock via a lockfile.

    POSIX: fcntl.flock(LOCK_EX). Windows: msvcrt.locking on byte 0.
    The lock is always released when the process dies (handles close),
    so a blocking acquire cannot deadlock forever."""

    def __init__(self, path):
        self._path = path
        self._fh = None

    def __enter__(self):
        fh = open(self._path, "a+b")
        fh.seek(0, os.SEEK_END)
        if fh.tell() == 0:  # msvcrt needs at least 1 byte to lock
            fh.write(b"\x00")
            fh.flush()
        fh.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(fh.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        self._fh = fh
        return self

    def __exit__(self, exc_type, exc, tb):
        try:
            if os.name == "nt":
                import msvcrt
                self._fh.seek(0)
                msvcrt.locking(self._fh.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
        finally:
            self._fh.close()
            self._fh = None
        return False


# --------------------------------------------------------------------------
# WireGuard config + PEERS.md surgery
# --------------------------------------------------------------------------

def append_wg_peer(wg_conf, pubkey, tunnel_ip, platform_id, label):
    """Append a [Peer] block. Returns True on success."""
    block = (
        f"\n# --- {platform_id} (paired {utcstamp()}, invite: {label}) ---\n"
        "[Peer]\n"
        f"PublicKey = {pubkey}\n"
        f"AllowedIPs = {tunnel_ip}/32\n"
    )
    try:
        with open(wg_conf, "a", encoding="utf-8") as f:
            f.write(block)
        return True
    except OSError:
        return False


def _rollback_wg_append(wg_conf, platform_id, tunnel_ip):
    """Best-effort rollback of a just-appended [Peer] block after a
    partial provisioning failure (S3). Only truncates when the file tail
    is exactly the block append_wg_peer wrote — never touches anything
    else. Returns True if rolled back."""
    marker = f"# --- {platform_id} (paired "
    try:
        p = Path(wg_conf)
        text = p.read_text(encoding="utf-8")
        idx = text.rfind(marker)
        if idx == -1:
            return False
        tail = text[idx:]
        if tail.count("[Peer]") != 1:
            return False
        if not tail.rstrip("\n").endswith(f"AllowedIPs = {tunnel_ip}/32"):
            return False
        p.write_text(text[:idx].rstrip("\n") + "\n", encoding="utf-8")
        return True
    except OSError:
        return False


def append_peers_row(peers_path, tunnel_ip, pubkey, platform_id, label):
    """Append a row to the PEERS.md markdown table."""
    row = (f"| {tunnel_ip} | {pubkey[:16]}… | {platform_id} | {label} |"
           f"  |  |  |  | {utcnow().date().isoformat()} |\n")
    p = Path(peers_path)
    try:
        text = p.read_text(encoding="utf-8") if p.is_file() else (
            "# Peer registry (gateway operator keeps this)\n\n"
            "| Tunnel IP | Mesh public key (first 16 chars…) | platform_id |"
            " Party / unit | lat | lon | alt_m (MSL*) | Position updated (UTC) | Added |\n"
            "|---|---|---|---|---|---|---|---|---|\n")
    except OSError:
        return False
    lines = text.splitlines(keepends=True)
    # insert after the last table row (last line starting with '|')
    idx = -1
    for k, ln in enumerate(lines):
        if ln.startswith("|"):
            idx = k
    if idx >= 0:
        lines.insert(idx + 1, row)
    else:
        lines.append(row)
    try:
        p.write_text("".join(lines), encoding="utf-8")
        return True
    except OSError:
        return False


def wg_live_reload(wg_conf, interface):
    """Apply wg0.conf to the running interface. Returns True on success.

    `wg syncconf` rejects wg-quick-only keys (Address, DNS, PostUp...), and
    the shipped gateway conf has `Address =`, so feeding it the raw file
    always failed and every pairing/revoke silently fell back to "reactivate
    manually" (leaving a revoked key live until someone did). Strip it with
    `wg-quick strip` first; wg-quick wants an interface-named file, hence
    the temp copy."""
    import tempfile
    wg = shutil.which("wg")
    wgq = shutil.which("wg-quick")
    if not wg or not wgq:
        return False
    try:
        with tempfile.TemporaryDirectory() as td:
            named = Path(td) / f"{interface}.conf"
            named.write_text(Path(wg_conf).read_text(encoding="utf-8"),
                             encoding="utf-8")
            os.chmod(named, 0o600)
            stripped = subprocess.run([wgq, "strip", str(named)],
                                      capture_output=True, timeout=15)
            if stripped.returncode != 0:
                return False
            out = Path(td) / "stripped.conf"
            out.write_bytes(stripped.stdout)
            os.chmod(out, 0o600)
            r = subprocess.run([wg, "syncconf", interface, str(out)],
                               capture_output=True, timeout=15)
            return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def try_wg_reload(wg_conf, interface):
    """Try a live reload (Linux hub). Returns True if it applied."""
    return wg_live_reload(wg_conf, interface)


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "ZMetaPair/1.0"
    cfg = {}          # filled by main()
    paths = {}        # filled by main()
    log_path = None   # filled by main()

    def log_message(self, fmt, *args):  # quieter logs
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _client_ip(self):
        peer = self.client_address[0] if self.client_address else "?"
        # Behind cloudflared every request arrives from loopback, which
        # would collapse all per-IP rate limits into ONE shared bucket (a
        # single client could lock everyone out of pairing). Trust
        # CF-Connecting-IP only when the TCP peer is loopback, i.e. the
        # local tunnel daemon — never from a direct remote connection.
        if _is_loopback(peer):
            cf = (self.headers.get("CF-Connecting-IP", "") or "").strip()
            try:
                return str(ipaddress.ip_address(cf))
            except ValueError:
                pass
        return peer

    def do_GET(self):
        if urlparse(self.path).path == "/health":
            self._send(200, {"ok": True})
            return
        self._send(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/redeem":
            self._handle_redeem()
        elif path in ("/ingest", "/zmeta/ingest"):
            self._handle_ingest()
        else:
            self._send(404, {"ok": False, "error": "not_found"})

    def _handle_redeem(self):
        ip = self._client_ip()
        if not check_rate(ip):
            log_line(self.log_path, f"redeem 429 rate_limited from {ip}")
            self._send(429, {"ok": False, "error": "rate_limited"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._send(400, {"ok": False, "error": "bad_request"})
            return
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
            self._send(400, {"ok": False, "error": "bad_request"})
            return
        if not isinstance(body, dict):
            self._send(400, {"ok": False, "error": "bad_request"})
            return
        result, code = self.server.redeem(body)
        log_line(self.log_path,
                 f"redeem {code} {result.get('error', 'ok')} from {ip}")
        self._send(code, result)

    def _handle_ingest(self):
        """HTTPS event ingest (no WireGuard): Bearer auth, per-token rate
        limit, then platform binding + forward to the gateway's UDP."""
        ip = self._client_ip()
        token = bearer_token(self.headers.get("Authorization", ""))
        # Rate-limit key: the token's hash ONLY for well-formed tokens;
        # malformed/missing auth falls back to the shared per-IP bucket
        # (so garbage can't mint unlimited per-key buckets).
        rl_key = ("tok:" + token_hash(token)) if valid_ingest_token(token) \
            else ("ip:" + ip)
        try:
            max_pm = int(self.cfg.get("ingest_rate_per_min", 120))
        except (TypeError, ValueError):
            max_pm = 120
        if not check_ingest_rate(rl_key, max_pm):
            log_line(self.log_path, f"ingest 429 rate_limited from {ip}")
            self._send(429, {"ok": False, "error": "rate_limited"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > INGEST_BODY_MAX:
            self._send(400, {"ok": False, "error": "bad_request"})
            return
        try:
            raw = self.rfile.read(length)
            body = json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
            self._send(400, {"ok": False, "error": "bad_request"})
            return
        if not isinstance(body, dict):
            self._send(400, {"ok": False, "error": "bad_request"})
            return
        result, code = self.server.ingest(raw, body,
                                          self.headers.get("Authorization", ""),
                                          ip)
        self._send(code, result)


class PairingServer(ThreadingHTTPServer):
    """HTTP server with the redeem business logic (all state under a lock)."""

    def __init__(self, addr, handler, cfg, paths, log_path,
                 bind_and_activate=True):
        self.cfg = cfg
        self.paths = paths
        self.log_path = log_path
        handler.cfg = cfg
        handler.paths = paths
        handler.log_path = log_path
        super().__init__(addr, handler,
                         bind_and_activate=bind_and_activate)

    # -- state helpers -------------------------------------------------
    def _load_invites(self):
        return load_json(self.paths["invites"], {"invites": []})

    def _save_invites(self, obj):
        save_json(self.paths["invites"], obj)

    def _load_state(self):
        """Load pairing_state.json, validating its shape (N5).

        Returns the state dict, or None when the file is corrupt —
        callers must fail closed (HTTP 500), never raise mid-redeem."""
        st = load_json(self.paths["state"],
                       {"allocated": {}, "next_suffix": FIRST_SUFFIX,
                        "ingest_tokens": {}})
        if not isinstance(st, dict):
            return None
        allocated = st.get("allocated", {})
        nxt = st.get("next_suffix", FIRST_SUFFIX)
        ingest_tokens = st.get("ingest_tokens", {})
        # next_suffix must be a real int (bool is an int subclass: exclude
        # it) inside the usable range. Corrupt file -> fail closed.
        if not isinstance(allocated, dict):
            return None
        if isinstance(nxt, bool) or not isinstance(nxt, int):
            return None
        if not (FIRST_SUFFIX <= nxt <= MAX_SUFFIX + 1):
            return None
        for rec in allocated.values():
            if not isinstance(rec, dict):
                return None
        if not isinstance(ingest_tokens, dict):
            return None
        for rec in ingest_tokens.values():
            if not isinstance(rec, dict):
                return None
        st["allocated"] = allocated
        st["next_suffix"] = nxt
        st["ingest_tokens"] = ingest_tokens
        return st

    def _save_state(self, obj):
        save_json(self.paths["state"], obj)

    # -- redeem ---------------------------------------------------------
    def redeem(self, body):
        token = body.get("token")
        pubkey = body.get("pubkey")
        platform_id = body.get("platform_id")

        # S1: cross-process file lock (shared with zmeta_invite.py) wraps
        # the whole load -> validate -> provision -> save sequence, so two
        # redeems (or a CLI revoke) can never interleave mid-write.
        # The file lock is always acquired OUTSIDE the thread lock, in
        # this order, to avoid lock-order inversion.
        with FileLock(lock_path_for(self.paths["state"])):
            with _state_lock:
                invites = self._load_invites()
                inv = None
                if isinstance(token, str) and token:
                    th = token_hash(token)
                    for cand in invites.get("invites", []):
                        if hmac.compare_digest(cand.get("token_hash", ""), th):
                            inv = cand
                            break
                if inv is None:
                    return {"ok": False, "error": "bad_token"}, 400
                # S2: unparseable or missing expires_utc is EXPIRED (fail
                # closed) — an invite must never become immortal.
                exp_dt = None
                exp = inv.get("expires_utc")
                if isinstance(exp, str) and exp:
                    try:
                        exp_dt = _dt.datetime.fromisoformat(exp)
                        if exp_dt.tzinfo is None:
                            exp_dt = exp_dt.replace(tzinfo=_dt.timezone.utc)
                    except ValueError:
                        exp_dt = None
                if exp_dt is None or utcnow() > exp_dt:
                    return {"ok": False, "error": "expired"}, 400
                if inv.get("used"):
                    return {"ok": False, "error": "used"}, 400
                if not isinstance(platform_id, str) or not PLATFORM_RE.match(platform_id):
                    return {"ok": False, "error": "bad_platform_id"}, 400

                # N5: corrupt state fails closed (HTTP 500), never raises.
                state = self._load_state()
                if state is None:
                    log_line(self.log_path,
                             "pairing_state.json is corrupt; refusing redeem "
                             "(fail closed)")
                    return {"ok": False, "error": "state_corrupt"}, 500
                for ip_addr, rec in state["allocated"].items():
                    if rec.get("platform_id") == platform_id and not rec.get("revoked"):
                        return {"ok": False, "error": "platform_taken"}, 400
                if not valid_pubkey(pubkey):
                    return {"ok": False, "error": "bad_pubkey"}, 400

                suffix = state["next_suffix"]
                if suffix > MAX_SUFFIX:
                    return {"ok": False, "error": "pool_exhausted"}, 400
                tunnel_ip = f"10.99.0.{suffix}"

                # S3: provision FIRST, commit state only when BOTH writes
                # landed. On partial failure the invite stays usable and
                # we answer 500 (provision_failed), never 200.
                label = inv.get("label", "")
                ok_wg = append_wg_peer(self.paths["wg_config"], pubkey,
                                       tunnel_ip, platform_id, label)
                ok_peers = (ok_wg and append_peers_row(
                    self.paths["peers"], tunnel_ip, pubkey, platform_id, label))
                if not (ok_wg and ok_peers):
                    if ok_wg:
                        _rollback_wg_append(self.paths["wg_config"],
                                           platform_id, tunnel_ip)
                    log_line(self.log_path,
                             f"provision_failed for {platform_id} ({tunnel_ip}): "
                             f"wg_config ok={ok_wg}, PEERS.md ok={ok_peers}")
                    return {"ok": False, "error": "provision_failed"}, 500

                state["next_suffix"] = suffix + 1
                state["allocated"][tunnel_ip] = {
                    "platform_id": platform_id,
                    "pubkey": pubkey,
                    "label": label,
                    "added_utc": utcstamp(),
                    "revoked": False,
                    "revoked_utc": None,
                }
                # Mint the HTTPS-ingest credential alongside the WireGuard
                # peer (dual-mode) — but ONLY when the hub actually
                # configured an ingest_url. Minting a token nobody can
                # use would break every join on ingest-less hubs.
                ingest_url = (self.cfg.get("ingest_url", "") or "").strip()
                ingest_token = ""
                if ingest_url:
                    ingest_token, ingest_th = mint_ingest_token()
                    state.setdefault("ingest_tokens", {})[ingest_th] = {
                        "platform_id": platform_id,
                        "created_utc": utcstamp(),
                        "revoked": False,
                        "revoked_utc": None,
                    }
                inv["used"] = True
                inv["used_by"] = platform_id
                inv["used_utc"] = utcstamp()
                self._save_invites(invites)
                self._save_state(state)

                reloaded = try_wg_reload(self.paths["wg_config"],
                                         self.cfg.get("wg_interface", "wg0"))
                reload_needed = not reloaded
                if reloaded:
                    log_line(self.log_path,
                             f"wg syncconf applied for {platform_id} ({tunnel_ip})")
                else:
                    log_line(self.log_path,
                             f"pair {platform_id} -> {tunnel_ip}; "
                             "reactivate the tunnel in the WireGuard app")

                return {"ok": True,
                        "tunnel_ip": tunnel_ip,
                        "hub_pubkey": self.cfg.get("hub_pubkey", ""),
                        "hub_endpoint": self.cfg.get("wg_endpoint", ""),
                        "zmeta_target": self.cfg.get("zmeta_target", "10.99.0.1:5555"),
                        "reload_needed": reload_needed,
                        "ingest_url": ingest_url,
                        "ingest_token": ingest_token}, 200

    # -- ingest ---------------------------------------------------------
    def ingest(self, raw, body, auth_header, ip):
        """HTTPS event ingest: Bearer auth, platform binding, forward.

        This endpoint is auth + binding + forward ONLY. The gateway
        still does all schema/policy validation on the forwarded
        datagram. The token itself is never logged (hash prefix only).
        """
        token = bearer_token(auth_header)
        # Same lock order as redeem(): file lock outside the thread lock.
        with FileLock(lock_path_for(self.paths["state"])):
            with _state_lock:
                state = self._load_state()
                if state is None:
                    log_line(self.log_path,
                             "pairing_state.json is corrupt; ingest refused "
                             "(fail closed)")
                    return {"ok": False, "error": "state_corrupt"}, 500
                th = token_hash(token) if token else None
                rec = None
                if th:
                    for cand_hash, cand in state.get("ingest_tokens", {}).items():
                        if hmac.compare_digest(cand_hash, th):
                            rec = cand
                            break
                if rec is None or rec.get("revoked"):
                    # N1: log 401s like the 403s — token itself never
                    # logged, hash prefix at most.
                    log_line(self.log_path,
                             f"ingest 401 unauthorized "
                             f"tok={th[:8] if th else '-'} from {ip}")
                    return {"ok": False, "error": "unauthorized"}, 401
                platform_id = rec.get("platform_id", "")
                # Platform binding for the HTTPS path: the event's
                # platform_id must equal the token's registered
                # platform_id. (WireGuard path binds via tunnel IP.)
                got_pid = event_platform_id(body)
                if got_pid != platform_id:
                    log_line(self.log_path,
                             f"ingest 403 platform_mismatch tok={th[:8]} "
                             f"expected={platform_id} "
                             f"got={got_pid!r}")
                    return {"ok": False, "error": "platform_mismatch"}, 403
                try:
                    gw_host = self.cfg.get("gateway_host", "127.0.0.1")
                    gw_port = int(self.cfg.get("gateway_port", 5555))
                    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    try:
                        sock.sendto(raw, (gw_host, gw_port))
                    finally:
                        sock.close()
                except (OSError, ValueError) as e:
                    log_line(self.log_path,
                             f"ingest forward_failed tok={th[:8]} "
                             f"platform={platform_id}: {e}")
                    return {"ok": False, "error": "forward_failed"}, 500
                log_line(self.log_path,
                         f"ingest 202 tok={th[:8]} platform={platform_id} "
                         f"bytes={len(raw)}")
                return {"ok": True}, 202


def main():
    ap = argparse.ArgumentParser(description="ZMeta pairing server (hub side)")
    ap.add_argument("--conf", default=str(SCRIPT_DIR / "pairing.conf"))
    ap.add_argument("--pair-host", default="0.0.0.0")
    ap.add_argument("--pair-port", type=int, default=8443)
    ap.add_argument("--wg-config", default=str(SCRIPT_DIR / "wg0.conf"))
    ap.add_argument("--peers", default=str(SCRIPT_DIR / "PEERS.md"))
    ap.add_argument("--state", default=str(SCRIPT_DIR / "pairing_state.json"))
    ap.add_argument("--invites", default=str(SCRIPT_DIR / "invites.json"))
    ap.add_argument("--cert", default=str(SCRIPT_DIR / "pairing.crt"))
    ap.add_argument("--key", default=str(SCRIPT_DIR / "pairing.key"))
    ap.add_argument("--hub-pubkey", default="")
    ap.add_argument("--wg-endpoint", default="")
    ap.add_argument("--wg-interface", default="wg0")
    ap.add_argument("--zmeta-target", default="10.99.0.1:5555")
    ap.add_argument("--ingest-url", default="",
                    help="public HTTPS ingest URL handed to meshes at redeem "
                         "(e.g. https://pair.example.com/zmeta/ingest)")
    ap.add_argument("--gateway-host", default="127.0.0.1",
                    help="gateway UDP ingest host (forward target for /ingest)")
    ap.add_argument("--gateway-port", type=int, default=5555,
                    help="gateway UDP ingest port (forward target for /ingest)")
    ap.add_argument("--ingest-rate-per-min", type=int, default=120,
                    help="max /ingest POSTs per token per minute")
    ap.add_argument("--log", default=str(SCRIPT_DIR / "pairing.log"))
    ap.add_argument("--no-tls", action="store_true",
                    help="serve plain HTTP (for use behind cloudflared, which "
                         "terminates TLS at the edge). Only allowed when "
                         "--pair-host is a loopback address.")
    args = ap.parse_args()

    cfg = read_conf(args.conf)
    # Explicit CLI args win over pairing.conf.
    for k, attr in (("hub_pubkey", "hub_pubkey"), ("wg_endpoint", "wg_endpoint"),
                    ("zmeta_target", "zmeta_target"),
                    ("wg_interface", "wg_interface"),
                    ("ingest_url", "ingest_url"),
                    ("gateway_host", "gateway_host"),
                    ("gateway_port", "gateway_port"),
                    ("ingest_rate_per_min", "ingest_rate_per_min")):
        if getattr(args, attr):
            cfg[k] = getattr(args, attr)
    cfg.setdefault("pair_port", str(args.pair_port))

    # Item 16: --no-tls is only for loopback-behind-cloudflared. Refuse
    # to serve the token-bearing API in cleartext on a real interface.
    use_tls = not args.no_tls
    if not use_tls and not _is_loopback(args.pair_host):
        print(f"Refusing --no-tls on non-loopback --pair-host "
              f"({args.pair_host}). Bind to 127.0.0.1 (e.g. behind "
              f"cloudflared) or drop --no-tls.", file=sys.stderr)
        sys.exit(2)

    if use_tls:
        for need, val in (("--cert", args.cert), ("--key", args.key)):
            if not Path(val).is_file():
                print(f"Missing {need} file: {val}\nRun SETUP_PAIRING.bat first.", file=sys.stderr)
                sys.exit(2)
    # N7: hub_pubkey must be a real WireGuard public key (44-char strict
    # base64 decoding to 32 bytes) — it is echoed to every mesh, so a
    # typo here would hand out a broken config. Refuse to start.
    if not valid_pubkey(cfg.get("hub_pubkey", "")):
        print("hub_pubkey is missing or invalid (pairing.conf or --hub-pubkey): "
              "must be 44-char base64 decoding to 32 bytes.", file=sys.stderr)
        sys.exit(2)

    paths = {"wg_config": args.wg_config, "peers": args.peers,
             "state": args.state, "invites": args.invites}
    srv = PairingServer((args.pair_host, args.pair_port), Handler, cfg, paths,
                        args.log, bind_and_activate=False)
    if use_tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        try:
            ctx.load_cert_chain(args.cert, args.key)
            srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        except Exception as e:
            print(f"TLS setup failed: {e}", file=sys.stderr)
            sys.exit(2)
    try:
        srv.server_bind()
        srv.server_activate()
    except OSError as e:
        print(f"Could not bind {args.pair_host}:{args.pair_port}: {e}", file=sys.stderr)
        sys.exit(2)

    scheme = "https" if use_tls else "http"
    log_line(args.log, f"pairing server on {scheme}://{args.pair_host}:{args.pair_port} "
                       f"(wg {args.wg_config}, peers {args.peers})")
    if not use_tls:
        # Loud line: the operator must know tokens travel in cleartext
        # on loopback only, with TLS terminated upstream.
        log_line(args.log, "TLS terminated upstream (Cloudflare); "
                           "bound to loopback only.")
    bound_port = srv.server_address[1]
    print(f"Pairing server: {scheme}://{args.pair_host}:{bound_port}/")
    print("Ctrl+C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
