# LoRa Nodes Spec — two paths, one goal

Warfighter constraint: whatever LoRa hardware is on hand must work as a
Shepherd node, plug-and-play. Two independent paths cover the two
hardware realities.

## Path 1 — Meshtastic driver (app side)

**Use when:** the team already has Meshtastic devices (T-Beam, Heltec,
RAK, …). Zero new firmware, zero flashing — point the app at the mesh.

**How:** `lib/services/meshtastic_driver.dart` (driverId `meshtastic`).
TCP to any node's client API (port 4403), `want_config` handshake,
NodeDB tracking. Each mesh node becomes a Shepherd node:

- GPS position → auto-placed on the tracking map (dragged nodes keep
  manual positions; `NodePosition.userPlaced` guards this).
- `meshtastic:local → meshtastic:!<id>` link samples (heard-SNR) and
  `meshtastic:!<a> → meshtastic:!<b>` neighbor edges (NeighborInfo).
- Node loss = pruned after silence (no phantom links).

**Setup:** Settings → add radio → MESHTASTIC → enter the node's LAN IP
(or leave 127.0.0.1 for a USB-bridged node). "Find radios on LAN" sweeps
TCP 4403 with the real handshake and tags Meshtastic finds. USB-serial
nodes go through the standard serial-to-TCP bridge (the driver refuses
`serial:` addresses with actionable guidance instead of failing
silently). Full protocol spec: `docs/meshtastic_driver_spec.md`.

**Honest limits:** positions/SNR move on the mesh's own slow cadence
(minutes). This is presence + coarse link health, NOT tripwire-grade
sensing. A body crossing a LoRa link does disturb SNR, so big events
register — but fine disturbance detection is Path 2's job.

## Path 2 — SX1276 LoRa backhaul (firmware)

**Use when:** the team has bare ESP32 + SX1276 modules (or can get
them — ~$15 class) and needs real tripwire sensing at LoRa range.

**Architecture (star topology):**

```
[SLN-XXXX tripwire node]  --LoRa-->  [SLG-XXXX gateway]  --UDP 49160-->  Shepherd app
   WiFi RSSI sensing                          re-emits standard
   (edge tripwire,                            beacons/events +
    LoRa backhaul)                            mDNS discovery
```

- `field_kit/esp32/lora_node/lora_node.ino` — ESP32 + SX1276. Senses
  with WiFi (promiscuous RSSI + MAD edge tripwire, same approach as the
  WiFi node); **LoRa is the backhaul, not the sensor**. Sends compact
  binary packets: beacons and events, 22 B each in codec v1, sent
  every 30 s (beacons) or immediately (events). Node IDs `SLN-XXXX`.
- `field_kit/esp32/lora_gateway/lora_gateway.ino` — ESP32 + SX1276.
  Hosts AP `Shepherd-LoRa-XXXX` (password `shepherd-field`); the
  Shepherd PC joins it. Decodes LoRa packets and re-emits byte-
  compatible UDP 49160 JSON beacons/events with the *original* node IDs,
  plus its own `SLG-XXXX` beacon, mDNS `_shepherd-node._udp`, and a
  status page of recently heard nodes.

**Wire encryption (codec v2, PSK):** v1 put the node ID in plaintext
in every packet header — the exact handle Aras et al. (MobiQuitous
2017) used for ~€100 per-node selective jamming. Codec v2 wraps the
v1 payload in AES-128-CCM under a per-deployment pre-shared key set
once on each status page: 34 B on air (schema byte + nonce stay
readable so the gateway's schema gate still fires before decryption;
everything else, node ID included, is ciphertext + auth tag). The
gateway decrypts after the gate and feeds the *unchanged* decode path,
so app-visible JSON is byte-identical to v1. A device with no PSK set
stays on v1 plaintext and says so loudly on its status page — there is
no default key. Migration order: gateways first, then node keys.
Full spec: `docs/lora_psk_codec_spec.md`; test vectors:
`field_kit/esp32/tests/`.

**Key refresh / rotation (prototype, 2026-10-23):** the deployment
PSK can now be rotated without re-visiting devices by hand —
ML-KEM-512 refresh (new key derived from a post-quantum exchange
authenticated by the current PSK) or gateway-pushed rotation (new
key wrapped in the existing codec wrap), both over the devices'
Wi-Fi link (nodes have no LoRa receive path), both through one
stage → confirm → commit machine with a monotonic key counter and
a dual-key acceptance window. Gateway UDP JSON stays byte-identical
throughout. Full spec: `docs/lora_key_refresh_spec.md`.

**App side:** `lib/services/esp32_driver.dart` (driverId `esp32`) is a
passive UDP-49160 listener. It reconstructs each sensor's disturbance
from the node's reported `depth_db` as a virtual link
`esp32:<node> → esp32:<node>:<sensor>` (0 baseline, drops by depth for
the event duration), so the app tripwire detects with its own adaptive
threshold. Beacon lat/lon auto-places nodes. This driver also ingests
WiFi-direct `shepherd_node` beacons — one driver for both node kinds,
no config: add radio → ESP32 NODE → it listens.

**Range (honest):** km-class line-of-sight at SF7/125 kHz; hundreds of
meters in clutter/urban. Higher spreading factor = more range, less
duty-cycle headroom. See the sketch headers for the full table.

**Bandwidth (honest):** beacons 30 s cadence (~57 ms airtime each in
v1, ~77 ms in v2-PSK — far under 1% duty cycle where regulated);
events are rare and immediate.
This link carries detections only: no firmware updates, no streaming,
no mesh LoRa-to-LoRa (star to the gateway).

**Region:** compile flags `LORA_REGION_US915` (default) /
`LORA_REGION_EU868` / `LORA_REGION_AS433`.

## When to use which

| | Path 1: Meshtastic | Path 2: SX1276 backhaul |
|---|---|---|
| Hardware | Any Meshtastic device | ESP32 + SX1276 module |
| Setup | IP address, no flashing | Flash node + gateway once |
| Sensing grade | Coarse (presence/health) | Tripwire (edge detection) |
| Range | Whatever the mesh reaches | km LOS per hop to gateway |
| Node positions | Automatic (mesh GPS) | Beacon lat/lon if equipped |
| Best for | "We have Meshtastic, use it" | "We need real sensing far out" |

They compose: a Meshtastic mesh for team comms/positions *and* LoRa
tripwire nodes for sensing can run side by side — different driverIds,
no link-key collisions.

## What needs field hardware to confirm

- Meshtastic: handshake against real firmware versions (field numbers
  verified against current mesh.proto; tested with synthetic frames
  only), NeighborInfo broadcast cadence on the team's config, position
  update latency in practice.
- SX1276: per-region RX sensitivity, tripwire threshold tuning in real
  RF environments, multi-node Aloha collision behavior at the gateway,
  actual vs. modeled range.
