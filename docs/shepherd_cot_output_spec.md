# Shepherd CoT track output — build spec (v0.15.0 candidate)

Publish Shepherd's fused tracks as Cursor-on-Target (CoT) events so they appear
on ATAK / WinTAK / TAK Server alongside the rest of the COP. Shepherd becomes a
sensor node on the tactical network, not another stovepiped dashboard.

## Why this, why now

- The org already runs ATAK; the BEAST+ already emits CoT onto 239.2.3.1:6969.
  Shepherd tracks showing up on the same net is the single highest-leverage
  interoperability win available — no new hardware, no new sensing.
- This is output plumbing, not new detection. It does not make Shepherd see
  better; it makes what Shepherd sees visible to everyone else.

## CoT primer (emit-only — the minimum the builder needs)

A CoT event is one XML document per track update, sent as a UDP datagram
(multicast) or over TCP (TAK Server):

```xml
<event version="2.0" uid="SHEPHERD.T-0042" type="a-u-G"
       time="2026-10-10T21:30:00.123Z" start="2026-10-10T21:30:00.123Z"
       stale="2026-10-10T21:30:30.123Z" how="m-g">
  <point lat="35.052100" lon="-78.878900" hae="0.0" ce="12.0" le="12.0"/>
  <detail>
    <contact callsign="SHEPHERD T-0042"/>
    <track course="94.0" speed="2.5"/>
    <remarks>Size M (conf 62%). Possible fixed-wing drone — INBOUND TO DEFENDED POINT.</remarks>
  </detail>
</event>
```

Field rules:
- `uid`: stable per Shepherd track. Format `SHEPHERD.<trackId>` — no spaces,
  survives app restarts for the same track only within a run (track IDs are
  per-run; document this).
- `type`: `a-u-G` (unknown ground) default. If the tracker's type guess is a
  drone/fixed-wing/rotary with confidence ≥ 0.5, emit `a-u-A` (unknown air).
  Affiliation is always `u` (unknown) — Shepherd never asserts hostile/friendly.
- `time`/`start`: event timestamp, UTC, millisecond precision, ISO 8601.
- `stale`: `time` + configured stale window (default 30 s). Track loss is
  signaled by letting the event go stale — no explicit delete message.
- `how="m-g"`: machine-generated.
- `point`: lat/lon from the tracker's map position via the GPS anchor
  (defended point or node GPS — whichever the map is registered to). `hae`
  (height above ellipsoid): 0.0 unless node elevation data exists. `ce`/`le`:
  circular/linear error in meters — populate from the tracker's position
  uncertainty when available, else a fixed honest default (15 m) and SAY SO.
- `detail/contact@callsign`: `SHEPHERD <trackId>` (human-readable, spaces OK).
- `detail/track@course`: heading degrees true (0–360). `speed`: m/s.
- `detail/remarks`: free text — size estimate + confidence, type guess +
  confidence, inbound/outbound relative to defended point. Keep under 200 chars.

## Data model (new)

`CotPublisher` service (lib/services/cot_publisher.dart):
- Subscribes to the fused tracker output (same stream the map UI consumes).
- Maintains `trackId → lastSentAt`; emits on: new track, position/heading
  update, type-guess change. Throttle: max 1 update/sec per track.
- Owns the map-meters → lat/lon projection (reuse the map's existing GPS
  anchor; do not invent a second one).
- Owns the type-code selection (`a-u-G` vs `a-u-A`) and remarks formatting.
- Emits nothing when: publisher disabled, no GPS anchor set (can't project —
  log and skip), or track confidence below the publish floor (default 0.3,
  configurable).

No changes to the tracker itself. The publisher is a read-only consumer.

## Transport

Two destinations, multicast default:
1. **UDP multicast 239.2.3.1:6969** (default CoT multicast group — the same
   group the BEAST+ CoT capture tool listens on). Zero-config on a LAN with
   ATAK clients. One datagram per event.
2. **TAK Server TCP** (default port 8087 — plaintext TCP; 8089 is TLS and needs client certs, which this publisher does not do): persistent connection, reconnect
   with backoff. For the enterprise net. TLS left to the server's config;
   the publisher sends plaintext CoT over the established socket.

Config (settings, behind the gear — defaults are sane):
- Enable/disable (default OFF — publishing to a tactical net must be a
  deliberate act).
- Destination: multicast group/port or TAK host/port + protocol selector.
- Callsign prefix (default `SHEPHERD`).
- Stale window seconds (default 30).
- Publish confidence floor (default 0.3).
- Air-type confidence threshold (default 0.5).

## UI

- One toggle + destination fields in Settings → Output. Status line on the
  dashboard when active: "CoT → 239.2.3.1:6969 · 3 tracks publishing".
- No map changes. No new permissions.

## Honest scope (stated in-app and in the white paper's next rev)

- Positions are RF-derived estimates with stated error (ce/le on every event).
  They are not targeting-grade.
- Affiliation is always unknown. Shepherd does not declare hostile/friendly.
- This is a sensor feed, not C2. No fire-control, no weapon cueing language
  anywhere in the UI or remarks.
- Track IDs are per-run; a restarted app re-numbers. Consumers must key on
  uid + stale, not assume persistence.

## Test plan

1. Unit: XML golden test — known track in → byte-exact expected event out
   (modulo timestamps). Type-code selection table test (ground vs air).
2. Throttle test: 10 updates in 200 ms → exactly 1 datagram.
3. Bench: WinTAK or ATAK-CIV on the same LAN, multicast destination.
   - New track appears as `a-u-G` marker with SHEPHERD callsign.
   - Marker moves as the (simulated) track moves; course/speed readouts update.
   - Kill the track → marker disappears after the stale window, no ghost.
   - Remarks show size/type/confidence text.
4. TAK Server path: single TCP test against a local TAK server container;
   verify reconnect after server bounce.
5. Gate: no merge until the bench test passes on real hardware with the
   operator watching both Shepherd's map and ATAK side by side.

## Build steps

1. `lib/services/cot_publisher.dart` — subscription, throttle, XML builder,
   transport (UDP multicast + TCP client).
2. `lib/services/geo_projection.dart` — map-meters → lat/lon via the existing
   GPS anchor (extract if currently inline in map code).
3. Settings UI: Output section (toggle, destination, prefix, stale, floors).
4. Dashboard status line when publishing.
5. Unit + golden tests; bench test per §Test plan.

## Out of scope for this spec

- CoT *ingest* (displaying others' CoT in Shepherd) — separate spec, separate
  value proposition. The BEAST+ receive path is the MRSI driver, not this.
- Remote ID decode, ADS-B ingest — separate specs.
- TAK Server auth/TLS client certs — deployment config, not app code.
- Any transmit beyond our own track events. The publisher never sends
  anything that isn't a Shepherd track.
