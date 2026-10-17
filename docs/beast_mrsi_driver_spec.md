# BEAST+ / Mastodon MRSI bearing ingest — build spec for Shepherd (v0.15.0 candidate)

Prepared 2026-10-08. Interface verified against the document Draco
provided: `MRSI_API_-20261008T134141Z-1-001.zip` →
`MRSI API /MRSI_ASync_API_Core_Summary.md`
("Mastodon Remote Sensor Interface (MRSI) API — Summary Overview",
**MRSI 10.5.0**, Document Version 1.0, support mastodon-support@caci.com).

## Why this, why now

The parked question — *"which interface does the BEAST+ actually
expose?"* — is now answered. Not the un-documented LAN CoT multicast
(stood down 2026-10-07), not the EUD-in-the-loop taky route, not an
Ice Bucket export. The unit exposes a documented **JSON-over-TCP
command interface plus client-directed UDP data streams** — the Mastodon
Remote Sensor Interface. It publishes exactly the data products
Shepherd's bearing ingest needs: **lob / lobext** (line-of-bearing,
extended LOB with confidence), **hits** (detection events), **psd**,
**compass**, plus multinode **mn.lob / mn.gps / mn.geo**. This makes the
BEAST+ the emitter-bearing half of Shepherd's fusion story: tripwire
disturbance + emitter bearing at the same timestamp = detection plus
direction, and the corroboration kills most false alarms.

## Verified interfaces (do not re-derive — build to these)

From the summary (§2, §10):

- **TCP command socket**, default port **10051**. Persistent connection
  for commands/control. TCP keepalives maintain it; **all subscriptions
  terminate if the connection drops**.
- **UDP data streams** to a **client-specified IP/port** — Shepherd
  tells the unit where to send; no fixed multicast to chase.
- **Multicast discovery (optional):** hello messages on
  **239.2.3.27:10050**. The driver should listen first, then fall back
  to the configured IP.
- **Message format: JSON**, all requests/responses (no binary command
  framing). Request shape from §10.1:

      {"type": "connect_req"}
      {"type": "command_req", "id": "clientHandle",
       "command": "rf_frequency", "endpoint": 0,
       "args": {"frequency": 462000000}, "request_id": "..."}

  Result codes: ok / invalid_client / invalid_command /
  invalid_argument / invalid_endpoint / invalid_stream / op_failed /
  bad_request.

Connection handshake (§10.1): `connect_req` → receive unique client
handle → `version_req` (MRSI version + system capabilities) →
`available_streams_req` → `subscribe_req` with `stream_id`, `data_type`,
`ip`, `port` → receive on UDP → `unsubscribe_req` / `disconnect_req`.

Stream IDs to subscribe to (§4): the Shepherd-relevant set is

- `lob` — line of bearing, JSON
- `lobext` — extended LOB **with confidence**, JSON
- `hits` — signal detection events, JSON
- `compass` — heading information, JSON (station heading reference)
- `psd` — power spectral density (optional, future spectrum strip)
- `mn.lob` / `mn.gps` / `mn.geo` — multinode: LOB from distributed
  nodes + calculated geolocation results (if a second node exists)

Station position comes from **`info.gps`** (§3.2: GPS position and fix);
health from **`info.status`** (battery, CPU, temperature).

**What is NOT in this summary (honest gaps, §"Document Version 1.0"):**

1. The **field-level JSON schema** of `lob` / `lobext` records
   (field names, bearing units/precision, timestamp format) is not
   spelled out — only that they are JSON. Do NOT lock field names in
   code until one of: (a) the full **AsyncAPI 3.0 spec** is obtained
   from CACI support, or (b) a real record is captured with
   `mrsi_handshake.py --subscribe lob` and the parser is built to the
   captured shape.
2. TCP framing is not specified — assume newline-delimited JSON with
   an incremental-parse fallback (as implemented in the handshake
   tool); confirm against the live unit.
3. Exact `stream_id` naming (`simple.lob.0.0` style vs. other) is only
   exemplified for IQ — `available_streams_req` is the source of truth
   at runtime; the driver must enumerate, never hardcode.

## Data model (shares the planned bearing abstraction)

Same abstraction as the Kraken spec (`docs/kraken_driver_spec.md`):
new `lib/models/bearing.dart` → `BearingObservation`, new abstract
`lib/services/bearing_driver.dart` → `BearingDriver`. Whichever driver
is built first introduces them; both drivers emit into it.

- `MastodonDriver implements BearingDriver`, station IDs namespaced
  **`beast:<station-id>`** — a Kraken and a BEAST+ can coexist, and so
  can two BEAST+ nodes (`mn.geo` fixes become natural later).
