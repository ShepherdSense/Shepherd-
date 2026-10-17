# Changelog

## 0.15.1 — bug fixes, LoRa nodes, universal sensors, callsigns

Everything the v0.15.0 adversarial review found (HIGH through LOW),
fixed and re-verified — plus the three builds that landed after the
review: LoRa node support, universal sensor ingestion, and node
callsigns. All validated: `flutter analyze` clean, 100/100 Dart
tests, 22/22 SDR bridge tests, firmware compiles in all 5 flag
configs (50-51% flash / 19-20% RAM), ZMeta samples pass
`validate.py --profile H --strict` (0 warnings).

### Bug fixes (v0.15.0 review, HIGH → LOW)

- **Replay:** timestamps re-based on replay (DETECTED banner and health
  work in replay); replays never emit to ZMeta, never sound alerts,
  never contaminate recordings.
- **ESP-NOW relay:** callback restructured (no WiFi-task crash risk);
  250-byte ceiling enforced with a drop counter.
- **LD2450:** corrected 24-byte frame parse + runtime sync-failure
  warning.
- **Variance channel** gated on baseline trust; **ZMeta "link secured"**
  now fail-closed (unsecured non-local export refused, not just
  warned); security warning recomputes while typing.
- **GPS/PPS:** NMEA UTC epoch where available, wrap-safe clocks, real
  lock detection (3 consecutive ~1 s edges), stale coordinates zeroed
  on fix loss.
- Recorder failure handling, UUIDv7 monotonicity, replay watchdog,
  Windows-path basename, and ~15 more LOW findings.

### ZMeta: coordinates + heartbeat

- Per-observation **declared-2D geo** (21.8): the SENSOR position,
  never zero-filled, never fake HAE — device altitude rides in
  `features.shepherd_sensor_alt_m` as labeled metadata. Required the
  v1.1 lane (`kZmetaVersion` 1.0 → 1.1.0).
- Opt-in **PLATFORM_STATUS heartbeat** (default off, 15–600 s,
  fail-closed, never during replay). PEERS.md gains position columns.

### LoRa nodes (two ways in)

- **Meshtastic driver** (TCP 4403, auto-reconnect, GPS→map,
  discovery probe) and **custom SX1276 backhaul** (22-byte binary
  codec, US915/EU868/AS433, ~0.19% duty, star topology) with
  plug-and-play flashers and pre-compiled bins.

### Universal sensor ingestion

- **Shepherd Sensor Protocol**: typed messages (RANGE/BEARING/
  SPECTRUM/BINARY/PIR/ENERGY/MOTION) over UART + UDP 49160; generic
  driver with bounded store; map overlay (range arcs, bearing wedges,
  motion markers); upgrade-only corroboration — sensors can only ever
  raise confidence, never veto the RF tripwire.
- **Cameras**: motion-webhook receiver + ONVIF events, snapshot pull
  for the evidence view, wired into the camera-confirmation contract
  (CORROBORATED / NO_MOTION / NOT_CONFIGURED).
- ZMeta export: only MOTION→EO (validated); acoustic stays local —
  the 1.1.0 ACOUSTIC arm requires a level we don't measure, and
  fabricating one would be exactly the lie the schema guards against.

### Node callsigns

- Operator-set callsigns in the app (tracking screen, validated,
  persisted) or broadcast by the ESP32 in its beacon (set from the
  status page). App-set wins; hardware ID is the fallback. Shown over
  every node type on the map.

## 0.15.0 — capabilities build ("do it all")

New sensing, fusion, and operator-interface capabilities from the
2026-10-16 research pass, plus the ZMeta integration. All validated:
`flutter analyze` clean, 51/51 Dart tests, 20/20 SDR bridge tests,
firmware compiles in all 5 flag configs (50-51% flash / 19-20% RAM).

### Detection: fade-aware tripwire + VRTI second channel

- **Fade-signed detection.** Links now carry a fade level (link baseline
  median vs. network median of link medians); disturbances are judged
  against their *expected* direction — deep-fade links are expected to
  RISE when disturbed, others to DIP. Gate ±3.0 dB. (Wilson & Patwari
  2012; Kaltiokallio et al. 2014.)
- **VRTI variance channel.** A second detection channel fires when the
  mean is quiet but RSS variance jumps (varWindow 12, varK 3.0) —
  catches slow movers the mean channel misses. Firing samples are
  excluded from the variance window so one blip can't pollute it.
- `CrossingEvent` gains `direction` ('dip'/'rise') and `viaVariance`;
  summaries and the evidence view render both honestly.

### SDR bridge: band plans + FHSS signature detector

- `--plan {fpv,dji,longrange,lora}` presets (fpv: 1290/2437/5780 MHz;
  dji: 2437/5780; longrange/lora: 433/868/915).
