# Changelog

## v0.27.0 — 2026-10-28 — PMR preamble-jamming monitor (EXPERIMENTAL)

Live-data gateway jamming monitor for the LoRa backhaul, from Herrera-Loera et al., Sensors 2026, 26(19), 6123 (a simulation-only paper — its numbers are NOT thresholds here). The SDR bridge stares at the backhaul channel (SF7/125 kHz) and computes a dechirp-domain peak-to-mean ratio (PMR) per preamble: dechirp each preamble symbol against an ideal reference, DFT, dominant-bin magnitude / mean spectral magnitude, averaged over the preamble upchirps. PMR is a separate decision alongside the RSS-anomaly + gap/sync-failure alerts — never fused, never a tripwire input, never vetoing. Report-only until live traffic sets a real threshold (no sim-derived threshold baked in); pass `--pmr-threshold` to enable alerting. See `docs/pmr_monitor_spec.md` for the statistic, limits, and live-test procedure. RX-only throughout; gateway .ino and node firmware untouched. Verified in this workspace: `flutter analyze` clean, full suite 583/583; bridge suites 103/103.

## v0.26.1 — 2026-10-25 — review-fix pass (from a PC-side static review of v0.26.0)

Small, behavior-preserving fix set; no features, no gateway/CoT/ZMeta changes, no detection-path changes. Verified in this workspace: `flutter analyze` clean, full suite 576/576 (573 v0.26.0 baseline + 3 new v0.26.1 tests).

- AppState.dispose(): cancel the ZMeta fix/heartbeat timers and the Remote ID Wi-Fi poll (they kept firing after dispose).
- SensorsPlusStepSource.start(): a synchronous throw from the accelerometer stream (platforms without motion sensors) now degrades to "no steps" + lastError instead of crashing Hunt start; never adds to a closed controller.
- TileCache: manifest writes serialized and atomic (temp + rename). Concurrent writes could corrupt the manifest, and a corrupt manifest deletes every cached tile on next launch.
- tilesForBounds: O(n) de-duplication (was O(n^2) List.contains).
- Tracker.update: guard against non-positive/non-finite max dip (NaN grid scores); reports a missed poll instead.

## v0.26.0 — 2026-10-24 — Fieldwatch-borrow build (Remote ID hardening/labels, signature library, Hunt, phone-only tier, offline maps)

Phone/EUD-first build borrowing five Fieldwatch (OffGridPete, MIT)
ideas — concept adapted, no Fieldwatch code or catalog data copied.
Defensive-only, RX-only throughout; no gateway, CoT, or ZMeta
changes; no detection, tracker, or merger code paths touched. All
five items are additive and opt-in; default behavior for existing
mesh users is unchanged.

- **Remote ID — harden, label, prove (NOT new).** Remote ID
  decoding shipped in v0.22.0; this release hardens, labels, and
  proves it instead of re-implementing it. Audit of
  `remote_id.dart` / `remote_id_service.dart` for malformed and
  short frames, with regression tests (truncated message, bad type
  nibble, oversized pack count, empty service data, stale contact
  expiry). Two service-layer crash fixes: (a) the BLE
  advertisement path now decodes before ingesting, so empty or
  garbled service data fires no spurious onUpdate (correction,
  v0.26.0 fix-pass: the real BLE fix was the spurious update —
  ingest already early-returned on empty lists, so no contact
  was ever created by empty data); (b) the Wi-Fi survey poll now
  treats a throwing
  survey source as a soft no-op and skips rows with a non-string
  BSSID or non-numeric beacon elements instead of `as`-casting
  them — the old casts threw and took the whole poll down with one
  bad row, and skipped (never ingested under a shared 'unknown'
  key, which would have merged distinct drones into one contact). RID records now render `COOPERATIVE (RID)` (with
  transport, e.g. `COOPERATIVE (RID · BLE)`) as a second marker
  line on the Tracking map, visibly distinct from mesh tracks.
  Proven by test: RID evidence never feeds detection, the tracker,
  or the confidence merger, and never suppresses or downgrades a
  mesh track/alert. Wi-Fi NAN Remote ID is NOT implemented —
  stock Android does not expose NAN frames to the app; the RID
  help copy in Settings now says so, and BLE 5 extended
  advertising is labeled platform-dependent. Never faked.
- **Wi-Fi/BLE signature library — "what's around me" (opt-in,
  default off).** New `lib/services/device_signatures.dart`: a
  const built-in catalog matched against phone-visible Wi-Fi scan
  results and BLE advertisements, returning ranked candidate
  device classes with firing evidence. User-added signatures load
  from `device_signatures.json` in the app documents directory
  (read by AppState via path_provider — the service itself does
  no file I/O) and merge over built-in entries; user entries are
  labeled USER-ADDED wherever they surface. Every match is
  labeled HYPOTHESIS, never identity, in code and in UI strings;
  catalog entries are grounded in a public assignment (Bluetooth
  SIG company ID / service UUID, IEEE OUI) or marked
  UNVERIFIED/COMMUNITY. Malformed user JSON degrades to built-in
  only with a warning surfaced in Settings (never a crash, never
  a silent whole-catalog drop). Settings shows built-in +
  user-added + merged counts and a reload button. Live match
  surface (v0.26.0 fix-pass): when the switch is on, Wi-Fi Vision
  access-point rows show each row's best hypothesis match label
  (display-only; matching creates no detection, track, or alert).
- **Hunt heat-map mode (opt-in).** New `lib/services/hunt_tracker.dart`
  (pure-Dart core) plus `lib/screens/hunt_screen.dart`: a selected
  emitter's RSSI samples accumulate into a spatial heat grid with
  decay/aging (driven on a ~5 s timer) and a highlighted loudest
  cell; motion-sensor steps (`sensors_plus`, added to pubspec)
  carry the walk between GPS fixes. Output is PROXIMITY ONLY —
  NOT A POSITION FIX, labeled on the screen. Feedback wires
  onBeep to a system click + visual flash and onVibrate to
  haptics; there is NO audio plugin in this build, so the beep is
  a system click, not a dedicated tone (documented on-screen).
  TileBackgroundPainter paints the bottom layer when a cached
  origin tile is available; missing tiles render the NO CACHED
  TILE grid, never an invented map. Entered from the dashboard
  (phone-tier banner, or the always-visible HUNT button in the
  SOURCE card) — deliberately not a new bottom-nav tab.
