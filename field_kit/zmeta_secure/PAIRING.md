# ZMeta invite-code pairing (hub operator guide)

The manual flow (mesh sends you `mesh.pub`, you hand-edit configs) still
works. This is the easy version: you hand out a single-use invite code,
the mesh's Shepherd app redeems it, and the hub provisions itself.

## The controls (nothing got weaker)

- **Issuance is the authorization.** No code, no join. Codes are
  single-use and expire (default 7 days).
- **Only token hashes are stored** (`invites.json` keeps sha256, never
  the token).
- **WireGuard still authenticates every peer** cryptographically —
  pairing only automates what the manual flow did by hand.
- **Platform binding still enforced** — two layers, same rule:
  the gateway must drop any event whose `platform_id` doesn't match the
  sender. WireGuard path: tunnel IP → PEERS registry entry.
  HTTPS path: the ingest token is bound to one platform_id at redeem
  time, and `/ingest` returns 403 on mismatch.
- **The pairing channel is TLS** with a self-signed cert, and the
  Shepherd app **pins the cert fingerprint** embedded in the invite
  code. A network attacker can't substitute their own hub.
- **Rate limited**: 10 redeem attempts/minute per source IP;
  120 ingest POSTs/minute per token (tunable with
  `--ingest-rate-per-min`).

## One-time hub setup

1. Double-click **SETUP_PAIRING.bat**. It installs the `cryptography`
   package if needed, generates `pairing.crt` / `pairing.key` (5-year
   self-signed cert), prints the cert fingerprint, and writes
   `pairing.conf` from your answers (gateway WireGuard public key,
   reachable hostname, ports).
2. Copy `gateway-wg0.conf.example` → `wg0.conf`, put your gateway
   **private** key in it. (Or pass `--wg-config` pointing at your real
   config — the server appends `[Peer]` blocks to it.)
3. Open **TCP 8443** (pairing) and **UDP 51820** (WireGuard) in the
   firewall.
4. Start the server: `python zmeta_pairing_server.py`
   (runs in a console window; leave it running).

## Pairing a mesh (~1 minute)

On the hub:
```
python zmeta_invite.py invite --label "3rd Platoon" --hub hub.example.com
```
Hand the printed `Z1.…` line to the mesh operator (any channel — text,
Signal, in person). If the `qrcode` pip package is installed on the
hub (`pip install qrcode`), the invite tool also prints the code as a
scannable QR.

On the mesh (their Shepherd):
Settings → ZMeta export → **Join network** → paste the code, or tap
**SCAN QR CODE** and point the camera at the hub's QR (Shepherd
v0.21.0+, Android/iOS) → the app generates its keypair, redeems the
code, and shows a QR code / config for the WireGuard app. They scan
it, activate the tunnel, set their Platform ID, and enable export.
Their tunnel IP is assigned automatically (10.99.0.11, .12, …).

Check it worked:
```
python zmeta_invite.py list
```
Their `[Peer]` block is in `wg0.conf` and their row is in `PEERS.md`.

## HTTPS ingest — no WireGuard needed

For forward-deployed meshes that can't install apps and whose networks
allow HTTPS but block UDP: skip the WireGuard tunnel entirely. The
mesh POSTs ZMeta events straight to the hub over HTTPS.

**How it works.** Every successful redeem now ALSO mints a long-lived
ingest credential and returns it in the redeem response:

```json
{ "ok": true, ..., "ingest_url": "https://pair.example.com/zmeta/ingest",
  "ingest_token": "<43-char token, shown ONCE>" }
```

The mesh stores the token and sends each event as:

```
POST https://pair.example.com/zmeta/ingest
Authorization: Bearer <ingest_token>
Content-Type: application/json

{"zmeta_version": "1.0", "source": {"platform_id": "bravo-mesh-1", ...}, ...}
```

The endpoint is auth + binding + forward **only**:
- unknown or revoked token → `401`
- body not a JSON dict, or over 64KB → `400`
- event `source.platform_id` ≠ the token's registered platform_id → `403`
  (this is the platform binding for the HTTPS path)
- accepted → the raw JSON is forwarded as a UDP datagram to the
  gateway's ingest (`--gateway-host`/`--gateway-port`, default
  127.0.0.1:5555), which still does all schema/policy validation →
  `202`