- Rolling sub-band occupancy detector emits additive `sig_hint`:
  `fhss-2g4` (ELRS-like), `fhss-900m`, `ofdm-5g` (DJI O4-like),
  `tone-5g8` (analog FPV). Signatures, never identity — documented
  honest limits. 20/20 bridge tests pass.

### ZMeta integration (tactical → operational)

- **Emit-only adapter** (`lib/services/zmeta_adapter.dart`):
  CrossingEvent → `OBSERVATION_EVENT`/`RF`, AI label →
  `INFERENCE_EVENT`/`CLASSIFICATION` with genuine lineage, over UDP to
  the gateway (default 127.0.0.1:5555). Validated against ZMeta's own
  `tools/validate.py --strict`: 3/3 pass.
- Documented `power_dbm: 0.0` sentinel (passive link sensors don't
  measure emitter power — follows ZMeta's own sentinel precedent),
  flagged in `quality.shepherd_power_sentinel`.
- **Secured transport (required):** WireGuard hub-and-spoke package in
  `field_kit/zmeta_secure/` (double-click keygen, mesh/gateway configs,
  peer registry). Architecture: Shepherd at the tactical level, ZMeta
  fusing at the operational/strategic level. Full doc:
  `docs/zmeta_deployment.md`. Settings gains a link-secured
  acknowledgment with an honest warning on unsecured non-local targets.

### Firmware (ESP32 node)

- LD2450 24 GHz mmWave radar support (`LD2450_ON`, default off).
- GPS PPS time sync + position in beacons (always on, silent if absent).
- ESP-NOW relay with dedup cache and TTL (default off).
- MPU6050 IMU motion channel (default off) — carrier-motion context,
  never an intrusion signal. All 5 flag combos compile.

### Operator interface

- Event timeline scrubber (tap any event → evidence sheet).
- Honest confidence qualifiers on the alert panel and event rows.
- Alert triage: ACK / FALSE ALARM per event, triage stats, and
  `falseAlarmRate` exposed for human-led threshold tuning (the app
  never auto-tunes).
- Spectrum-band panel (per-band energy bars, SDR only).
- Node health map overlay on the tracking screen.
- Camera confirmation hook (upgrade-only stub; camera may upgrade
  confidence display, never veto a detection).

### R&D tools (offline, not shipped in the app)

- `field_kit/passive_radar/`: passive coherent location demo
  (DVB-T-like illuminator, ECA clutter cancel, CAF + CFAR) — synthetic
  target detected at 0.0% range/Doppler error; honest-scope README.
- `tools/stone_soup_bench/`: Stone Soup tracker prototyping against
  Shepherd-schema CSVs (24/28 tracks matched, purity 0.86 on synthetic).

## 0.14.5 — review pass

Bug fixes and hardening from a full read-through. Dart changes were made
without a Dart toolchain available: run `flutter analyze` and
`flutter test` before shipping. The Python bridge changes ARE tested
(`python field_kit/sdr_bridge/test_sdr_bridge.py`, 7 tests, passing).
The ESP32 firmware was not compiled or flashed.

### Detection correctness (highest impact)

- **Replayed SDR readings defeated "confirm polls".** The SDR driver
  re-reports each band's latest reading on every 0.25 s poll, so a single
  noisy reading was seen 2+ times and satisfied `confirmPolls` on its own,
  and duplicates flooded the baseline. `AppState` now skips readings whose
  timestamp it has already processed (`_lastSampleTs`).
- **SDR links were judged "stale" after 2 s**, though a sweep revisits each
  band every few seconds. That made health flap to DEGRADED and hid band
  links from the banner. Drivers can now declare `sampleMaxAge`; the SDR
  driver uses its 15 s retention.
- **A failed SDR capture was reported as a real -120 dBFS reading**,
  poisoning the baseline and producing a phantom emitter on the next good
  read. The bridge now drops failed/short/non-finite captures. The Dart
  parser also rejects NaN/Infinity.
- **Pluto scaling was data-dependent** (`peak > 1.5` → divide by 32768),
  which could jump ~55 dB between quiet and loud captures. Now a fixed
  12-bit scale.
- **Windows Wi-Fi survey parsed every SSID as "(hidden)".** `netsh` emits
  CRLF and Dart's `(.*)$` can't match across the trailing `\r`, so rogue-AP
  detection never ran on Windows. Lines are now split on `\r?\n`.
- **Wi-Fi APs stayed "disturbed" forever.** `disturbedBssids` was never
  cleared (only on `stop()`), and an AP that vanished while flagged kept
  the DETECTED state stuck. Both fixed.
- **Tracker invented positions from a single link.** With < 3 positioned
  nodes it now returns no fix (the UI says why) instead of an arbitrary
  point on the link, matching the README's "two nodes cannot triangulate".

### SDR bridge

- `--simulate` never tripped the energy tripwire (the scripted emitter was a
  DC tone: +28 dB changed the median by 0.2 dB). The 2.4 GHz burst is now
  wideband; the 915 MHz burst is deliberately narrowband to show the
  median-vs-peak distinction.
- `bw_mhz` was ignored: every band measured the whole 4 MHz capture. Now
  the requested band (clipped to the central 80% of the sample rate) is
  measured and `span_mhz` reports what was actually covered.
- Sub-bands were not in frequency order (unshifted FFT). Now low→high.
- `--dwell N` captured N times but reported only the last. Now averaged.
- Welch-averaged PSD (lower variance → fewer false alerts); DC spike masked.
- New optional packet fields: `peak_mhz`, `peak_dbfs`, `span_mhz`
  (protocol stays `v:1`; old apps ignore them). Beacon every 3 s (was 10)
  and carries a `dropped` counter.
- UDP send errors no longer kill the bridge; bad `--bands` input gives a
  clear message.

### App / state

- SDR pseudo-nodes (`sdr:rtlsdr0`, `sdr:band-433`) were auto-placed into the
  map layout and persisted. They are now excluded.
- SDR events were given mesh-trained AI labels (PASSING/LINGERING…) and
  counted in `simulLinks` / `meshLinks`. Both excluded.
- In-flight polls from a stopped/replaced session could write into the new
  session's history. Guarded.
- Quick START on a cold launch could overwrite saved radios with the legacy
  single-radio default (saved list still loading). START now waits.
- `SdrDriver` bind used `InternetAddress(host)` (IP literals only); falls
  back to all interfaces for hostnames. `probe()` waited 2 s for a beacon
  that came every 10 s, so a healthy bridge usually "failed" — now accepts
  any bridge packet within 5 s.
- Silvus polling opened a new TCP connection 4×/s; now one keep-alive
  client, closed on dispose. Duplicate link directions in one snapshot are
  de-duplicated (they would also satisfy `confirmPolls` alone).
- `RadioConfig.fromJson`: explicit `double` for `pollInterval`.
- Discovery: error text said /16 but anything below /20 was rejected.
- Classifier: NaN features no longer yield a fake label at -100%.
- Wi-Fi threats: the first observation no longer counts as a "flap";
  sighting counts no longer double-increment.
- `AppState.dispose` now cancels the watchdog, drivers, and Wi-Fi sensing.

### Capability

- Tracker velocity is a least-squares fit over the last 12 s of fixes (was
  a two-point difference), so speed/heading are much less jumpy.
- Tracker/shadow grid cost is capped (~20k / ~6k cells) so large meshes
  can't stall the UI thread; refinement window scales with the coarse step.
- SDR driver exposes `latestBands` (incl. `peak_mhz`) for UI panels, and a
  driver-specific "no data" hint on the radio card.
- New tests: `test/tripwire_test.dart`, `test/tracker_test.dart`, extra
  cases in `test/sdr_bridge_test.dart`, `field_kit/sdr_bridge/test_sdr_bridge.py`.

### ESP32 firmware (uncompiled — please build and bench-test)

- **CC1101 was never detected**: VERSION was read with the wrong address and
  without the burst bit (that address range is command strobes, including
  SRES). Fixed; also accepts version 0x04.
- **nRF24 RPD could never report energy**: CE was never driven. New
  `NRF_CE` (GPIO22) is held high — see wiring note in `field_kit/README.md`.
- CC1101 polarity was inverted vs nRF24 (fired when a signal *vanished*).
- Events could stay open forever after a lasting level change; now
  force-closed after 120 s and the baseline relearned.
- Event `t0` was the close time; now the start time.
- UART-supplied sensor names/details are sanitized before going into JSON.
- Frame counters are updated under a spinlock.

### Repo hygiene

- Removed `android/local.properties` (a developer's machine path) and
  `__pycache__/*.pyc` from the archive.

### Known issues NOT fixed (need hardware or a design decision)

- `README`/`CONTRIBUTING` reference `test/ai_golden.json` and
  `test/stitcher_golden.json`; neither is in the archive, so the numerical
  check of the Dart inference kernel against the Python trainer is absent.
- Rogue-AP auto-trust: the AP you connect to is trusted automatically, so
  an evil twin you *joined* is trusted. Needs a UX decision (e.g. confirm
  before first trust).
- Wi-Fi per-AP baseline still lets a lingering disturbance "heal" (the
  Silvus tripwire holds its baseline; the Wi-Fi one doesn't).
- ESP32 CSI only fires on received frames; with no station associated to
  the node's AP the Wi-Fi channel sees nothing.
- The Android package id is still the `com.example.rf_sentry` placeholder.
- The tracker still assumes a single target and a fixed Gaussian falloff
  (`sigma = 11 m`).