- **Phone-only tier.** New `lib/services/phone_tier.dart`, wired
  in AppState from live driver state (mesh poller / SDR-bridge /
  Kraken / ESP32 poller / simulated mode), recomputed on every
  attachment change (start/stop already notify). The tier is
  active ONLY when its switch is on (default true — but mesh
  users see zero change, because any attached hardware deactivates
  it) and no mesh/SDR hardware is attached. When active, the
  dashboard shows its mode and range labels verbatim:
  `PHONE-ONLY · PHONE-RANGE · tens of meters, not area
  coverage`, plus the phone sources it exposes (BLE scan, Wi-Fi
  survey, Remote ID, signature library, Hunt) — never presented
  as mesh-equivalent. Unavailable sources degrade to off and are
  named, never silently dropped.
- **Offline maps pattern.** New `lib/services/offline_map_source.dart`:
  keyless tile sources only (OpenStreetMap Standard, USGS
  Imagery, USGS Topo — URL templates, no paid keys, no
  Esri/MapTiler/Stadia/Thunderforest built in; the keyless
  constructor refuses any template carrying a key parameter), a
  cache-first 50 MB LRU disk cache (http + path_provider,
  stale-on-error), and a CustomPaint-compatible tile-background
  painter. Settings carries a keyless-only tile-source dropdown
  (default OSM); the Hunt screen paints the cached origin tile
  underneath its grid.
- **UNVERIFIED until hardware runs it:** all live-RF and on-device
  behavior in this release — Hunt step accuracy (0.75 m step
  length is an assumption, not a measurement), the
  SensorsPlusStepSource adapter on a real phone (its detector is
  unit-tested; the adapter itself cannot be exercised without
  hardware), phone-OS scan quotas and randomized-MAC hiding,
  tile fetching on a real EUD, and the Hunt screen's manual
  hunt-local position entry (no live GPS feed is wired into the
  screen in this build — the onGpsFix plumbing is real, the feed
  is operator-entered). Hunt disclosure (v0.26.0 fix-pass):
  samples (RSSI + position) are operator-typed in this build, no
  live RSSI/GPS feed is wired in, and step distance is
  informational only — with no heading source it never places
  samples. No performance numbers are claimed
  anywhere in this release.
- **Reviews + tests.** `flutter analyze` clean (no issues);
  full `flutter test` 550/550 passing (v0.25.0 base 472 plus the
  v0.26.0 service suites: Remote ID audit/never-override,
  signature, Hunt, phone-tier, and offline-map tests).

## v0.25.0 — 2026-10-24 — Research-sweep build (BSense tracker gating, Kim tuning, LTE + 5G SDR-bridge adapters)

The actionable items from the 2026-10-24 research sweep (lanes 1+2).
Defensive-only throughout; no new transmit anywhere — the LTE and 5G
paths are receive-only illuminators of opportunity, and the tracker
gates are opt-in (default app behavior is unchanged; `app_state.dart`
wiring is deferred to a follow-up, see below).

- **BSense tracker gating (lane 2, Meng et al. 2026, portable parts
  only).** (a) Per-spatial-cell Gaussian clutter fingerprint +
  Mahalanobis gating replaces global thresholds for link-shadow
  false alarms (adapted to link dips — Shepherd has no point
  clouds; cell size/refresh mapped from the paper's 40 m cubes /
  700 frames and documented in
  `docs/bsense_tracker_gating_spec.md`). (b) Decayed (0.9)
  spatial/velocity consistency confidence as a false-track gate
  (report by default; strict veto is opt-in). Known limits carried
  in code and docs: tangential-flight blindness, 50–100 m-style
  occlusion gaps, and Doppler/continuity assumptions exploitable
  by a knowledgeable operator. BSense's 1 km range and F1 95.56%
  are NEVER claimed for Shepherd — they belong to carrier 5G-A
  hardware Shepherd does not control. TrajFormer (the paper's
  stage 3) was deliberately not ported.
- **MilaGro gate pattern (lane 1, Picazo-Martinez et al. 2025).**
  The sharpest/shortest-range channel gates (prunes) the
  broad-coverage channel's search space, same shape as
  anti-fade-link gating. No ML, no CNN imported.
- **Size-aware detection thresholds (lane 1, Kim et al. 2025).**
  Slim targets degrade detection, so thresholds are size-aware
  (S 0.7 / M 1.0 / L 1.3 starting estimates, to field-calibrate),
  not one global threshold. The 6-node/15-link ~1–2 m imaging
  bound is NOT upgraded on this paper.
- **Kim tuning discipline (lane 1).** Elastic Net α and
  path-thickness γ are now tuned by optimization on recorded
  data (deterministic grid search; the paper used Bayesian
  optimization) instead of hand-picked, with tuned values logged
  per deployment (provenance required, no default); DBSCAN-on-
  binarized-image is the blob extractor. Demonstration data is
  harness-generated, documented as NOT field data — the machinery
  is data-agnostic and accepts recorded scenes. Field re-tuning
  per deployment is required before trusting any tuned (α, γ).
- **LTE illuminator adapter (lane 2, SDR bridge, RX-only).**
  FDD LTE downlink bands (including LTE450, opt-in only) as
  passive-radar illuminators feeding the Doppler-only refinement
  layer (0.5 s CPI → ~2 Hz / 0.16 m/s radial resolution).
  Presence is shape-only — never identity, never position, no
  payload bits touched. FKIE LTE450's ~1.6 km bistatic figure is
  CLAIMED (single secondary source, full text UNREAD) and is NOT
  a Shepherd capability; the bridge ships a bench log (hits AND
  misses) so a measured curve can replace it. LTE sweep presence
  is bridge-only pending an app consumer; the stare path surfaces
  via the existing `doppler_ref` parser.