**Token lifecycle.** 32 random bytes (base64url, 43 chars); only the
SHA-256 is stored, in `pairing_state.json` under `ingest_tokens`
(constant-time compare; the token itself never appears in logs —
at most the first 8 chars of its hash). `revoke <platform_id>` kills
the mesh's ingest token(s) along with its WireGuard peer, and `list`
shows each mesh's token status (`active`/`revoked`/`none`, never the
token). If a token is suspected compromised, revoke and re-pair — the
mesh gets a fresh one.

**Hub setup.** Set `ingest_url` in `pairing.conf` (see
`pairing.conf.example`), e.g. your Cloudflare-fronted domain — the
ingest traffic then blends in as ordinary HTTPS, same as the pairing
endpoint. The gateway must be running on the hub ingesting UDP 5555
(`python tools/run_gateway.py --profile H` in your Zmeta folder);
the pairing server forwards to it on loopback. Works in both TLS and
`--no-tls` (loopback-only) modes.

**WireGuard stays.** Nothing about the tunnel path changed — it
remains the option for operators who want network-layer identity on
top of the token. The redeem response carries both; the mesh picks.

## Revoking a mesh

```
python zmeta_invite.py revoke shepherd-mesh-a
```
Removes the `[Peer]` block, marks the PEERS.md row REVOKED, and frees
nothing — tunnel IPs are never reused. On a Linux hub the server tries
`wg syncconf` live; otherwise **reactivate the tunnel in the WireGuard
app** for the change to take effect. If a key is suspected compromised,
have the mesh generate a fresh keypair and pair again with a new invite.

### Lost or stolen device — do this immediately (S5)

```
python zmeta_invite.py revoke <platform_id>
```

One command kills **both** paths: the WireGuard `[Peer]` and the
platform's HTTPS ingest token(s). The ingest token dies on the very
next request — a revoked token gets HTTP 401, and the thief's app
shows them "HUB REJECTED THE TOKEN" after 5 failures. There is no
grace period and nothing to wait for on the hub side.

Then assess what the device held:
- **HTTPS-ingest token only** (the normal forward-deployed case):
  revoking is sufficient. The token was bearer-only — it could submit
  events as that mesh, nothing more. The gateway still validated every
  event, and the platform binding meant it could never impersonate
  another mesh. Re-pair the replacement device with a fresh invite.
- **WireGuard private key** (if the mesh used the WG path): revoke as
  above, and consider the tunnel IP burned (it already is — IPs are
  never reused). No hub-side key rotation is needed for one lost
  client key; the hub's own key never left the hub.
- **If the device held the hub's pairing cert fingerprint** it changes
  nothing — the fingerprint is public by design (it ships inside every
  invite code). Only rotate the hub's pairing cert if you believe the
  hub host itself is compromised, then re-run SETUP_PAIRING.bat and
  issue fresh invites (old codes carry the old fingerprint and stop
  working — tell your meshes).

## Cloudflare deployment (public domain, no open ports)

If you'd rather not expose TCP 8443 directly, front the pairing
endpoint with Cloudflare — it blends in as ordinary HTTPS:

1. Run a `cloudflared` tunnel at the pairing server:
   `cloudflared tunnel --url http://127.0.0.1:8443`
   (or a named tunnel → `pair.example.com`).
2. Start the pairing server with `--no-tls`:
   `python zmeta_pairing_server.py --no-tls --pair-host 127.0.0.1`
   (or just double-click `START_HUB.bat` — it picks the right mode)
   The server REFUSES `--no-tls` unless `--pair-host` is a loopback
   address, and logs a loud line on start:
   "TLS terminated upstream (Cloudflare); bound to loopback only."
3. In `pairing.conf`, set `certfp=-` (overwrite the fingerprint
   SETUP_PAIRING.bat generated — there is no pairing TLS cert in this
   mode).
4. Hand out invites for the public domain:
   `python zmeta_invite.py invite --label "3rd Platoon" --hub pair.example.com --pair-port 443`
   The invite code ends in `.-` instead of a fingerprint, and the
   Shepherd app does normal public-CA verification of your domain.

