# Skydio Integration Spec — Shepherd

Status: SPEC (2026-10-21). Source research:
`~/workspace/research_notes/skydio-integration-surfaces-2026-10-21.md`
(CONFIRMED / WIDELY REPORTED / CLAIMED labels preserved from there).
Operator decisions: integrate Skydio BOTH ways (friendly + detection),
make his X10Ds sensors, design for both radio fits, Drone tab with
viewer-side camera switching.

## Corrections to earlier assumptions (read first)

1. **No factory Silvus option exists.** The Silvus path is the
   third-party **FLYMOTION AirMesh** payload (announced 2026-10-14):
   a Silvus StreamCaster LITE 5200 (SL5200) on the X10D's payload
   interface. A procurement item, not a current fit.
2. **His X10Ds may broadcast no Remote ID at all.** X10D is exempt
   from FAA Part 89; federal X2Ds are generally exempt. The Remote ID
   decoder catches CIVIL Skydio fleets (X10/X2E — Wi-Fi Beacon,
   SkySafe-tested fully compliant), not necessarily his airframes.
   His friendly path is CoT/telemetry, never RID.
3. **Native Skydio link metrics are not exposed anywhere public.**
   The standard fit can never be an RF sensing node — position only.

## Capability classes (runtime discovery, no config toggle)

An airframe is classified by the evidence that actually arrives.
Promote on evidence; never demote on silence.

- **Class A — full sensing node.** StreamScape per-link metrics
  (SNR/MCS) for a node whose position moves in 3D. Only reachable
  via AirMesh/SL5200 on the mesh (or any future MN-MIMO fit).
  Links to ground nodes become Shepherd sensing links; the fusion
  layer must handle a moving airborne endpoint (ego-motion rules
  from the mesh-mode spec apply, extended to altitude).
- **Class B — position node.** CoT, MAVLink, or cloud telemetry
  (position, altitude, battery, camera frustum) with no link
  metrics. Friendly track + geometry participant, not a sensing
  link endpoint.
- **Class C — broadcast contact.** Remote ID only (civil fleets).
  Whitelist-checked; renders as FRIENDLY (claimed) on a serial
  match — RID is unauthenticated and spoofable, so the label always
  carries "(claimed)" until corroborated by a Class A/B feed.
- **Class D — RF cue.** In-band emitter energy/DF only. Bearing cue
  on the map, NEVER labeled "Skydio" (links are proprietary,
  AES-256, FHSS — energy cannot attribute a platform).

## Ingest routes, in build order

1. **Controller CoT (his fleet, offline, first).** ATAK runs on the
   Skydio controller; Skydio documents TAK-server setup; the
   existing CoT listener ingests it. Zero accounts, works with no
   internet. This is how his X10Ds appear as Class B friendly
   tracks on day one.
2. **Remote ID decoder (detection).** BLE + Wi-Fi Beacon Remote ID,
   pure-Dart decode (feasibility checked 2026-10-05). Serial,
   drone position, operator position. Sees civil Skydio and every
   other compliant broadcaster. In-app honesty label: broadcast-
   only; absence of RID never means absence of a drone.
3. **Skydio Cloud API poller (optional, later).** REST
   api.skydio.com/api/v0, org-admin scoped read-only tokens,
   polling + webhooks; `/vehicles` roster auto-populates the
   friendly whitelist. Caveat designed-in: X10D is the offline
   variant — a tactical fleet may never touch the cloud; the
   poller is an enhancement, never a dependency.
4. **AirMesh/SL5200 (when procured).** No new driver: the SL5200 is
   a Silvus node; the existing Silvus driver + node-identity
   mapping (callsign/serial registry) promotes the airframe to
   Class A automatically when its links appear in StreamScape.
5. **Payload detections (opportunistic).** ISR Command (Oct 2026)
   shares operator-tracked subject positions as TAK markers + MISB
   ST 0601/0903 KLV in video — ingested via the CoT listener and
   the video tab respectively. No raw-detection API exists
   publicly; do not design for one.

## Friendly whitelist

- Fields: ANSI serial, callsign/tail label, class hints.
- Population: manual entry of battery-tray serials (right-sized
  for a handful of airframes) + optional Cloud `/vehicles` sync.
- Match: RID serial string equality → Class C FRIENDLY (claimed);
  CoT/cloud identity → Class B FRIENDLY. A whitelist match NEVER
  suppresses a track or an alert by itself; it changes rendering
  and correlation priority only (detection stays deterministic,
  per Shepherd's standing rule).

## Drone tab

- **Feeds:** EO and thermal are SEPARATE SIMULTANEOUS streams from
  the aircraft — viewer-side switching between them is just stream
  selection in the tab. No control channel needed, pilot untouched.
  - Primary path: vehicle-direct RTSP on the local link
    (documented for the RAS-A/external-radio fit:
    `rtsp://192.168.42.10:5554/subject` EO, `:6554/infrared` IR,
    H.264/MPEG-TS + MISB 0601) — mesh-local, no internet.
  - Secondary path: Skydio Cloud dual RTSP (webhook announces URL +
    stream type per serial) for reach-back viewing.
- **Wide ↔ tele is NOT viewer-switchable.** Both are focal choices
  inside the single EO stream, selected by the pilot (or Remote
  Flight Deck / gated MAVLink camera service). The EO feed is
  labeled "PILOT'S FOCAL VIEW" in the tab — never imply the viewer
  controls it.
- **Layout:** feed picker (EO / THERMAL) as big segmented control;
  per-drone selector when multiple airframes stream; MISB 0601
  telemetry (airframe position/heading, sensor frustum) overlaid
  when present in the stream; stream health (bitrate/freeze)
  shown honestly; default stream bitrate ~4 Mbps (DroneSense
  guide) — Skydio publishes NO latency figure, so none is shown.
- **Out of scope for the tab:** flight control, gimbal control,
  pilot-focal switching, recording to cloud. Camera switching in
  this spec = stream selection only; no new transmit/control
  surface is added to Shepherd.

## Honesty rules (binding)

- Class D energy is never attributed to a platform.
- FRIENDLY (claimed) until a Class A/B feed corroborates.
- The RID-exempt status of D-model airframes is stated in-app
  wherever the decoder's coverage is described.
- No latency, range, or detection-probability numbers beyond what
  sources state; Skydio publishes no stream latency — show none.

## Build phases

- **P1:** Class B via controller CoT (identity registry + friendly
  rendering + whitelist manual entry) — no new ingest code, mostly
  identity/classification work in the merger.
- **P2:** Remote ID decoder (Class C) + whitelist matching +
  FRIENDLY (claimed) rendering.
- **P3:** Drone tab — dual-stream RTSP viewer (EO/thermal switch),
  MISB 0601 overlay, stream health. Player approach TBD at build
  (evaluate media_kit / flutter VLC-class options against the
  H.264/MPEG-TS + KLV requirement).
- **P4 (optional/procurement-gated):** Cloud API poller + roster
  sync; AirMesh Class A promotion (driver-free; fusion work only);
  ISR Command marker ingest.
