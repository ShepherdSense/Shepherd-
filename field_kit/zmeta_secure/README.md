# Secured Shepherd → ZMeta link (WireGuard)

Shepherd works at the **tactical** level. ZMeta fuses at the
**operational/strategic** level. This package secures the connection
between them — every mesh's detection events travel inside an
authenticated, encrypted WireGuard tunnel to the ZMeta gateway.

No Shepherd code changes needed: Shepherd just sends its ZMeta UDP
events to the gateway's *tunnel* address (e.g. `10.99.0.1:5555`).
The tunnel is the encryption.

## What this secures (and what it doesn't)

- **Confidentiality:** detection times, frequencies, platform IDs are
  unreadable on the wire. ✅
- **Authentication:** only meshes whose public key the gateway
  registered can send events. Forged detections from the LAN are
  rejected by the tunnel itself. ✅
- **Integrity:** events can't be altered in transit. ✅
- What it does NOT do: protect the gateway host itself, or stop a
  compromised mesh from sending *its own* (false) detections — that's
  a trust problem, not a crypto problem.

## Setup (per mesh, ~5 minutes)

1. Install WireGuard for Windows: https://www.wireguard.com/install/
2. Double-click `NEW_MESH_KEY.bat` → creates `mesh.key` (private —
   never share) and `mesh.pub` (public).
3. Send `mesh.pub` to the ZMeta gateway operator (it's public; any
   channel works).
4. The operator replies with: your tunnel IP (e.g. `10.99.0.11`), the
   gateway's public key, and the gateway's public `host:port`.
5. Copy `shepherd-mesh.conf.example` → `shepherd-mesh.conf`, fill in
   the 4 values, import into WireGuard, Activate. For an EUD instead
   of a PC: double-click `MAKE_TUNNEL_QR.bat` and scan the QR with
   the phone's WireGuard app (+ → Scan from QR code) — the tunnel
   imports directly, no file to copy. The QR contains the private
   key; treat it like the key itself.
6. In Shepherd → Settings → ZMeta export: set host to the gateway's
   **tunnel** address (`10.99.0.1`), port `5555`, and your unique
   Platform ID (e.g. `shepherd-mesh-a` — must match the PEERS registry).

## Setup (gateway operator)

1. `wg genkey > gateway.key && wg pubkey < gateway.key > gateway.pub`
2. Copy `gateway-wg0.conf.example` → `/etc/wireguard/wg0.conf`, fill in
   the gateway private key, add one `[Peer]` block per mesh (their
   public key + assigned tunnel IP).
3. Record each mesh in `PEERS.md` (tunnel IP ↔ platform_id ↔ party).
4. `sudo wg-quick up wg0`; open UDP 51820 in the firewall.
5. Bind the ZMeta gateway's ingest to the tunnel address (`10.99.0.1`),
   NOT `0.0.0.0` — plaintext events must never sit on an untrusted
   interface.
6. Enforce the platform binding: check every incoming event's
   `source.platform_id` against the PEERS registry entry for the
   sender's tunnel IP; drop mismatches (see `docs/zmeta_deployment.md`).

## Testing the secured path

1. Activate the tunnel on the mesh; `ping 10.99.0.1` should answer.
2. In Shepherd, enable ZMeta export pointed at `10.99.0.1:5555`.
3. Trigger a detection (or sim mode); the gateway log should show the
   event arriving with your platform_id.
4. Negative test: stop WireGuard — events must NOT arrive (proving
   they only flow inside the tunnel).

Full architecture, multi-party fusing notes, and key-compromise
procedure: `docs/zmeta_deployment.md` in the Shepherd repo.
