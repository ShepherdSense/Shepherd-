# KrakenSDR bearing ingest — build spec for Shepherd (v0.15.0 candidate)

Prepared 2026-10-06. Feasibility verified against the live Shepherd
codebase and current public references (KrakenRF docs, krakensdr_doa /
krakensdr_suite sources, third-party hardware verification notes).

## Why this, why now

Draco owns a KrakenSDR (5-channel coherent DF, 24 MHz–1766 MHz) alongside
his two Silvus SC4200Ps and a CACI BEAST+. Shepherd today senses
*disturbances* (something crossed the RF field) but cannot sense
*emitters*. A bearing ingest driver closes that gap: tripwire crossing +
emitter bearing at the same timestamp = detection plus direction, and
cross-confirmation kills most false alarms. The Kraken is the easy first
DF integration because its output interfaces are open and documented;
the BEAST+ ingest (CoT) follows the same fusion pattern once CACI's
interface docs are in hand.

## Verified output interfaces (do not re-derive — build to these)

Two generations of Kraken software exist; the driver auto-detects.

**Classic `krakensdr_doa` (Pi image, incl. v1.8.1 — verified on hardware
by a third party, 2026-07):**
- `http://<pi-ip>:8081/DOA_value.html` — positional CSV, rewritten by the
  DSP on every update. Parse the **last non-empty line** positionally:
  `timestamp, bearing, confidence, power, frequency`.
- Bearing field is reported as **360−θ** — the sign/true-vs-relative
  convention MUST be confirmed against his hardware on the bench
  (see Test plan) before the convention is locked in code.
- **Empty file = squelch closed (no signal).** This is a valid state,
  not an error — emit nothing, do not alert, do not mark the driver down.
- Emit an observation only when the DSP timestamp **advances**; a stale
  timestamp means no new measurement.
- Pin the Kraken UI "DOA Data Format" to **Kraken App** for this path
  (DF-Aggregator writes `doa.xml` instead — reserved for later).

**Newer `krakensdr_suite` (Heimdall v2):**
- Local WebSocket broadcast server, default port **8021**, streaming one
  legacy `doapost` record per VFO, captured on a 200 ms tick.
- Records are gated on `doa_enabled`, calibration state, and per-VFO
  squelch — squelch off = bearings always stream; squelch on = only
  while open. Byte-compatible with the map.krakenrf.com / Android app
  contract.
- Prefer this transport when port 8021 accepts a connection; fall back
  to the :8081 CSV poll otherwise.

**KrakenSDR Suite V2 (public beta; C++ rewrite — `heimdall_v2`
server + `kraken_doa_v2` client, repo `krakenrf/krakensdr_suite`) —
VERIFIED against source 2026-10-06; both transports survive:**
- Local WebSocket broadcast, default port **8021**, streams one legacy
  `doapost` record per VFO — **but it is OPT-IN in V2**: enable it in
  the client web UI's "🌐 Web Mapper" panel → Local Network WS
  broadcast (port configurable, default 8021). By design it is
  token-free for LAN readers (host allow-list checked, no Origin
  check). The old Node.js `web_mapper_middleware/` is deprecated and
  no longer needed — Shepherd reads the WS directly.