- **5G NR adapter (lane 2, SDR bridge, STUB — stated plainly).**
  The bridge runs at 4 MSPS (3.2 MHz usable span) against
  20–100 MHz NR channels, so claiming NR detection would be
  faking a capability. `Nr5gAdapter` gates on USRP-class
  hardware at ≥20 MSPS, is inert otherwise, and emits NO NR
  packet in any v0.25.0 configuration. The interface exists for
  a future wideband capture path.
- **Reviews + tests.** Two independent reviews (both
  SHIP-AFTER-FIXES); all 3 blockers, 20 should-fixes, and nits
  fixed with regression tests, including: gate evaluation at
  0.25 s poll cadence, veto state snapshot/restore, per-poll
  refresh counting with trusted-cell floor, quiet-only
  fingerprint learning, bounded-window LTE quiet reference,
  stare-only Doppler routing, and bench miss rows. `flutter
  analyze` clean; `flutter test` 472/472; bridge suite 83/83;
  Kim suite 11/11.

## v0.24.0 — 2026-10-23 — Research-sweep build (FHSS threshold, classifier retrain, dropout bench, TinyML boundary)

The four remaining actionable items from the 2026-10-23 research
sweep (lanes 5+6). Defensive-only throughout; no new transmit,
detection, or alerting behavior — the classifier still only labels
what the deterministic tripwire found, and never suppresses alerts.

- **FHSS percentile-adaptive threshold (lane 5, Șorecău et al.
  2025).** The SDR bridge's noise floor is now the **20th
  percentile** of each capture (`NOISE_FLOOR_PCT`, `noise_floor_dbfs`
  in `sdr_bridge.py`), replacing the 10th percentile; the signature
  scorer's hot threshold stays floor + 12 dB and now tracks a
  rising/drifting floor. UDP packet format unchanged. Measured
  behavior changes: `noise_dbfs` and hot thresholds read ~0.8 dB
  higher on a flat floor; the ELRS chirp CPU gate is ~0.8 dB
  stricter on marginal captures; thresholds no longer collapse
  (~10 dB) when 10–20% of a band sits in a fade/filter notch
  (past ~20% notched, any percentile estimator lands in the notch).
  Only the paper's detector design was ported — nothing from its
  jamming path. 6 new Python tests (63/63 bridge suite).
- **Synthetic corpus regeneration + retrain (lane 6, WiFi-JEPA).**
  `tools/train_disturbance_clf.py` now generates trajectory-diverse
  examples — randomized speeds, headings, start points, loiter
  durations, gait wobble, body-shadow dropouts — instead of
  near-fixed trajectories (which caused negative transfer in the
  paper). Retrained weights ship in
  `assets/models/disturbance_clf.json`; the 10-feature contract and
  JSON schema are unchanged. Synthetic holdout: 0.967 on the new
  (harder) corpus vs 0.994 for the old model on its narrow corpus;
  on a shared trajectory-diverse bench set the old weights score
  0.868 vs the new 0.961. **Synthetic accuracy does not establish
  field accuracy** — no real-data validation exists yet.
- **Link-dropout bench (lane 6, link-masking ablation).**
  `tools/bench_link_dropout.py` + `docs/link_dropout_bench.md`:
  accuracy vs 0–14 dropped links is flat for the shipped model
  (0.961 → 0.956), and link-dropout augmentation (feature-level
  masking on the aggregate link-count features, exactly as the
  runtime would see it — see the bench doc's explicit runtime
  assumption) beats the no-augmentation ablation by +0.2–0.4 points
  at every drop count ≥ 2. Reproducible via the training script's
  new `--no-aug` / `--out` flags.
- **TinyML boundary doc (lane 6).** `docs/tinyml_boundary.md`
  records the measured numbers behind the standing split: ESP32-S3
  CSI-HAR typing at 232 ms / 127 kB / PSRAM-required vs the <50 ms
  on-node budget, CSI ceiling >200 pps (watchdog) / ≤5 ms per
  sample — typing (`disturbance_clf`, track stitcher) stays
  on-phone, nodes do detection/tripwire only. The proposed 5th
  model-card item is referenced there as proposed, NOT adopted.
- **Tests.** New Dart golden test (`test/ai_golden_test.dart`)
  loads the shipped weights into the real TinyMlp kernel and
  asserts the golden probabilities — closing the gap where new
  weights shipped with manual-only Dart-side verification.
  Flutter: analyze clean, 438/438 tests. Python bridge suite:
  63/63. Two independent reviews: SHIP-AFTER-FIXES, all fixes
  applied and re-verified.

## v0.23.1 — 2026-10-21 — New app icon

Icon-only release: no code or behavior changes.

- **New launcher icon.** A photorealistic black tricolor
  Australian shepherd wearing an olive Comtac headset with
  boom mic on a dark background — chosen by the operator from
  his own photo. Regenerated across the full set from that
  photo: `assets/icon/shepherd_icon_1024.png` master, all five
  Android mipmap densities (`ic_launcher.png`), and the
  Windows `app_icon.ico`.
- Replaces the v0.22.0 icon, which is backed up at
  `docs/shepherd_icon_v0220_backup.png`.

## v0.23.0 — 2026-10-21 — PRC-163 friendly ground tracks (published)

Friendly GROUND tracks per `docs/prc163_ground_tracks_spec.md`:
the dismounts join the aircraft on the map — as positions, with
honest labels, and with no change to what the 163 is (and is not)
to Shepherd.