Trust tradeoff: in direct mode the app pins the exact server cert —
even a compromised CA or a proxy CA installed on the device cannot
impersonate the hub. In Cloudflare mode the app trusts the public CA
system and the Cloudflare edge (the edge sees the token); the 256-bit
single-use invite token in the POST body is the credential, so a
stolen token only lets an attacker race the legitimate redeem — and
the loser's redeem fails loudly ("used"), so interception is noisy
and shows up in the hub's pairing.log.

## Invite code anatomy (for the Shepherd app side)

```
Z1.<hub_host>.<pair_port>.<wg_port>.<token_b64url>.<certfp>
```

- `Z1` — version tag.
- `hub_host` — DNS name or IPv4 the mesh can reach. **May contain dots** —
  parse the code from the RIGHT: the last field is always the certfp,
  the one before it the 43-char token, then the two numeric ports;
  everything between `Z1.` and `pair_port` is `hub_host`.
- `pair_port` — TCP port of the pairing HTTPS endpoint.
- `wg_port` — hub WireGuard UDP port. **Informational / validated only:**
  the app shows it, but the `[Peer] Endpoint` line in the generated
  WireGuard config always comes from the server's `hub_endpoint` in the
  redeem response — that is authoritative.
- `token_b64url` — 32 random bytes, base64url, no padding (43 chars).
  Send verbatim as `token` in the redeem POST.
- `certfp` — either 64 hex chars = SHA256 of the pairing server's TLS
  cert DER (direct mode: pin this; abort if the presented cert doesn't
  match), or `-` (Cloudflare mode: normal public-CA verification of
  `hub_host`; see "Cloudflare deployment" above).

Redeem: `POST https://<hub_host>:<pair_port>/redeem`
`{"token","pubkey","platform_id"}` → see the server docstring for the
exact success/error shapes.

## Files

| File | What it is — protect it |
|---|---|
| `pairing.key` | TLS private key — **never share** |
| `pairing.crt` | TLS cert (public) |
| `pairing.conf` | hub pubkey, endpoints, cert fingerprint |
| `invites.json` | invite records (hashes only) |
| `pairing_state.json` | IP allocations + ingest token hashes — **back this up**; losing it risks re-issuing a tunnel IP |
| `pairing.log` | audit log: every invite, redeem, revoke |
| `wg0.conf` | your live WireGuard config (private key inside — **never share**) |
| `PEERS.md` | human-readable peer registry |

### Protect the hub folder (N9)

Everything in this folder is operator-only. `pairing.key` and the
private key inside `wg0.conf` are the crown jewels; `invites.json`
holds live invite hashes and `pairing_state.json` controls IP
allocation — anyone who can write these files can impersonate the hub
or hijack pairings.

- **Windows:** right-click the folder → Properties → Security →
  Advanced → disable inheritance, remove every principal except your
  own account and SYSTEM/Administrators. Or from an elevated prompt:
  `icacls <folder> /inheritance:r /grant:r "%USERNAME%:(OI)(CI)F"`.
- Never copy `pairing.key` / `wg0.conf` to a shared drive, chat, or
  repo. `pairing.crt` (the public cert) is the only file here that is
  safe to move around.

## Troubleshooting

- **Redeem fails / can't reach the hub**: the mesh needs
  `https://<hub>:8443` reachable (TCP). Check the firewall and that the
  server console shows no bind errors.
- **`reload_needed: true` in the redeem response**: normal on Windows —
  the hub operator reactivates the tunnel in the WireGuard app once.
- **Invite expired**: make a new one (`--days N` sets lifetime).
- **"platform_taken"**: that Platform ID is already paired. Pick a
  unique one per mesh.
- **Cert regenerated**: re-run SETUP_PAIRING.bat, hand out fresh
  invites — old codes embed the old fingerprint and stop working.
- **`/ingest` returns 401**: the token is wrong, revoked, or wasn't
  sent as `Authorization: Bearer <token>`. Check `list` for the
  mesh's token status; re-pair for a fresh token.
- **`/ingest` returns 403**: the event's `platform_id` doesn't match
  the platform the token was issued to — fix the mesh's Platform ID.
- **`/ingest` returns 500 `forward_failed`**: the gateway isn't
  listening on the forward target — start it
  (`python tools/run_gateway.py --profile H`) and check
  `--gateway-host` / `--gateway-port`.
