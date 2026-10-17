# Shepherd → ZMeta adapter spec

Emit-only bridge from Shepherd's detection pipeline to a
[ZMeta](https://github.com/JTC-byte/zmeta-spec) gateway (v1.0 lane),
so ZMeta can see Shepherd detection data and fuse across multiple
Shepherd mesh networks. One Shepherd instance = one ZMeta `platform_id`;
the gateway correlates and fuses across meshes.

## Why ZMeta fits

ZMeta's adapter contract machine-checks the same honesty rules Shepherd
is built on: no fabricated bearings for omnidirectional sensors, no
invented quality metrics, degraded timing stays visible, and a line of
bearing is not a track. Its reference deployment history already
includes KrakenSDR DoA and PSD-sweep sensors feeding RF observations
into downstream fusion — the same shape as Shepherd's outputs.

## Event mapping

| Shepherd | ZMeta event | Notes |
|---|---|---|
| Tripwire `CrossingEvent` | `OBSERVATION_EVENT` / `RF` | One per confirmed crossing |
| Embedded classifier label | `INFERENCE_EVENT` / `CLASSIFICATION` | Genuine `based_on` lineage to its observation |
| Radio health transitions | `SYSTEM_EVENT` / `LINK_STATUS` | Planned (v1.1) |

Fused tracks are deliberately NOT emitted as `FUSION_EVENT` in v1:
cross-mesh fusion is the gateway's job, and Shepherd's internal tracks
are its own estimate. The gateway builds tracks from observations.

## Field mapping (observation)

- `event.event_id`: UUIDv7. `event.ts`: UTC with trailing `Z`.
- `source.platform_id`: the mesh's platform ID (Settings → ZMeta export,
  default `shepherd-mesh-1`). This is what distinguishes meshes at the
  gateway — give each mesh a unique ID.
- `source.node_role`: `EDGE`. `source.producer`: `rf-sensor-shepherd`
  (matches the gateway's producer-authority policy).
- `source.sensor_id`: the Shepherd link key.
- `payload.modality`: `RF`.
- `payload.features.center_freq_hz`: measurement channel center —
  Silvus/sim 2440 MHz, SDR band center from the bridge, KrakenSDR tuned
  frequency parsed from the link key.
- `payload.features.bandwidth_hz`: channel bandwidth when known, else
  the documented `0.0` sentinel (ZMeta's own convention for
  receiver-class sensors).
- `payload.features.power_dbm`: **documented sentinel `0.0`.** The schema
  requires this field, but a passive link-disturbance sensor measures
  channel disturbance, not emitter power, and Shepherd's dip depth is in
  radio-internal units, not dBm. Following ZMeta's documented-sentinel
  precedent, the adapter emits the fixed sentinel and flags it in
  `quality.shepherd_power_sentinel: true` with
  `quality.calibration_state: UNCALIBRATED`. The real measurement —
  disturbance depth in dB (radio units) — is in the explicitly-named
  `features.shepherd_dip_depth_db`. Never read `power_dbm` as received
  power on Shepherd events.
- `payload.features.shepherd_link` / `shepherd_driver` /
  `shepherd_disturbance` (`dip`|`rise`) / `shepherd_duration_s` /
  `shepherd_size_est` (S/M/L heuristic) / `shepherd_via_variance`
  (VRTI channel) / `shepherd_energy_dbfs` (SDR, dBFS — not dBm) /
  `shepherd_sig_hint` (SDR signature hint, future).
- KrakenSDR DoA travels array-relative in
  `features.kraken_doa_array_relative_deg`. The canonical `bearing` block
  is omitted until a surveyed array heading is configured (ZMeta contract
  6.4: convert or omit).
- `payload.timing_quality`: `UNKNOWN`/`UNSYNCED` with `est_error_ms: 60000`
  unless the reporting node has GPS PPS lock (`GPS_PPS`/`LOCKED`,
  `est_error_ms: 1`). `last_sync_ts` falls back to the event timestamp
  per ZMeta's reference convention. Degraded timing stays visible.
- `confidence` is never present on observations (contract 7.1).
- Original observations carry no `lineage` block (no ZMeta parent exists).

## Inference mapping

- `event_subtype`: `CLASSIFICATION`. `node_role`: `GATEWAY` (the roles
  policy permits `INFERENCE_EVENT` only from `GATEWAY` — same convention
  as ZMeta's own eo-cv/sapient adapters, whose inference also runs on
  the edge device). `producer`: `classifier-shepherd`.
- Envelope `confidence` = the classifier's confidence (required on
  inference). `claim.label` = PASSING/LINGERING/INTERFERENCE/FAULT with
  a `confidence_hint` (high/medium/low).
- `model`: `shepherd-disturbance-clf` v1.0.0 — heuristic, synthetic-trained.
- `lineage.based_on` = the genuine parent observation's `event_id`.

## Transport

UDP, one JSON object per datagram, to the gateway's ingest port
(default `127.0.0.1:5555`). Emit-only: the adapter never receives, and
a down gateway can never disturb detection (all errors swallowed,
socket closed on dispose).

## Deployment security

Shepherd operates at the **tactical** level and reports to ZMeta at
the **operational/strategic** level. That connection crosses networks
by design, so it is **always secured** — see `docs/zmeta_deployment.md`
and `field_kit/zmeta_secure/` for the full package.

- **WireGuard** hub-and-spoke: the gateway is the hub, each mesh a
  spoke with its own keypair. Authenticated encryption
  (confidentiality + integrity + peer authentication) at the OS layer.
- **No Shepherd code changes needed**: the adapter already targets a
  host:port — it becomes the gateway's *tunnel* address
  (e.g. `10.99.0.1:5555`). The gateway binds ingest to the tunnel
  address, never `0.0.0.0`.
- Do NOT encrypt inside the adapter: the gateway validates plaintext
  ZMeta JSON, so adapter-level crypto would break the standard
  contract. ZMeta is deliberately "not a transport" — encryption is
  the transport's job.
- The sharper threat is **injection** (forged detections → false
  tracks). The gateway must additionally enforce the **platform
  binding**: every event's `source.platform_id` must match the PEERS
  registry entry for the sender's tunnel IP; drop mismatches.
- What the data reveals (detection times, watched frequencies,
  platform IDs) is OPSEC-relevant — it never travels outside the
  tunnel.

## Validation

- `test/zmeta_adapter_test.dart`: 14 unit tests (UUIDv7 shape, `Z`
  timestamps, no confidence on observations, sentinel flagging, timing
  completeness, inference lineage/clamping) plus a sample-JSONL export.
- The sample events pass ZMeta's own `tools/validate.py --profile H
  --strict` with 0 failures (validated against zmeta-spec v1.1.26,
  1.0 lane).
- `flutter analyze`: clean.

## Future

- `SYSTEM_EVENT` / `LINK_STATUS` on radio health transitions.
- `shepherd_sig_hint` from the SDR bridge's FHSS signature detector.
- Surveyed KrakenSDR array heading → canonical `bearing.az_deg`.
- ZMeta Profile M/L thinning notes for constrained links.