- **Ground ingest on the existing CoT path.** Friendly-ground
  events (`a-f-G*` — a PRC-163 carrier's PLI out of an ATAK EUD)
  now enter the CoT listener's platform path by type, exactly as
  `a-f-A*` does; the observation carries its domain off the type
  string, so a ground event can never be routed as an airframe.
  Position, `<track>` course/speed, and `<status>` battery parse
  with the same rules as the air path. The Predator emitter path
  is untouched.
- **Ground records, not airframes.** New `GroundTrackRecord` in
  `airframe_identity.dart`: callsign/uid, position, course/speed,
  battery, last-seen — sharing the friendly registry and the
  classifier's bookkeeping, in a separate collection. Ground
  records get NO capability class (A–D is air evidence) and are
  structurally absent from the Drone tab's airframe selector.
  Labels: `FRIENDLY (FEED)` for CoT-sourced tracks, `FRIENDLY`
  when the callsign/uid also matches the registry. Pruning
  mirrors the air path: feed-only records prune on the Class C
  stale window (they are positions, not assets); registry-matched
  records are retained like air friendlies — silence never
  demotes a friendly classification.
- **Rendering.** Ground friendlies draw as person-glyph dismount
  markers (never the air diamond) with callsign labels and a
  course tick, in friendly green, plus a GROUND TRACKS section in
  the contacts readout with battery/speed/age. The map layer
  toggle is renamed AIR → CONTACTS: it gates the whole
  cooperative-contacts layer (air + ground + RID), which is what
  it always actually did minus the ground half.
- **Sim.** Simulated mode walks two dismounts carrying "163s"
  (SIM-163-A/B) at dismount pace; their ATAK-shaped CoT datagrams
  run through a real CotListener, so the demo path is the
  production path with a fake radio. Sim ground tracks anchor to
  the GPS origin when one is set, else a documented arbitrary
  demo anchor (sim only — live mode never invents an origin).
- **Not a sensing node — stated again because it matters.** The
  163 contributes PLI presence via TAK/CoT only. No link metrics
  exist for it, its USB port is the programming interface, and
  the no-LAN constraint stands; nothing here senses with the
  radio. The no-suppression invariant is unchanged and
  re-verified: ground records are classifier/display output only
  and never feed the merger or the tracker.

## v0.22.0 — 2026-10-21 — Skydio integration P1–P3 (published)

Friendly-airframe support per `docs/skydio_integration_spec.md`:
Shepherd now knows his own drones, classifies every airframe by the
evidence that actually arrives, and can watch their video — while
staying ingest-only (no new transmit/control surface of any kind).

- **P1 — Friendly identity via CoT.** The existing CoT listener
  gains a separate platform path: friendly-air events (`a-f-A*`) and
  registry-matched callsigns land as platform observations (point
  hae, `<track>` course/speed, `<status>` battery) in their own
  collection — the Predator emitter path is byte-for-byte unchanged.
  New `airframe_identity.dart`: the friendly registry (battery-tray
  serials typed in Settings → Drones, `SERIAL[, CALLSIGN[, A|B]]`)
  and the capability classifier — Class A sensing node / Class B
  position node / Class C broadcast contact; Class D (RF cue) never
  enters the registry. Promotion is evidence-only and monotonic:
  never demote on silence. A whitelist match changes rendering and
  correlation priority ONLY — it cannot suppress a track or alert.
- **P2 — Remote ID decoder.** Pure-Dart ASTM F3411 decoder
  (`remote_id.dart`): Basic ID, Location/Vector, System, Operator
  ID, Self-ID, Authentication (structural only, never verified),
  message packs, and the counter-prefixed BLE/Wi-Fi transport
  framing; unknown sentinels decode to null, never zero. Receive
  paths: BLE advertisements ride the existing BLE scan via a new
  passive hook on the FFFA service; Android Wi-Fi beacons are
  extracted from the existing survey (Kotlin IE-221 scan in
  MainActivity — native side uncompiled in the build sandbox, as
  with all prior Kotlin work). Class C contacts render on the
  Tracking map (diamond = drone, square = operator/takeoff point)
  with an AIR CONTACTS readout. A registry serial match renders
  FRIENDLY (claimed) — broadcast identity is unauthenticated and
  spoofable — until a Class A/B feed corroborates the same airframe.
  In-app copy states the limits: broadcast-only coverage, and
  D-model airframes (X10D) may transmit no Remote ID at all.
- **P3 — Drone tab.** New tab (six destinations now): dual-stream
  RTSP viewer on media_kit — EO / THERMAL segmented switch is
  viewer-side stream selection between the aircraft's simultaneous
  streams; EO is labeled PILOT'S FOCAL VIEW (wide/tele is the
  pilot's in-stream choice, not viewer-switchable). Per-airframe
  selector over Class A/B records; telemetry strip comes from the
  CoT feed, NOT the video stream — MISB 0601 KLV extraction through
  media_kit is not practical (no demuxed-metadata surface), so no
  KLV parse is claimed. Stream health is honest (NO SIGNAL /
  CONNECTING / LIVE / FROZEN from playhead behavior); no latency
  figure is shown (none is published or measurable). Endpoints are
  configurable in Settings (local-link defaults per the documented
  RAS-A fit; cloud URL fields for the webhook variant). No flight,
  gimbal, or focal controls exist anywhere in the tab.
- Settings: the whole Skydio block persists (registry text, RID
  toggle, stream URLs, stream source) with boot-time application.
- **Post-review fixes** (two independent review passes before
  publish): the Remote ID decoder's wire layout was corrected
  against the opendroneid-core-c struct definitions — the Location
  flag byte's bit allocation (SpeedMult/EW/HeightType were read
  from mirrored positions, which would have decoded a real
  broadcast's heading and speed wrong), the System message field
  offsets, and the Authentication page-0 data offset; the affected
  test vectors were rebuilt under the corrected layout. The Drone
  tab's stream health no longer reports LIVE before the first
  frame actually arrives (a session that connects but never sends
  frames now reads CONNECTING, then FROZEN at a 10 s deadline
  instead of LIVE forever), and a latched stream error now
  auto-retries on a bounded 10 s cadence (plus tap-to-retry)
  instead of sitting at NO SIGNAL until the operator poked the tab.
- **New app icon**: the cartoon mark is replaced by a photoreal
  portrait — the same black tricolor Australian shepherd wearing
  Comtacs, serious expression, dark background — as the icon
  master and across the Android launcher set.
- New tests: Remote ID vectors (hand-built from the F3411 encoding,
  arithmetic verified — no authoritative public capture exists;
  the ASTM annex is paywalled), classifier promotion rules,
  registry parsing, CoT platform ingest incl. emitter-path
  invariance, stream-health state machine, Drone tab widget
  (fake player), RID service paths, settings round-trip.

Not in this build (spec P4): Skydio Cloud roster sync, AirMesh
Class A promotion beyond the registry/motion rule, ISR Command
detection markers.

## v0.21.3 — 2026-10-21 — Review-fixes merge (Hermes pass, reviewed + applied)

An externally-authored hardening/correctness pass over the
unauthenticated inputs and stuck-state bugs, reviewed on the merits,
independently re-reviewed, and applied with the reviewer's four
should-fixes addressed. 356/356 tests (32 new). Highlights:

- **Node UDP hub**: 16 KB datagram cap, 2000/s flood guard, optional
  source allowlist, UTF-8 decode (was garbling non-ASCII names),
  socket-death recovery, and truthful `lastError`/`isBound` — both
  passive drivers' `probe()` now reports a failed bind as unhealthy.
- **Wi-Fi sensing**: surveys no longer feed the connected AP's
  baseline; connection state judged only from fast polls (empty
  surveys fabricated disconnect flaps → false deauth alerts);
  auto-trust requires a 3-survey dwell on one BSSID, with an
  auth-match gate for extra BSSIDs of a trusted SSID.
- **Pairing**: WireGuard conf builder rejects newline injection in
  hub-supplied keys/endpoints; AllowedIPs follows the assigned
  tunnel /24 (was hard-coded 10.99.0.0/24); public-CA mode keeps
  the ingest bearer token on the invite hub's domain family;
  redeem body size-bounded; copied conf auto-clears from the
  clipboard after 60 s (it carries a private key); token persisted
  only after all join validations pass.
- **Tripwire**: closed episodes report true duration/peak and events
  are reclassified on the full episode; stale links swept after
  10 min; `confirmPolls: 0` can no longer disable all events.
- **CoT listener**: single-quoted attributes parse; far-future
  events rejected (30 s skew); observations capped at 256;
  optional source allowlist.
- **ESP32 driver**: datagram hardening (object-only JSON, ID
  charset/length caps, node/sensor/active caps, coordinate
  validation — lat 0 alone is now kept, only the (0,0) no-fix pair
  is rejected).
- **Trusted sender IPs** setting gates both UDP inputs (node 49160
  + CoT), applied at boot as well as on save (reviewer fix).
- **Android**: FINE+COARSE requested together (Android 12+ ignores
  FINE alone); permission latch re-arms after an answer; redacted
  connected-BSSID placeholder never marks scan entries connected;
  backups disabled; optional release signing via key.properties.
- **Reviewer fixes on top**: calib flag accepts the firmware's
  integer 0/1 (was never readable as a JSON bool); ingest token
  cache also invalidates on 403 and on settings save; the stale-link
  sweep closes open episodes instead of discarding them.
- CI workflow (analyze + test) added for the repo.
- **Wi-Fi RTT ranging fixed** (field report, same day): every RANGE
  tap failed with `NO_MATCHING_AP` — the wifi_ftm plugin matches
  targets against a scan cache only its own scan call populates,
  and the app never scanned. The service now scans first and ranges
  only APs present in that scan (the scan's verbatim BSSID strings;
  stale registry entries dropped), and failures surface as plain
  operator copy — "not in the latest scan" is now distinguishable
  from "AP doesn't answer FTM", and no raw exception reaches the UI.
  Regression-locked with a mock-channel test that emulates the
  plugin's native cache.

## v0.21.2 — 2026-10-21 — Wi-Fi DETECTED headline size fix

- **Wi-Fi status headline no longer wraps mid-word** (field report:
  the WI-FI FIELD STATUS banner rendered "DETECTE / D" on a phone).
  The headline was 40 pt with 5 px letter-spacing beside a 52 px
  icon — too wide for the card. Now 28 pt, single-line, inside a
  scale-down FittedBox, so any status word shrinks to fit instead of
  wrapping, at any screen width.
- **FIELD ACTIVITY header overflow fixed** (found by the new
  regression test): the title + level-chip Row overflowed by 12 px
  at 360 px when the chip read ACTIVE. Title now flexible with
  ellipsis, same pattern as the other headers on this screen.
- Regression test forces the DETECTED state at phone width and
  asserts the headline stays on one line
  (`test/wifi_vision_header_test.dart`). 324/324 tests. Independent
  review: SHIP, no blocking or should-fix findings.

## v0.21.1 — 2026-10-20 — BLE header overflow fix + tunnel QR script

- **BLE Monitor/Scan misalignment fixed** (field report, same evening
  as v0.21.0). Measured at 360 px wide: the NEARBY WIRELESS (BLE)
  header row pushed MONITOR to x=433 and SCAN to x=521 — entirely
  off-screen. Header restructured to a title row + Wrap of actions,
  same pattern as the v0.21.0 tracking fix. The same check found the
  WI-FI FIELD STATUS header overflowing by 14 px next to its LIVE/SIM
  chip; title is now flexible with ellipsis. New regression test
  renders the whole WiFi Vision tab at phone width
  (`test/wifi_vision_header_test.dart`). 323/323 tests.
- **Hub: MAKE_TUNNEL_QR.bat** (field ask) — renders a filled
  `shepherd-mesh.conf` as a QR the EUD scans in the WireGuard app
  (+ → Scan from QR code) to import the tunnel. Comment-stripped
  payload (1,153 → 242 bytes) so the QR stays scannable; refuses
  unfilled templates; prints the tunnel Address for confirmation
  (a second mesh keeping the template's 10.99.0.11 would import
  fine and silently never connect); BOM-safe read (Notepad/
  PowerShell BOMs would otherwise corrupt the payload's first
  line). The QR carries the private key — labeled as such, with a
  delete-the-PNG reminder. Independent review: app fix SHIP,
  script SHIP-AFTER-FIXES with both fixes applied.

## v0.21.0 — 2026-10-20 — Field fixes: tracking header, QR join, Doppler AUTO

Three operator asks from the first full EUD day, in one build:

- **Tracking header overflow fixed** (field report: "the buttons at the
  top aren't aligned properly"). The FIELD MAP header put the title,
  fullscreen button, four layer toggles and the mode label in one row —
  on phone widths HEALTH clipped mid-word and SENSORS fell off-screen.
  Now: title row + a wrapping toggle row. The same bug class was hiding
  in the GPS card (SET ORIGIN / SET DEFENDED shared rows with long
  labels) — restructured the same way. New widget regression tests
  render the Tracking tab at 360 px in simulated and live modes and
  fail on any overflow.
- **QR scan for ZMeta invite codes** (field ask). The join dialog gains
  a SCAN QR CODE button (Android/iOS): camera → the field is filled
  only with a code that passes the full strict invite parse; any other
  QR is rejected with a plain message. Hub side: `zmeta_invite.py` now
  also prints the invite as an ASCII QR (optional `qrcode` pip package;
  degrades to a hint, never an error). CAMERA permission added
  (camera feature not required, so camera-less devices still install).
- **Doppler AUTO station** (field ask). Settings → SDR station gains
  AUTO STATION (GPS): the station position comes from the device's own
  GPS fix instead of hand-typed coordinates, re-arms on a >25 m move,
  and a fix older than 30 min never arms — the status line reports
  armed / waiting / stale / coarse honestly. The eNB position stays
  manual (no tower database on-device; the UI says so). Manual station
  values are preserved under AUTO, including across saves with the
  fields left blank. Saved geometry now loads per-pair (station pair,
  eNB pair) so an AUTO config with no manual station still loads its
  eNB.
- Independent review: 0 blocking, 4 should-fix — all fixed (staleness
  disclosure + re-arm on fresh fixes, AUTO save preserving the manual
  fallback, hub QR crash-proofing on legacy consoles, true-distance
  25 m gate). 322/322 Dart tests, hub pairing tests 60/60, analyze
  clean. The QR scanner's native camera path is Kotlin/SDK-side and
  compiles on the operator's PC build, same caveat as the v0.20.0
  Android WiFi channel.

## v0.20.0 — 2026-10-20 — WiFi Vision goes real on Android

The phone in your pocket is now an actual WiFi sensor, not a demo:

- **Android WiFi source** (`AndroidWifiSource` in `lib/services/wifi_sense.dart`
  + the `shepherd/wifi_sense` channel in `MainActivity.kt`): WiFi Vision
  previously fell back to simulated data on Android. It now reads the real
  adapter — the connected AP's RSSI polled every second (the live tripwire)
  plus the system scan-results cache for the neighbor survey, with per-AP
  security labels parsed from scan capabilities feeding rogue-AP detection.
- **Honest platform limits, handled in code**: Android throttles scans, so a
  survey whose cache timestamp hasn't advanced is dropped instead of being
  re-ingested as fresh samples; scan results need the Location permission
  (one prompt, then a plain-language error, never silent nothing); the
  connected-AP poll needs *full* Location — Nearby Wi-Fi alone leaves the
  connection info redacted, and the app now says exactly that; transition
  RSSI garbage (-127) is rejected before it can fake a disturbance.
- Manifest gains `ACCESS_WIFI_STATE` / `CHANGE_WIFI_STATE` (install-time).
- Independent review: 0 blocking, 5 should-fix — all fixed (stale-cache
  guard, NEARBY-only redaction error, unknown-vs-Open security label,
  RSSI_INVALID rejection, service-level regression test). 308/308 Dart
  tests, analyze clean. Kotlin reviewed by inspection; the on-device
  build + a handset check of the fast poll remain the field test, same
  as every Android-side change.

## v0.19.0 — 2026-10-19 — Device auto-connect

Plug-and-play radios, and an eagerly-connected TAK link:

- **Device auto-connect framework** (`lib/services/device_autoconnect.dart`,
  spec `docs/device_autoconnect_spec.md`): one watcher per device family,
  one 5 s coordinator. A Silvus plugged in over USB-C (172.17.97.x
  interface) gets a real `streamscape_data` handshake and is added as a
  radio config automatically — no SCAN button, no IP entry. Rules:
  validate-before-add (no ghosts), dedupe by driverId+address (interface
  flaps can't clone configs), never auto-delete (unplug marks the driver
  offline; replug resumes). No subnet is ever scanned automatically.
  Per-family toggle in Settings → Radios → Auto-connect (default ON).
  MPU5 has no watcher yet — its driver is still a stub awaiting the SNMP
  walk data, and nothing claims otherwise.
- **TAK/CoT eager connect**: `CotPublisher.connectNow()` runs at
  configure time (cold start, toggle-on) so the link state is known
  before the first track publish; the existing backoff still paces
  retries against a dead server. Dashboard radios card gains a TAK LINK
  row: LINKED / RETRYING / MULTICAST / OFF.
- Independent review: 0 blocking, 3 should-fix (auto-connect timer now
  stopped in dispose(); handshake skipped for already-known radios;
  positive-path connectNow tests with a loopback server). 268/268 Dart
  tests, analyze clean.

## v0.18.0 — 2026-10-18 — Predator-RF CoT integration

Bilateral integration with Predator RF (see `docs/predator_integration_spec.md`):
Shepherd publishes its tracks as CoT (`SHEPHERD-` callsigns) and ingests
Predator's emitter tracks (`PREDATOR-`) as upgrade-only corroboration via the
gated confidence merger. Wire-protocol-only across the GPL-3.0/MIT boundary —
no shared code.

- CoT emit: `lib/services/cot_publisher.dart` — 1 Hz/track throttle, UDP
  multicast 239.2.3.1:6969 default + TAK Server TCP, publish floor 0.3,
  affiliation always unknown.
- CoT ingest: `lib/services/cot_listener.dart` — 60 s emitter window, 50 m
  coincidence radius, 0.10 boost, never originates or subtracts tracks.
- **Android multicast ingest**: `CHANGE_WIFI_MULTICAST_STATE` permission and
  a `MulticastLock` (`MainActivity.kt`, `lib/services/multicast_lock.dart`)
  held while the listener runs. Without it most Android Wi-Fi stacks drop
  inbound multicast and the listener hears nothing.
- **Listener socket loss**: stream `onError`/`onDone` clear `isListening`
  and set `lastError`; a 15 s watchdog retries via the generation-guarded
  reconfigure path (never resurrects a discarded listener).
- **Reconfigure race**: `CotListener.start()/stop()` serialized; a
  superseded `_configureCot` never stops a listener the newer generation
  reuses; the publisher rebuilds only when its own config changed (keeps
  the 1 Hz throttle and the TAK connection).
- **TAK TCP**: default port 8087 (plaintext; 8089 is TLS, which the
  publisher does not speak). Existing saved settings keep their port.

## Unreleased — CoT adapter bug-review fixes (folded into v0.18.0 above)

Author's note (2026-10-18): written without a Dart/Flutter toolchain on hand;
verified before publish — `flutter analyze` clean, 251/251 tests pass. The
Kotlin `MainActivity.kt` changes are standard `WifiManager` MulticastLock API
usage, reviewed by inspection; not yet compiled into an APK.

- **Android multicast ingest**: added `CHANGE_WIFI_MULTICAST_STATE` and a
  `MulticastLock` (`MainActivity.kt`, `lib/services/multicast_lock.dart`)
  held while the listener runs. Without it most Android Wi-Fi stacks drop
  inbound multicast and the listener heard nothing.
- **Listener socket loss**: stream `onError`/`onDone` now clear
  `isListening` and set `lastError`; the watchdog retries every 15 s. The
  receive callback drains all queued datagrams from the socket it was
  bound to.
- **Reconfigure race**: `CotListener.start()/stop()` are serialized; a
  superseded `_configureCot` no longer stops a listener the newer
  generation reuses; the publisher is rebuilt only when its own config
  changed (keeps the 1 Hz throttle and the TAK connection).
- **TAK TCP**: default port 8087 (plaintext; 8089 is TLS, which the
  publisher does not speak). Existing saved settings keep their port.
  Inbound bytes are drained, server-side close is detected, concurrent
  first sends share one connect, and a 0-byte multicast send is an error.

## v0.17.0 — 2026-10-18

### ARTI adaptive baseline + dial-it-in calibration

- **Adaptive baseline** (`lib/services/adaptive_baseline.dart`):
  per-link reference levels that follow slow environmental drift
  (diurnal/temperature creep) instead of re-tripping the tripwire
  on it. Calibration sets the *reference* the detector compares
  against — it never claims a target is present, never claims
  identity, never improves sensing range.
- **Dial-it-in calibration routine**: the operator walks the field
  and captures the per-link baseline profile before an event — a
  known-clean reference so deployment-day conditions, not
  guesswork, define "quiet".

### Direction-split, area-normalized RTI imaging weights

- The shadow heatmap now weights link disturbances with
  fade-signed, direction-split, area-normalized weights instead of
  raw dip depth — blobs land where the link geometry says they
  should, and each link's contribution scales with the ellipse area
  it actually covers (spec: `docs/rti_imaging_weights_spec.md`).
- Output is still a disturbance heatmap — blobs and trails, never
  imagery, never identity, never fire-control-quality tracks.

### ESP32 CSI motion pipeline

- The field-kit node gains an outdoor-usable CSI motion channel:
  Suzuki phase-cancellation averaging (commodity CSI phase usable
  outdoors without regression sanitization), a wind gate
  (`wind_gated` — no wind source, no CSI claim), and link-budget
  gates that zero-weight the channel on weak links (the AV-FDTI
  zero-weight case).
- **Protocol**: two new additive `obs` verbs on the UDP JSON path
  (port 49160) — `CSI` (`dev_hz`, `pairs_active`,
  `path_loss_db`, `wind_gated`) and `WIND` (`wind_ms`,
  `gust_ms`) — parsed by `sensor_protocol.dart`, feeding `e_csi`
  into the §5a gated merger as existence evidence only (spec:
  `docs/esp32_csi_pipeline_spec.md`; §5a addendum in
  `docs/sensor_protocol_spec.md`).

### Doppler-only track refinement

- **Bridge** (`field_kit/sdr_bridge/doppler_detect.py`): RX-only —
  listens to ambient LTE downlink (a signal the carrier transmits
  anyway) and measures what moving objects do to it. A 0.5 s CPI
  buys ~2 Hz Doppler resolution (~0.16 m/s radial velocity at
  1.86 GHz) on ordinary SDR hardware.
- **App** (`DopplerRef`/`DopplerCorrelator` in
  `lib/services/radio_driver.dart`): a second opinion on a tripwire
  track's motion — radial velocity, never a position. Upgrade-only
  corroboration in the gated merger: Doppler agreement can raise
  confidence; Doppler disagreement never deletes or downgrades a
  track.

### WPP-IDP passive radar (no-clean-reference)

- **Bridge** (`field_kit/sdr_bridge/wpp_idp_detect.py`) +
  reference implementation (`field_kit/passive_radar/wpp_idp.py`):
  passive radar on signals of opportunity using the WPP-IDP
  architecture — no clean reference signal required (per-packet
  energy → DC removal → STFT chain, plus the waveform rule that
  scores candidate illuminators before trusting a detection).
- **App** (`WppIdpDoppler` in
  `lib/services/radio_driver.dart`): wires detections into the
  correlator pipeline.
- **Constraint, test-enforced**: micro-Doppler is never used for
  identity — it corroborates *motion*, never says *what*.
  Meters-to-tens-of-meters, never fire-control quality (spec:
  `docs/passive_radar_wpp_idp_spec.md`).

### Validation benches

- **AERPAW replay harness**
  (`tools/stone_soup_bench/replay_aerpaw.py`): replays public
  AERPAW flight-test data through the fusion machinery (gated
  merger, innovation monitor, track stitcher). It validates the
  *fusion machinery*, not Shepherd's sensing — AERPAW has no
  RF-shadowing ground truth.
- **ESP32 500 fps bench mode**: a one-measurement go/no-go test for
  CSI frame-rate feasibility on the node firmware, run before the
  CSI pipeline is trusted.
- Spec: `docs/validation_benches_spec.md`.

### Honesty contract (whole release)

- RX-only, defensive-only: every feature in this release listens,
  measures, and scores. Nothing transmits, jams, deauths, spoofs,
  or probes.
- Paper accuracy numbers are NOT transferred to Shepherd's regime
  (6 nodes, dismounted, on the move, Group 2–3 UAS targets) — the
  specs cite them with their original regimes attached. Features
  are implemented per spec and bench-tested; **field validation is
  pending**.
- Wording stays "consistent with, never confirmed" wherever a
  signature or micro-Doppler claim appears.

## v0.16.0 — 2026-10-17

### ELRS Gemini signature detection (protocol-pattern corroboration)

RX-only DSP that detects LoRa chirp trains (ELRS's LoRa modes) and
scores the Gemini dual-emission signature — the first public
ELRS-specific detector of any kind (see
`docs/elrs_detection_spec.md`; research brief
`~/workspace/your_files/elrs_gemini_detection_brief.md`).

- **Bridge** (`field_kit/sdr_bridge/elrs_detect.py`): dechirp chirp
  detector over an (SF, BW) candidate grid (concentration gate keeps
  tones/FSK/noise out — 13/13 DSP tests), FHSS hop tracker,
  bridge-local Gemini coincidence scorer, throttled `elrs_chirp` /
  `elrs_signature` UDP events (`--no-elrs` disables). SimBackend gains
  a wall-clock-deterministic chirp emitter so two `--simulate`
  instances demo app-level GemX correlation.
- **App**: `ElrsChirp`/`ElrsSignature` parsing + `GeminiCorrelator`
  cross-radio coincidence (GemX: 2.4 GHz + 900 MHz; dual-radio 2.4 GHz
  ~40 MHz pair) in `lib/services/radio_driver.dart`; evidence-view
  "RF SIGNATURES" section; gated merger input (boost 0.15,
  score-weighted, 60 s horizon — existence evidence, no geometry
  claimed, never subtractive).
- **Honesty contract, test-enforced**: "Possible ELRS Gemini
  signature", never "confirmed ELRS". Documented gaps: FLRC modes,
  no identity vs other LoRa FHSS emitters, DF unbuilt, bridge-local
  dual-frequency needs ≥ ~50 MHz instantaneous BW, GemX needs two
  radios.

### Gated confidence merger + consistency monitor (research finding #2)

The upgrade-only rule is now confidence math, shaped by the
literature (AV-FDTI entropy-gated asymmetric fusion, lane3 P5; NEES
consistency, lane3 P8):

- **Gated merger** (`lib/services/confidence_merger.dart`):
  `C_display = clamp(C_RF + Σ w_s·e_s, C_RF, C_max)` — the
  reliability gate `w_s` (freshness × source health × alignment
  quality) collapses to 0 for stale/dead/misaligned sensors, so a
  degraded modality can never drag the picture below the RF-only
  baseline. Saturating (+0.35 cap, exponential approach — ten weak
  PIR triggers asymptote, never manufacture certainty). Never
  subtractive by construction; displayed confidence caps at 0.95
  (confidence, never identity). `Corroboration` gains a 0..1
  `quality` alignment channel feeding the gate.
- **Consistency monitor** (`lib/services/track_consistency.dart`):
  the honest NEES analogue for the covariance-free grid-search
  tracker — fix-to-fix innovation normalized by the tracker's
  expected fix-error scale (1.0 m), flags sustained 3σ jumps
  (3 consecutive to flag, 5 clean to clear, gaps reset instead of
  flagging). Surfaces as a `TRACK STATE: INCONSISTENT` flag on the
  tracking screen and **suspends all corroboration upgrades** while
  inconsistent — a misassociated track is never upgraded.
- **Tracking screen** shows the merged `CONFIDENCE` row (RF base +
  applied sensor upgrades) and the inconsistency flag.
- **Stone Soup bench** gains a true NEES evaluation
  (`tools/stone_soup_bench/bench_jpda.py`): mean NEES over the 4-D
  state should sit near d=4; the current config scores ≈66 —
  flagged OVERCONFIDENT, correctly: the link-midpoint detection
  stand-in carries unmodeled bias the 3 m covariance doesn't cover
  (RMSE alone never said so). `--shrink-covar 0.01` demo scores
  2865. Covariances must be re-honest (inflate or swap the
  detector) before porting to the app.
- Docs: `docs/confidence_math.md` (formula, literature basis,
  honesty boundaries); `docs/sensor_protocol_spec.md` §5a/§5b
  (merger math + reliability-gate table).
- Detection authority unchanged: the tripwire still originates
  every detection; the merger only computes a display number.

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
