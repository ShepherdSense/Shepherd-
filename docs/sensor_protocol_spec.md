# Shepherd Sensor Protocol

**"If it can sense something, it feeds Shepherd."**

One wire protocol for every non-RF-tripwire sensor: lidar, time-of-flight,
ultrasonic, acoustic arrays, PIR / break-beams, generic RF-energy taps, and
cameras. Two transports, one data model. The RF tripwire remains the
detection authority; everything here is **corroboration — upgrade-only,
never veto** (see §7).

## 1. Transports

### 1a. UART text lines (sensor → node serial port)

One measurement per line, `\n`-terminated, 9600–115200 baud (node's
choice). Whitespace-separated; `#` starts a comment.

```
RANGE lidar1 12.4 45            # distance_m [angle_deg]
RANGE tof1 3.2                  # angle omitted: omnidirectional/unknown
BEARING micarray 137 0.8        # deg clockwise from north [confidence]
SPECTRUM mic1 120:0.2,240:0.9   # hz:mag pairs, 1..64 bins
BINARY pir1 1                   # 0|1 (true|false also accepted)
ENERGY rf1 -67                  # RSSI-like level, dBm-ish
MOTION cam1 zone=3              # zone= and label= optional
MOTION cam1
SENSOR node1 -71.5              # LEGACY form → parsed as ENERGY
```

### 1b. UDP JSON (node → app, anything → app)

Port **49160** (shared with node beacons/events — different `type`).
One JSON object per datagram:

```json
{"type":"sensor_obs","obs":"RANGE","sensor":"lidar1",
 "dist_m":12.4,"angle_deg":45,"lat":35.10,"lon":-78.90,"t":1760000000.0}
```

Fields per `obs`:
| obs | fields |
|---|---|
| RANGE | `dist_m` (req), `angle_deg` (opt) |
| BEARING | `bearing_deg` (req), `confidence` (opt, default 0.5) |
| SPECTRUM | `freq_hz[]`, `magnitudes[]` (req, parallel, ≤64) |
| BINARY | `triggered` bool (req) |
| ENERGY | `level_db` (req) |
| MOTION | `zone`, `zone_label` (opt) |

Common optional: `lat`, `lon` (sensor position; `0,0` rejected),
`t` (unix seconds; receive time used when absent/insane).

### 1c. Parser contract

- Malformed input is **logged and skipped, never thrown**. A chatty
  broken sensor must not take down ingest.
- NaN / ±Inf rejected everywhere. Out-of-range values (negative
  distance, >64 bins, absurd timestamps) rejected.
- Unknown `obs` verbs → skipped (forward-compatible).

## 2. App ingestion

`GenericSensorDriver` (driverId `sensor`) listens on the shared UDP
hub, keeps a bounded store (500 observations / 200 sensors / 10 min),
and exposes `observationsSince(ts)` + `latestPerSensor()`.

ENERGY and BINARY observations **also** emit virtual tripwire links so
the existing adaptive tripwire fires on them with no new detection
code:

- `sensor:<id> → sensor:<id>:energy` — `snr` = reported level; the
  baseline learns it, disturbances trip it.
- `sensor:<id> → sensor:<id>:binary` — `snr` = 0 quiet / −20 triggered.

At merge these `sensor:` links are excluded from geometric fusion
(same as `sdr:`/`esp32:` — no link geometry).

## 3. Cameras

Two ingest paths, same observation stream (type MOTION):

**A. HTTP webhook (supported).** Driver binds
`http://<device>:<port>/motion` (default 49162). Cameras / NVRs
(Frigate, Shinobi, Blue Iris, most IP cams) POST on motion:

```json
{"camera":"front-porch","zone":"3","label":"Driveway",
 "snapshot_url":"http://cam/shot.jpg"}
```

Lenient: Frigate's `{"after":{"camera":…,"label":…}}` shape accepted,
`?camera=x&zone=3` query form accepted, common field spellings
accepted. Garbage → 400, logged, never a crash.

**B. ONVIF PullPoint (best-effort).** SOAP `CreatePullPointSubscription`
→ `PullMessages` loop against the camera's events service, watching
`RuleEngine/MotionDetector` (fallback `VideoSource/MotionAlarm`).
**Verified:** envelope shapes + topic/state parsing against synthetic
responses (unit-tested). **NOT field-verified:** real firmware varies
in WS-Security requirements, digest nonce handling, event-service
paths, and topic dialects. HTTP digest auth is handled; WS-UsernameToken
headers are not sent. Failures log and the driver keeps running —
the webhook path is the supported integration.

**Snapshots:** `fetchSnapshot()` pulls a JPEG on demand for the
evidence view ("why did it alert" + a frame). Frames stay on-device;
ZMeta carries only a local `snapshot_ref`, never pixels.

