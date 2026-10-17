# Shepherd → ZMeta adapter spec

Emit-only bridge from Shepherd's detection pipeline to a
[ZMeta](https://github.com/JTC-byte/zmeta-spec) gateway (v1.1 lane —
declared-2D geo and `PLATFORM_STATUS` require v1.1; the v1.0 schema
rejects both),
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
| Mesh heartbeat (opt-in) | `SYSTEM_EVENT` / `PLATFORM_STATUS` | "Alive, here is the platform" for teams on the move; default off |

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

### Geo (declared 2-D — the honest altitude story)

- `payload.geo` is present only when the detector position is genuinely
  known, and it is declared `"2D"` (`{lat, lon, dimensionality: "2D"}`,
  no `alt_m`) per semantics-contract 21.8. Omitted — never zero-filled
  — otherwise (6.8).
- **Why 2-D:** ZMeta 6.2 requires `alt_m` to be Height Above Ellipsoid
  and forbids MSL/pressure/local altitudes in canonical geo ("convert
  or omit"). The device-reported altitude is platform-dependent —
  Android documents WGS-84 ellipsoid, iOS documents MSL — and is never
  verified HAE, so it is **excluded** from canonical geo and carried
  explicitly in `features.shepherd_sensor_alt_m` instead. Substituting
  a non-HAE altitude into `alt_m` was rejected on the ZMeta record
  (doctrine A1-02); a 2-D position is the honest complete statement of
  what the sensor measured.
- **This is the SENSOR (platform) position, never the target's** —
  stated in `quality.shepherd_geo_note`. Source hierarchy
  (`AppState.bestKnownGeoFor`): (1) midpoint of the two link endpoints
  when both are mesh nodes with surveyed GPS positions (static, trusted
  until re-captured); (2) the phone's last GPS fix, if younger than 10
  minutes (a moving team outruns a stale fix); else omitted.
- `quality.geo_status`: `VERTICAL_UNAVAILABLE` with 2-D geo (21.1:
  a 2-D geo must not claim `AVAILABLE`), `UNAVAILABLE` when omitted.
  `quality.shepherd_geo_source` = `node-midpoint` | `phone-gps` |
  `node-centroid`; accuracy and age ride in
  `quality.shepherd_geo_accuracy_m` / `shepherd_geo_age_s` when known.
- Node positions themselves carry no altitude (operator-surveyed
  lat/lon); the phone fix's altitude is what populates
  `features.shepherd_sensor_alt_m`.

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

## Heartbeat (opt-in)

- `SYSTEM_EVENT` / `PLATFORM_STATUS` (v1.1, semantics-contract 21.6):
  platform health and operating state. The platform's own position is
  operating state — no target track is implied.
- Settings → ZMeta export → "mesh heartbeat", default OFF, cadence
  15–600 s (default 60). Same fail-closed gate as detections
  (non-local + unsecured = no emit) and never during replay.
- `payload.state`: `NOMINAL` while running. `payload.metrics` carries
  `power_state: 'UNKNOWN'` (schema requires a power field; the app does
  not measure device power, and `UNKNOWN` is the honest enum value),
  `platform_type: 'GROUND'` (dismounted team), node/detection counts,
  heartbeat interval, and the platform position (2-D + source/age,
  same honesty rules as observations) when freshly known.
- Policy-clean: `rf-sensor-*` producers may emit `SYSTEM_EVENT`
  (producer-authority.yaml) and `EDGE` may emit it (roles.yaml).

## Sensor observations (universal ingestion)

- `zmetaSensorObservation()` wraps `SensorObservation.toZMetaPayload()`
  in the standard envelope (same UUIDv7/ts/source/profile, fail-closed
  gate, never during replay). Producer `eo-sensor-shepherd` matches the
  governed EO producer pattern (producer-authority.yaml).
- **Only MOTION exports (EO).** BEARING/SPECTRUM stay local: the 1.1.0
  ACOUSTIC arm requires `center_freq_hz` plus a level (`spl_db`, or
  `pressure_pa` + `pressure_statistic`), and our acoustic reports are
  directions/uncalibrated bins — fabricating a level would be exactly
  the lie the schema guards against. RANGE/BINARY/ENERGY have no
  honest modality at all. All five types still feed the in-app map
  overlay and upgrade-only corroboration.
- The EO arm bans `class_name`/`confidence`/`classification`/`label`
  in features — all avoided (`zone_label`). `snapshot_ref` is a
  local-only reference; frames never leave the device.

## Validation

- `test/zmeta_adapter_test.dart`: 23 unit tests (UUIDv7 shape, `Z`
  timestamps, no confidence on observations, sentinel flagging, timing
  completeness, inference lineage/clamping, 2-D geo rules, heartbeat
  shape, sensor-observation modality honesty) plus a sample-JSONL export.
- The sample events (2-D geo observation, no-geo observation,
  inference, heartbeat, EO camera-motion) pass ZMeta's own
  `tools/validate.py --profile H --strict` with 0 failures, 0 warnings
  (validated against zmeta-spec v1.1.26, 1.1.0 lane).
- `flutter analyze`: clean.

## Future

- `SYSTEM_EVENT` / `LINK_STATUS` on radio health transitions.
- Surveyed KrakenSDR array heading → canonical `bearing.az_deg`.
- ZMeta Profile M/L thinning notes for constrained links.
