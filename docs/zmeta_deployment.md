# ZMeta deployment architecture: tactical Shepherd → operational/strategic ZMeta

## Tiers

```
TACTICAL (edge)                    OPERATIONAL / STRATEGIC
┌────────────────┐                  ┌─────────────────────────┐
│ Shepherd mesh A│──┐               │ ZMeta gateway           │
│ 6 nodes, trip- │  │ WireGuard     │  • validates events     │
│ wire + tracks  │  │ (one tunnel   │  • fuses across meshes  │
└────────────────┘  │  per mesh)    │  • projects STATE → COP │
┌────────────────┐  │               │    / ATAK (CoT egress)  │
│ Shepherd mesh B│──┤               └─────────────────────────┘
│ platform:      │  │
│ shepherd-mesh-b│  │
└────────────────┘  │
┌────────────────┐  │
│ Shepherd mesh C│──┘
│ (another party)│
└────────────────┘
```

- **Tactical:** each Shepherd mesh detects and tracks locally. It is
  the authority on its own detections — nothing above it re-decides
  whether a crossing happened.
- **Operational/strategic:** ZMeta ingests every mesh's
  `OBSERVATION_EVENT`s, correlates them across meshes (same target
  seen by two meshes, hand-off at boundaries), and promotes fused
  tracks toward the COP. Fusion never rewrites what a mesh reported;
  ZMeta's lineage model keeps every promotion evidence-bearing.

## Multi-party data fusing

"Multi-party" here means multiple independent Shepherd meshes —
different teams, units, or coalition partners — feeding one ZMeta
fabric. What makes it work:

1. **One platform_id per mesh, globally unique.** Set in Shepherd →
   Settings → ZMeta export. The gateway keys attribution, peer
   registry, and any per-party handling off this value.
2. **ZMeta's contract already separates authority by layer.** A mesh's
   observation is evidence; cross-mesh track identity is the gateway's
   fusion product. Parties can't corrupt each other's data — they can
   only add observations, and every promotion carries lineage back to
   the originating platform_id.
3. **No cross-mesh trust required for detection integrity.** Mesh A
   never sees mesh B's raw events unless the gateway operator chooses
   to share fused output downward. Raw observations flow one way:
   tactical → operational.
4. **Degraded parties stay visible.** A mesh that goes silent, sends
   stale data, or reports `UNCALIBRATED`/`UNSYNCED` timing is flagged
   by the gateway's policy layer — it degrades that party's
   contribution instead of silently dropping or blindly trusting it.

What Shepherd does NOT do: it never fuses other meshes' data, never
takes commands from ZMeta (emit-only — the adapter has no receive
path), and never re-labels another party's detections.

## Securing the tactical → operational link

The connection crosses networks by design, so it is secured with
**WireGuard** (Noise protocol, ChaCha20-Poly1305 authenticated
encryption), hub-and-spoke: the gateway (or a relay next to it) is
the hub; each mesh is a spoke. Meshes never talk to each other.

Why WireGuard and not event-level crypto in the adapter:
- The ZMeta gateway validates **plaintext** ZMeta JSON. Encrypting
  inside Shepherd would break the standard contract — you'd decrypt
  before ingest, which is just a worse VPN.
- WireGuard gives authentication + confidentiality + integrity in one
  audited mechanism, at the OS layer, with zero Shepherd code changes:
  the adapter already targets a host:port, which becomes the tunnel
  address.
- The sharper threat is **injection** (forged detections → false
  tracks), not just eavesdropping. An unauthenticated UDP socket
  accepts anyone's events; WireGuard peers are cryptographically
  identified, so the tunnel itself rejects outsiders.

### Key ceremony (per mesh)

1. Mesh operator runs `NEW_MESH_KEY.bat` (double-click) → `mesh.key`
   (private, never leaves the mesh) + `mesh.pub` (public).
2. `mesh.pub` goes to the gateway operator over any channel.
3. Operator adds a `[Peer]` block (public key + assigned tunnel IP
   `10.99.0.x`) to the gateway config and records the binding
   tunnel-IP ↔ platform_id ↔ party in `PEERS.md`.
4. Operator returns: the mesh's tunnel IP, the gateway public key,
   and the gateway's public endpoint.
5. Mesh fills `shepherd-mesh.conf`, imports into WireGuard, activates.

There is no PKI and no shared secret: compromise of one mesh's key
affects only that mesh. Revocation = delete its `[Peer]` block.

### The platform binding (gateway side — do not skip)

WireGuard authenticates the *peer*, but ZMeta events self-declare
`source.platform_id`. A compromised mesh could otherwise spoof
another mesh's platform_id inside its own (valid) tunnel. The gateway
MUST check, on ingest, that the event's `source.platform_id` equals
the PEERS registry entry for the sender's tunnel IP, and drop
mismatches. On the reference Python gateway this is a small check in
the ingest path before validation; on a production gateway it's part
of the ingress policy.

### What the gateway binds to

Bind the ZMeta ingest socket to the tunnel address (`10.99.0.1`),
never `0.0.0.0`. Plaintext events must not be exposed on any
untrusted interface — the tunnel is the only door.

### Firewall

- Gateway: allow UDP 51820 (or the chosen WireGuard port) inbound
  from the meshes' networks. Nothing else needs to be reachable.
- Meshes: outbound UDP to the gateway's endpoint. `PersistentKeepalive
  = 25` keeps NAT mappings alive on flaky tactical links.

## Failure modes

- **Tunnel down:** Shepherd's emitter silently drops events (emit-only,
  fire-and-forget — detection continues locally, nothing blocks).
  The gateway sees the mesh go quiet; its policy layer should flag
  the party stale, not assume clear.
- **Mesh key compromised:** revoke the `[Peer]` block; the mesh
  re-runs keygen and re-registers. Old key stops working immediately.
- **Gateway host compromised:** worst case — regenerate the gateway
  keypair, redistribute the new public key + endpoint to all meshes.
- **Clock skew:** ZMeta events carry `timing_quality`; meshes without
  GPS PPS declare `UNKNOWN`/`UNSYNCED` with a 60 s error bound, so the
  gateway treats their timestamps accordingly instead of trusting them.

## Bandwidth

One detection = one small JSON datagram (observation, ~1 KB) plus an
inference when the classifier fires. Even dozens of meshes at high
tempo fit comfortably in a WireGuard tunnel on a constrained link.
For severely constrained links, ZMeta's Profile M/L export thinning
applies at the gateway — a future adapter option, not needed for v1.
