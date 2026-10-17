# Meshtastic Driver Spec

`lib/services/meshtastic_driver.dart` — driverId `meshtastic`.

## What it does

Connects to a Meshtastic node's client API over TCP (default port 4403),
performs the `want_config` handshake, and maintains the mesh's NodeDB:

- **Node positions** — every mesh node's GPS position → the tracking map
  (auto-placed via `_applyMeshPositions`; a dragged node keeps its manual
  position).
- **Coarse link data** — two LinkSample families:
  - `meshtastic:local → meshtastic:!<id>` — SNR at which *our* node heard
    that node (from `NodeInfo.snr`).
  - `meshtastic:!<a> → meshtastic:!<b>` — neighbor edges with SNR (from
    the NeighborInfo module, portnum 71, when the mesh broadcasts it).
- **Node loss** — nodes silent > 2× `sampleMaxAge` are pruned; disappearance
  shows as lost links, not phantom data.

## Protocol

Framing (streaming transports): 4-byte header `[0x94, 0xC3, lenMSB, lenLSB]`
+ protobuf payload. Non-header bytes are debug text and are skipped.

Client → radio: `ToRadio{want_config_id}` (field 3, varint).
Radio → client: `FromRadio` stream. The radio answers the handshake with
its full NodeDB (`node_info` packets), then live `packet`s.

Protobuf is decoded by a minimal wire reader (`_PbReader`: varint,
fixed32/sfixed32/float32, length-delimited; unknown fields skipped, so
firmware additions can't break the parse). Only these fields are read
(verified against meshtastic/protobufs `mesh.proto`):

| Message | Field | Wire | Meaning |
|---|---|---|---|
| FromRadio | 2 | LEN | MeshPacket |
| FromRadio | 4 | LEN | NodeInfo |
| NodeInfo | 1 | varint | node number |
| NodeInfo | 3 | LEN | Position |
| NodeInfo | 4 | 32-bit | snr (float, dB) |
| Position | 1,2 | 32-bit | latitude_i, longitude_i (sfixed32, ×1e-7 deg) |
| MeshPacket | 1 | 32-bit | from (fixed32) |
| MeshPacket | 4 | LEN | Data (decoded) |
| MeshPacket | 8 | 32-bit | rx_snr (float) |
| Data | 1 | varint | portnum |
| Data | 2 | LEN | payload |
| NeighborInfo | 4 | LEN | neighbors (repeated) |
| Neighbor | 1 | varint | node_id |
| Neighbor | 2 | 32-bit | snr (float) |

`NEIGHBORINFO_APP` = portnum 71. Other portnums are ignored.

Node IDs follow the ecosystem convention: `meshtastic:!<8 hex digits>`
(e.g. `meshtastic:!a1b2c3d4`), matching `docs` in `lib/utils/node_ids.dart`.

## Timing characteristics

- `sampleMaxAge` = 15 min. Meshtastic telemetry moves on the mesh's own
  slow cadence (position/neighbor broadcasts are minutes apart by
  design) — a few-minute-old SNR is still live evidence.
- The TCP socket persists across polls; reconnect is automatic.
- `poll()` settles 350 ms so the first NodeDB burst lands before sampling.

## Discovery

`RadioDiscovery.scanMeshtastic(cidr)` probes TCP 4403 with the
`want_config` handshake and requires a framed FromRadio header back.
Settings → "Find radios on LAN" runs the Silvus and Meshtastic scans
back-to-back (progress bar split 50/50) and results are tagged with
their driver type — tap to add as the right radio kind.

## USB serial

Raw serial ports are not opened (no serial dependency on any platform).
`MeshtasticDriver.fromAddress('serial:...')` throws with guidance:
run the standard serial-to-TCP bridge on the PC, then add the bridge
address. Documented here so the failure is actionable, not silent.

## Honest scope (also in code)

- Positions update on the mesh's cadence (minutes), not seconds.
- Neighbor SNR is one number per edge — link *health*, not a fast
  disturbance signal. A body crossing a LoRa link *does* move RSSI/SNR
  (LoRa is fade-resistant, not fade-proof), so large disturbances still
  register — but this is coarse presence/health sensing.
- **Tripwire-grade sensing is Path 2** (SX1276 LoRa backhaul nodes with
  edge tripwires); see `docs/lora_nodes_spec.md`.
- Encrypted meshes: the client API decrypts locally, so telemetry still
  flows — same physical-layer argument as the rest of Shepherd.
- `probe()` validates the handshake; `emptyHint` covers "connected but
  no nodes yet".

## Tests

`test/lora_nodes_test.dart`: synthetic protobuf frames (built from the
field table above) verify NodeInfo position/SNR decode, NeighborInfo
edge decode via MeshPacket, framer resync past debug text, portnum
filtering, address parsing, and the `serial:` guidance error.