- `frequencyHz` on each observation comes from the LOB record /
  `info.mission`; bearings group by band. The BEAST+ typical RX range
  is **30 MHz – 6 GHz** (Appendix A), which is what covers the 2.4 /
  5.8 GHz drone bands the KrakenSDR cannot reach.
- Silence = no emitters = valid state, not an error — same rule as the
  Kraken's squelch-closed. Emit nothing, do not alert, do not mark the
  driver down. A dropped TCP connection = subscriptions dead → mark
  down and reconnect.

## Fusion (same pattern as the Kraken spec)

- **Map layer:** bearing lines from the station marker; color by
  confidence, age-fade (default 120 s); station marker from `info.gps`
  (or the walk-to-node capture / manual override already in the app).
- **Corroborated crossing:** a Silvus tripwire DIP within ±2 s of a
  bearing observation is promoted in the event log and on the map.
- **Fix:** two simultaneous bearings (second BEAST+ node via `mn.geo`,
  or Kraken + BEAST+) intersect to a position estimate with an error
  ellipse. One bearing never claims a position.
- `hits` events feed the same event-log pipeline as the Kraken's
  detection events would.

## UI

- Shares the planned **BEARINGS** toggle layer on the Tracking map
  (station markers, bearing lines, corroboration highlights).
- Dashboard radio card: driver status (connected / no-emitters /
  stale / down), current mission mode, last bearing age.
- Settings: unit IP/host (auto-discovery via 239.2.3.27:10050 first),
  command port, subscribe list (lob/lobext/hits…), bearing age-fade,
  corroboration window, station position/heading override.

## Honest scope (stated in-app and in the white paper's next rev)

- **Bearings exist only for emitters.** A dark drone is invisible to
  this driver — same blind spot as Remote ID.
- `lobext` confidence is algorithm-internal, not a calibrated
  probability of detection — the UI must never present it as one.
- **Shepherd is receive-only on this interface.** The MRSI API also
  exposes Electronic Attack commands (`ea_sweep_req`,
  `ea_sweep_effectiveness_req`, `ea_stop`) — Shepherd never invokes
  them, and never issues `rf_*`, mission, SOI, or scan commands either:
  the unit's own control plane stays authoritative. Shepherd
  subscribes to sensor streams and nothing else.
- **No authentication is described in the summary** for the TCP command
  socket. Deploy the BEAST+ on an isolated sensor network; do not
  expose port 10051 beyond it.
- Bearing accuracy lives and dies on the DF head's calibration and
  multipath — the BEAST+ DF head does 2/3/4-channel phase
  interferometry, 30 MHz–6 GHz; state bearing quality honestly,
  especially in clutter.
- The summary is Document Version 1.0 of MRSI 10.5.0 — confirm the
  unit's firmware MRSI version with `version_req` on first connect and
  note it in the settings log.

## Test plan

- Unit tests (Dart, same convention as v0.14.x): `connect_rep` /
  `command_rep` parsing incl. all result codes; `lob`/`lobext` JSON
  parse against **captured fixtures** (not invented shapes); garbage
  record handling (skip + count); dropped-TCP → down-state; no-record
  window → no-emitters (not down); bearing-line projection math;
  corroboration-window logic.
- `mrsi_handshake.py` (in `~/workspace/your_files/`, 8/8 self-test
  2026-10-08) is the bench gate: discovery → `connect_req` →
  `version_req` → `available_streams_req` → optional
  `--subscribe lob` capture. The first `--subscribe lob` capture on
  his hardware is what locks the record schema.
- **Bench test against his hardware (required before merge):** park a
  VFO/mission on a known emitter at a known bearing, confirm the
  bearing reference (true vs. magnetic, sign convention) against
  measured geometry, then lock the convention in code with a comment
  citing the bench date — same gate as the Kraken spec.
- `flutter analyze` clean before handover, per standing release bar.

## Build steps

1. `lib/models/bearing.dart` — BearingObservation.
2. `lib/services/bearing_driver.dart` — BearingDriver abstract.
3. `lib/services/mastodon_driver.dart` — TCP session (connect,
   keepalive, reconnect), discovery listener, stream subscription,
   UDP record ingestion, `beast:` namespace.
4. Tracking map BEARINGS layer + dashboard card + settings
   (shared with the Kraken driver).
5. Unit tests + handshake capture against his hardware; bench gate.
6. White paper §5/§6 update in the next revision (new "Demonstrated"
   row only after the bench test passes).

## Out of scope for this spec

- Any Shepherd-initiated mission/SOI/scan/`rf_*` configuration, and
  all EA commands — read-only ingest, permanently.
- The KrakenSDR driver (separate spec; shares the abstraction).
- Transmit-side anything, on any hardware, ever.
