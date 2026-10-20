#!/usr/bin/env python3
"""zmeta_invite.py — hub operator CLI for ZMeta invite-code pairing.

    python zmeta_invite.py invite --label "3rd Platoon" --hub hub.example.com [--days 7]
    python zmeta_invite.py list
    python zmeta_invite.py revoke shepherd-mesh-a
    python zmeta_invite.py prune

Invite codes look like:
    Z1.<hub_host>.<pair_port>.<wg_port>.<token_b64url>.<certfp_hex>
Hand the whole string to the mesh operator; they paste it into
Shepherd -> Settings -> ZMeta export -> "Join network".

Standard library only.
"""

import argparse
import base64
import datetime as _dt
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def utcnow():
    return _dt.datetime.now(_dt.timezone.utc)


def utcstamp():
    return utcnow().isoformat(timespec="seconds")


def read_conf(path):
    cfg = {}
    p = Path(path)
    if p.is_file():
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


def b64u_nopad(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


# --------------------------------------------------------------------------
# Cross-process file lock (S1) — shared with zmeta_pairing_server.py.
# --------------------------------------------------------------------------

def lock_path_for(state_path):
    """Lockfile shared by the server and the CLI: <state>.lock."""
    return str(state_path) + ".lock"


class FileLock:
    """Exclusive cross-process lock via a lockfile.

    POSIX: fcntl.flock(LOCK_EX). Windows: msvcrt.locking on byte 0."""

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


def sanitize_label(label):
    """S4: labels land in wg0.conf comments and PEERS.md rows — strip
    newlines/control chars (config-injection surface) and cap at 64."""
    clean = re.sub(r"[\x00-\x1f\x7f]", " ", label or "")
    clean = " ".join(clean.split())
    return clean[:64]


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


# ---------------------------------------------------------------- invite ---

def cmd_invite(args, cfg):
    pair_port = args.pair_port or int(cfg.get("pair_port", "8443"))
    wg_port = args.wg_port or int(cfg.get("wg_port", "51820"))
    # certfp lives under "certfp" in pairing.conf; accept the spelled-out
    # alias too. "-" = Cloudflare mode (public-CA trust, no pinning).
    certfp = cfg.get("certfp", "") or cfg.get("cert_fingerprint", "")
    if not (certfp == "-" or re.fullmatch(r"[0-9a-f]{64}", certfp or "")):
        print("pairing.conf needs certfp: 64 hex chars (direct pin mode) "
              "or '-' (Cloudflare mode). Run SETUP_PAIRING.bat first.",
              file=sys.stderr)
        sys.exit(2)

    label = sanitize_label(args.label)

    token_raw = secrets.token_bytes(32)
    token = b64u_nopad(token_raw)  # 43 chars
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    days = args.days if args.days is not None else 7
    expires = utcnow() + _dt.timedelta(days=days)

    invites_path = args.invites
    with FileLock(lock_path_for(args.state)):
        data = load_json(invites_path, {"invites": []})
        data.setdefault("invites", []).append({
            "token_hash": token_hash,
            "label": label,
            "created_utc": utcstamp(),
            "expires_utc": expires.isoformat(timespec="seconds"),
            "used": False,
            "used_by": None,
            "used_utc": None,
        })
        save_json(invites_path, data)

    code = f"Z1.{args.hub}.{pair_port}.{wg_port}.{token}.{certfp}"
    print()
    print("Invite code (single-use, expires "
          f"{expires.date().isoformat()}):")
    print()
    print(code)
    print()
    print(f"Label: {label}")
    print("Hand the whole line to the mesh operator. They paste it into")
    print("Shepherd -> Settings -> ZMeta export -> \"Join network\",")
    print("or scan it as a QR code from the same dialog.")
    print()
    _print_qr(code)


def _print_qr(code):
    """Best-effort ASCII QR of the invite code, for the app's camera
    scanner. Uses the optional `qrcode` pip package; without it this
    prints a one-line hint and the text code above remains the path."""
    try:
        import qrcode  # type: ignore
        qr = qrcode.QRCode(border=2)
        qr.add_data(code)
        qr.make()
        qr.print_ascii(invert=True)
    except Exception:
        # ImportError (package absent) or a console that can't render
        # the block characters (legacy Windows code pages raise
        # UnicodeEncodeError) — the invite already exists and the text
        # code above is the fallback path. Never fail the command here.
        print("(Tip: `pip install qrcode` lets this tool also print a "
              "scannable QR code.)")
    print()


# ------------------------------------------------------------------ list ---

def cmd_list(args):
    with FileLock(lock_path_for(args.state)):
        invites = load_json(args.invites, {"invites": []}).get("invites", [])
        full_state = load_json(args.state, {"allocated": {}})
        state = full_state.get("allocated", {})
        ingest_tokens = full_state.get("ingest_tokens", {})

    def token_status(platform_id):
        """active / revoked / none — never the token itself."""
        found = None
        for trec in ingest_tokens.values():
            if isinstance(trec, dict) and trec.get("platform_id") == platform_id:
                found = "revoked" if trec.get("revoked") else "active"
        return found or "none"

    print("=== Invites ===")
    if not invites:
        print("  (none)")
    for inv in invites:
        status = "used by " + inv["used_by"] if inv.get("used") else "OPEN"
        print(f"  [{status}] {inv.get('label','')} "
              f"created {inv.get('created_utc','?')} "
              f"expires {inv.get('expires_utc','?')}")

    print("=== Paired meshes ===")
    if not state:
        print("  (none)")
    for ip_addr in sorted(state,
                          key=lambda x: tuple(int(p) for p in x.split("."))):
        rec = state[ip_addr]
        flag = "REVOKED" if rec.get("revoked") else "active"
        print(f"  {ip_addr}  {rec.get('platform_id','?')}  [{flag}]  "
              f"[ingest:{token_status(rec.get('platform_id',''))}]  "
              f"{rec.get('label','')}")


# ---------------------------------------------------------------- revoke ---

def cmd_revoke(args):
    platform_id = args.platform_id
    state_path = args.state

    # S1: hold the shared lock for the whole revoke so a concurrent
    # redeem can never interleave with the state read-modify-write.
    with FileLock(lock_path_for(args.state)):
        state = load_json(state_path, {"allocated": {}})
        allocated = state.get("allocated", {})

        target_ip = None
        pubkey = None
        for ip_addr, rec in allocated.items():
            if rec.get("platform_id") == platform_id and not rec.get("revoked"):
                target_ip = ip_addr
                pubkey = rec.get("pubkey")
                break
        if target_ip is None:
            print(f"No active pairing for platform_id '{platform_id}'.",
                  file=sys.stderr)
            sys.exit(1)

        # 1) Remove the [Peer] block from the WireGuard config.
        wg_path = Path(args.wg_config)
        removed = False
        if wg_path.is_file():
            lines = wg_path.read_text(encoding="utf-8").splitlines(keepends=True)
            out, i, n = [], 0, len(lines)
            while i < n:
                if lines[i].strip() == "[Peer]":
                    j = i
                    hit = False
                    while j < n:
                        s = lines[j].strip()
                        if j > i and s in ("[Peer]", "[Interface]"):
                            break
                        if s.startswith("PublicKey"):
                            _, _, val = s.partition("=")
                            if val.strip() == pubkey:
                                hit = True
                        j += 1
                    if hit:
                        removed = True
                        if out and out[-1].strip().startswith("# --- ") and "paired" in out[-1]:
                            out.pop()
                        i = j
                        continue
                    out.extend(lines[i:j])
                    i = j
                else:
                    out.append(lines[i])
                    i += 1
            if removed:
                wg_path.write_text("".join(out), encoding="utf-8")

        # 2) Mark the state revoked (IP is never reused).
        allocated[target_ip]["revoked"] = True
        allocated[target_ip]["revoked_utc"] = utcstamp()
        # 2b) Revoke this platform's HTTPS ingest token(s) too — every
        # non-revoked token bound to the platform_id dies with it.
        ingest_tokens = state.get("ingest_tokens", {})
        n_tok = 0
        for trec in ingest_tokens.values():
            if isinstance(trec, dict) and trec.get("platform_id") == platform_id \
                    and not trec.get("revoked"):
                trec["revoked"] = True
                trec["revoked_utc"] = utcstamp()
                n_tok += 1
        save_json(state_path, state)

        # 3) Mark the PEERS.md row REVOKED.
        peers_path = Path(args.peers)
        if peers_path.is_file():
            lines = peers_path.read_text(encoding="utf-8").splitlines(keepends=True)
            for k, ln in enumerate(lines):
                if not ln.startswith("|"):
                    continue
                cells = [c.strip() for c in ln.strip().strip("|").split("|")]
                if len(cells) >= 3 and cells[2] == platform_id and "REVOKED" not in ln:
                    cells[3] = (cells[3] + f" — REVOKED {utcstamp()}").strip(" ")
                    lines[k] = "| " + " | ".join(cells) + " |\n"
            peers_path.write_text("".join(lines), encoding="utf-8")

    # 4) Try a live reload (Linux hub); otherwise the operator reactivates.
    reloaded = wg_live_reload(args.wg_config, args.wg_interface) if removed else False

    print(f"Revoked {platform_id} ({target_ip}).")
    if n_tok:
        print(f"HTTPS ingest token(s) revoked: {n_tok}.")
    if reloaded:
        print("WireGuard config reloaded live.")
    else:
        print("NOTE: reactivate the tunnel in the WireGuard app for the "
              "change to take effect.")
    print("The mesh's old key stops working immediately once reloaded.")


# ----------------------------------------------------------------- prune ---

def _invite_expired(inv, now):
    """True when the invite is used up or past its expiry. Unparseable or
    missing expires_utc counts as expired (fail closed, same as S2)."""
    if inv.get("used"):
        return True
    exp = inv.get("expires_utc")
    if not isinstance(exp, str) or not exp:
        return True
    try:
        exp_dt = _dt.datetime.fromisoformat(exp)
        if exp_dt.tzinfo is None:
            exp_dt = exp_dt.replace(tzinfo=_dt.timezone.utc)
    except ValueError:
        return True
    return now > exp_dt


def cmd_prune(args):
    """N6: drop used/expired invites from invites.json. Report the count."""
    now = utcnow()
    with FileLock(lock_path_for(args.state)):
        data = load_json(args.invites, {"invites": []})
        invites = data.get("invites", [])
        kept = [inv for inv in invites if not _invite_expired(inv, now)]
        dropped = len(invites) - len(kept)
        data["invites"] = kept
        save_json(args.invites, data)

        # N3: also drop revoked ingest tokens past the audit retention
        # window (30 days). Recent revocations stay for the operator's
        # records; unparseable revoked_utc is kept (fail closed).
        state = load_json(args.state, {})
        toks = state.get("ingest_tokens", {})
        dropped_tok = 0
        if isinstance(toks, dict):
            cutoff = now - _dt.timedelta(days=30)
            for th in list(toks.keys()):
                rec = toks[th]
                if not isinstance(rec, dict) or not rec.get("revoked"):
                    continue
                ru = rec.get("revoked_utc")
                try:
                    rdt = _dt.datetime.fromisoformat(ru)
                    if rdt.tzinfo is None:
                        rdt = rdt.replace(tzinfo=_dt.timezone.utc)
                except (ValueError, TypeError):
                    continue
                if rdt < cutoff:
                    del toks[th]
                    dropped_tok += 1
            save_json(args.state, state)
    print(f"Pruned {dropped} invite(s); {len(kept)} open invite(s) remain.")
    if dropped_tok:
        print(f"Pruned {dropped_tok} revoked ingest token(s) "
              f"(older than 30 days).")


def main():
    ap = argparse.ArgumentParser(description="ZMeta pairing operator CLI")
    ap.add_argument("--conf", default=str(SCRIPT_DIR / "pairing.conf"))
    ap.add_argument("--invites", default=str(SCRIPT_DIR / "invites.json"))
    ap.add_argument("--state", default=str(SCRIPT_DIR / "pairing_state.json"))
    ap.add_argument("--wg-config", default=str(SCRIPT_DIR / "wg0.conf"))
    ap.add_argument("--peers", default=str(SCRIPT_DIR / "PEERS.md"))
    ap.add_argument("--wg-interface", default="wg0")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_inv = sub.add_parser("invite", help="create a single-use invite code")
    p_inv.add_argument("--label", required=True,
                       help="who this invite is for (operator note)")
    p_inv.add_argument("--hub", required=True,
                       help="hub hostname/IP the mesh can reach")
    p_inv.add_argument("--pair-port", type=int, default=0,
                       help="pairing HTTPS port (default: pairing.conf)")
    p_inv.add_argument("--wg-port", type=int, default=0,
                       help="hub WireGuard port (default: pairing.conf)")
    p_inv.add_argument("--days", type=int, default=7,
                       help="invite lifetime in days (default 7)")

    sub.add_parser("list", help="show invites and paired meshes")

    sub.add_parser("prune", help="drop used/expired invites from invites.json")

    p_rev = sub.add_parser("revoke", help="revoke a paired mesh")
    p_rev.add_argument("platform_id", help="platform_id to revoke")

    args = ap.parse_args()
    cfg = read_conf(args.conf)

    if args.cmd == "invite":
        cmd_invite(args, cfg)
    elif args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "prune":
        cmd_prune(args)
    elif args.cmd == "revoke":
        cmd_revoke(args)


if __name__ == "__main__":
    main()