- `doapost` record schema is **byte-compatible with the V1 / Android
  app / map.krakenrf.com contract** (verified against
  `build_doapost_json` in `web_mapper.cpp`): `station_id`, `tStamp`
  (wall-clock ms at record build — NOT a DSP measurement timestamp),
  `gps_timestamp`, `latitude`/`longitude` (strings), `gpsBearing`,
  `speed`, `radioBearing` (integer 0–359, string — "the integer
  compass bearing, exactly as DOA_value.html serves it"), `conf`
  (2 dp), `power` / `snr_db` (1 dp dB, strings), `freq` (Hz, number),
  `antType`, `doaArray` (comma-separated spectrum), `num_corr_sources`;
  `latency`/`processing_time`/`adc_overdrive` are 0.
- `:8081/DOA_value.html` **still exists** (plain HTTP, token-free, no
  CORS header) — the CSV fallback path works on V2 unchanged.
- Squelch: off = records always stream; on = only while the VFO's
  squelch is open (per VFO).
- Port changes to know: client web UI moved to **:8080** (HTTPS+WS);
  heimdall server web UI on **:8070**. Connect by **IP literal**
  (passes the host allow-list).
- Driver consequences: keep the same auto-detect order (ws :8021
  first, CSV :8081 fallback). If :8021 refuses on a V2 install,
  surface a settings hint — *"on V2, enable 🌐 Web Mapper → Local
  Network WS broadcast in the Kraken web UI"* — before falling back.
  Freshness on the WS path must be measured by **arrival cadence**
  (no record in N s = stale/squelch closed), since `tStamp` is
  record-build wall time, not a DSP clock.
- Bench test and driver validation stay on the **stable V1 generation**
  (the two transports above) until V2 leaves beta. The 360−θ /
  true-vs-relative bearing bench gate stands on both generations.

Station position/heading comes from the Kraken UI (static lat/lon/array
heading) or a gpsd USB GPS — the driver reads the configured values, it
does not do its own GPS.

## Data model (new)

`lib/models/bearing.dart`:

```dart
class BearingObservation {
  final String stationId;      // 'kraken:<station-id>'
  final DateTime timestamp;    // DSP timestamp, not wall-clock
  final double stationLat, stationLon, arrayHeadingDeg;
  final double frequencyHz;    // VFO this bearing belongs to
  final double bearingDeg;     // true bearing, 0-360, convention verified
  final double confidence;     // 0..1, MUSIC-internal — NOT a calibrated Pd
  final double powerDb;
}
```

New abstract `BearingDriver` in `lib/services/bearing_driver.dart`,
mirroring `RadioDriver` but emitting bearings instead of link samples:

```dart
abstract class BearingDriver {
  Future<List<BearingObservation>> pollBearings();
  DriverStatus get status;
}
```

`KrakenDriver implements BearingDriver`, namespaced `kraken:<stationId>`
so a second Kraken (or the BEAST+ driver later) can never collide.

## Fusion (the point of the whole exercise)

- **Map layer:** project each bearing as a line from the station marker
  at `arrayHeading + bearing`. Lines color-coded by confidence, fading
  with age (configurable, default 120 s).
- **Corroborated crossing:** a Silvus tripwire DIP whose timestamp falls
  within ±2 s of a bearing observation is promoted in the event log and
  on the map ("corroborated") — this is the primary false-alarm killer.
- **Fix:** two simultaneous bearings (second Kraken, or BEAST+ later)
  intersect to a position estimate with a simple error ellipse from the
  two confidence values. One bearing alone never claims a position.
- Station placement reuses the v0.7.0 GPS walk-to-node capture (or
  manual lat/lon entry) already in the app.

## UI

- New **BEARINGS** toggle layer on the Tracking map: station marker(s),
  bearing lines, corroborated-crossing highlights.
- Dashboard radio card extended: per bearing-driver status
  (connected / squelch closed / stale / down), current VFO frequency,
  last bearing age.
- Settings: Pi IP/host, transport (auto / CSV / websocket), poll
  interval for the CSV path (default 1 s), station position/heading
  override, bearing age-fade, corroboration window.

## Honest scope (stated in-app and in §6 of the white paper's next rev)

- Bearings exist only for **emitters**. A dark drone is invisible to
  this driver — same blind spot as Remote ID.
- **2.56 MHz instantaneous bandwidth = one band at a time.** VFO
  selection/hopping is configured Kraken-side; Shepherd reads the
  `frequencyHz` on each observation and groups bearings by band. It
  cannot see 900 MHz and 2.4 GHz simultaneously — and note the Kraken
  tops out at 1766 MHz, so 2.4/5.8 GHz drone links belong to the
  BEAST+, not this driver.
- `confidence` is MUSIC-algorithm-internal. It is not a calibrated
  probability of detection — the UI must never present it as one.
- Multipath in cluttered environments smears bearings; accuracy lives
  and dies on array geometry and calibration (use KrakenRF's
  length-matched antenna set / 1 mm harness tolerances).
- Both LAN interfaces (:8081, :8021) are **unauthenticated**. Deploy
  the Kraken Pi on an isolated sensor VLAN; do not expose these ports
  beyond it.

## Test plan

- Unit tests (Dart, same convention as v0.14.0's 9): golden CSV
  fixtures — normal line, empty file (squelch closed), stale
  timestamp (no emit), malformed line (skip + count), multi-VFO lines;
  websocket `doapost` record parsing; bearing-line projection math;
  corroboration-window logic.
- Integration without hardware: `sensorsiot/krakensimulator`
  (ESP32-S3, HTTP API mimicking KrakenSDR, `/api/v1/doa`) as the
  bench double.
- **Bench test against his hardware (required before merge):** park a
  VFO on a known emitter at a known bearing (his own test transmitter
  or a local broadcast station), confirm the 360−θ convention and
  true-vs-magnetic reference against measured geometry, then lock the
  convention in code with a comment citing the bench date.
- `flutter analyze` clean before handover, per standing release bar.

## Build steps

1. `lib/models/bearing.dart` — BearingObservation.
2. `lib/services/bearing_driver.dart` — BearingDriver abstract.
3. `lib/services/kraken_driver.dart` — auto-detect transport,
   CSV parser, websocket client, squelch/stale handling.
4. Tracking map BEARINGS layer + dashboard card + settings.
5. Unit tests + simulator integration; bench test on his hardware.
6. White paper §5/§6 update in the next revision (new "Demonstrated"
   row only after the bench test passes).

## Out of scope for this spec

- Driving the Kraken's VFO/squelch configuration from Shepherd
  (read-only ingest; Kraken UI remains the control plane).
- The BEAST+ CoT ingest driver — same fusion pattern, separate spec,
  needs CACI interface docs.
- Transmit-side anything, on any hardware, ever.