**Confirmation contract** (extends the existing stub): motion near a
track upgrades displayed confidence (`CORROBORATED`); disabled =
`NOT_CONFIGURED`; no motion = `NO_MOTION` (informational). There is no
code path by which a camera suppresses a detection.

## 4. Map rendering

`sensor_overlay.dart` — pure functions, observations + projector in,
widgets out: range arcs (circle, or wedge for directional), bearing
lines with ±25° uncertainty wedges, acoustic peak glyphs, motion
markers. Observations older than 5 min or without lat/lon are skipped
(never plotted at 0,0). Merge seam documented in the file.

## 5. Tracker corroboration (upgrade-only)

`SensorObservation.corroborationFor(track, sensorX, sensorY)` returns
a non-negative boost (asserted) plus a 0..1 `quality` (geometry
alignment). Current gates:

- RANGE: track within ±12 m of reported distance (and ±20° of the
  axis when directional) → up to +0.25, quality = closeness.
- BEARING: track within ±25° of the acoustic bearing → up to +0.20
  scaled by array confidence, quality = angular alignment.
- BINARY: triggered + track within ~12 m → +0.10, quality 1.0.
- MOTION: +0.15 (camera saw motion where the track is), quality 1.0.
- SPECTRUM / ENERGY: +0 (context for the evidence view, not a vote;
  ENERGY already drives the tripwire — no double counting).

Total boost is capped by the merger (at wire-up). Silence — missing
data, geometry miss, degenerate input — is always "no opinion", never
a veto.

### 5a. Gated confidence merger (research finding #2)

AppState merges corroboration into the track's *displayed* confidence
with the gated merger (`lib/services/confidence_merger.dart`) — the
literature shape of the upgrade-only rule (AV-FDTI entropy-gated
asymmetric fusion, lane3 P5):

```
C_display = clamp(C_RF + U, C_RF, C_max)
U  = U_max · (1 − exp(−Σ_s (w_s · e_s) / U_max))     (saturating)
w_s = freshness_s · health_s · quality_s              (reliability gate)
```

- `C_RF`: RF-core confidence from the deterministic tracker
  (`rfCoreConfidence`: saturating in linksUsed, capped 0.80 —
  a labeled display heuristic, not a measured probability).
- `e_s`: the non-negative boost from `corroborationFor` above.
- `w_s ∈ [0,1]`: measured information content, multiplicative —
  any single zero collapses the weight:

| gate factor | measures | zero when |
|---|---|---|
| freshness | observation age vs the per-type staleness horizon below | age ≥ horizon (no recent data ⇒ no weight — the AV-FDTI `h → 0` case) |
| health | driver alive / recent data (sensor-bus last-poll ≤ 90 s; camera enabled + recent motion) | source silent or unconfigured |
| quality | `Corroboration.quality` — geometry alignment from the gates above | geometry miss (`none` carries quality 0) |

Staleness horizons: RANGE/BEARING/SPECTRUM 10 s, ENERGY 30 s,
MOTION 30 s, BINARY 2 min — the sensors' natural cadence, not a
tuning knob.

Hard properties (all property-tested): **never subtractive**
(`C_display ≥ C_RF` by construction — the merger has no code path
that lowers confidence); **saturating** (total upgrade capped
+0.35, exponential approach — ten weak PIR triggers asymptote, they
cannot manufacture certainty); **never identity** (`C_max = 0.95`).
Detection authority is untouched: the tripwire originates every
detection; the merger only computes a display number for a track the
RF core already supports.

While the track is internally inconsistent (see §5b) all upgrades are
suspended: `C_display = C_RF`. Upgrading a misassociated track is the
failure mode the consistency literature warns about.

### 5b. Consistency monitor (honest NEES analogue)

The app tracker is a grid search with no state covariance, so a
textbook NEES (eᵀP⁻¹e) is impossible. `lib/services/track_consistency.dart`
checks what *can* be checked: predict each fix from the track's recent
constant-velocity motion, normalize the residual by the tracker's
expected fix-error scale (1.0 m — the coarse-grid quantization scale),
and flag **sustained** large normalized innovations (3σ × 3
consecutive to flag, 5 consecutive small to clear — one jump never
flaps the flag). The verdict surfaces on the tracking screen as a
`TRACK STATE: INCONSISTENT` flag and gates the merger per §5a.

## 6. ZMeta export

`toZMetaPayload()` maps each type to a modality that actually fits
(checked against zmeta-spec; modalities are RF/EO/IR/ACOUSTIC/NETWORK).
Validated against `tools/validate.py --profile H --strict` (EO sample:
1/1 pass, 0 warnings).

| type | modality | notes |
|---|---|---|
| MOTION | EO | zone/label; `snapshot_ref` is local-only. Producer `eo-sensor-shepherd` per the governed producer pattern |
| BEARING | — | **not exported**: the 1.1.0 ACOUSTIC arm *requires* `center_freq_hz` plus a level (`spl_db`, or `pressure_pa` + `pressure_statistic`). A bearing is a direction with no level — fabricating one would be exactly the lie the schema guards against |
| SPECTRUM | — | **not exported**: bins are uncalibrated magnitudes, not a sound pressure |
| RANGE | — | **not exported**: no LIDAR modality; shoehorning into EO/IR would misstate the measurement |
| BINARY | — | **not exported**: no PIR modality |
| ENERGY | — | **not exported**: rides the existing RF crossing-event path |

Banned feature keys (`label`, `confidence`, …) are avoided
(`zone_label`). The merge wraps the payload in the standard envelope
via the existing emitter, under the same fail-closed gate (no replay,
no unsecured non-local export).

## 7. Honest limits per modality (read before deploying)

- **Lidar/ToF:** range is excellent (±cm) until it isn't — rain, fog,
  dust, and smoke scatter the beam; glass is invisible; max range is
  a lie told on reflective targets. A "no return" is absence, not
  zero — the protocol distinguishes them.
- **Acoustic bearing:** ±10–20° on a good day with a calibrated array,
  worse with wind. It hears *all* rotating machinery — HVAC, generators,
  distant traffic. A bearing is a direction, not an ID.
- **Acoustic spectrum:** blade-pass tones are real but not fingerprints;
  two drone models can share a band. Useful context, not evidence.
- **PIR:** pet-immunity is marketing. Sun-heated foliage, HVAC vents,
  and small animals all trigger it. Treat as a crude presence hint;
  the ±12 m gate in corroboration is deliberately coarse.
- **Ultrasonic ToF:** soft furnishings and angled surfaces absorb or
  deflect the ping; max ~10 m honest.
- **Cameras:** night, rain, occlusion, and facing-away all produce
  silence — absence of motion means nothing. Motion *presence* near a
  track is meaningful; motion *absence* is not evidence of absence.
- **The meta-rule:** every one of these can be wrong, spoofed, or
  blind. That is why they corroborate and never veto. A $7 sensor
  must never be able to silence the RF tripwire.

## 8. Reference Arduino snippet

Any microcontroller with a UART can speak the protocol. The node
firmware forwards these lines as UDP `sensor_obs` (or the app ingests
them via a serial-attached bridge):

```cpp
// Any sensor, any board: one line per measurement.
void reportRange(const char* id, float dist_m, float angle_deg = NAN) {
  Serial.print("RANGE "); Serial.print(id);
  Serial.print(' '); Serial.print(dist_m, 2);
  if (!isnan(angle_deg)) { Serial.print(' '); Serial.print(angle_deg, 1); }
  Serial.println();
}
void reportPir(const char* id, bool triggered) {
  Serial.print("BINARY "); Serial.print(id);
  Serial.print(' '); Serial.println(triggered ? 1 : 0);
}
void reportBearing(const char* id, float deg, float conf) {
  Serial.print("BEARING "); Serial.print(id);
  Serial.print(' '); Serial.print(deg, 1);
  Serial.print(' '); Serial.println(conf, 2);
}
// Malformed lines are skipped by the app parser — but don't be sloppy:
// validate ranges before printing (dist_m > 0, 0 <= deg < 360).
```

## 9. Files

| file | role |
|---|---|
| `lib/models/sensor_observation.dart` | observation model, corroboration, ZMeta payload |
| `lib/services/sensor_protocol.dart` | UART + UDP parser/serializer (pure Dart) |
| `lib/services/node_udp_hub.dart` | shared UDP 49160 hub (public, refcounted) |
| `lib/services/generic_sensor_driver.dart` | driverId `sensor`: ingest + virtual links |
| `lib/services/camera_driver.dart` | driverId `camera`: webhook + ONVIF + snapshots |
| `lib/screens/sensor_overlay.dart` | map rendering helpers (pure) |
| `test/sensor_protocol_test.dart` | 26 tests |

## 10. Merge seams (for the integrator)

1. `radio_driver.dart`: `case 'sensor': return GenericSensorDriver();`
   `case 'camera': return CameraDriver();` + `driverTypes` entries.
2. `Esp32Driver._Esp32UdpHub` → migrate to `NodeUdpHub` (mechanical).
   Until then, don't enable `esp32` + `sensor` together (bind fight).
3. `app_state.dart`: exclude `sensor:` links from geometric fusion;
   construct one `CameraDriver`, route `onObservation` into the
   shared store; `requestCameraConfirmation` → `recentMotion()`.
4. `settings.dart`: `CameraSettings` UI (all fields exist in the
   driver file).
5. `tracking.dart`: drop `sensorObservationLayer(...)` into the map
   Stack (snippet in `sensor_overlay.dart`).
6. `zmeta_adapter.dart`: wrap `toZMetaPayload()` in the envelope for
   non-null payloads; emit through the existing emitter.
