# Shepherd v0.26.0 — Fieldwatch-borrow build spec

## Status note (read first)

Draco greenlit this 2026-10-24 ("Borrow away") under his standing EUD
assumption: most Shepherd users run it on an EUD (ATAK Android device),
so anything that works on a phone gets implemented.

**Correction to the original brief, verified in code 2026-10-24:**
Remote ID decoding is NOT new in v0.26.0. It already exists and is wired:
`lib/services/remote_id.dart` (full ASTM F3411 message decoder: Basic ID,
Location/Vector, System, Operator ID, Self ID, Authentication, message
packs), `lib/services/remote_id_service.dart` (BLE service-data 0xFFFA
hook, assigned in `app_state.dart:950`, plus Android Wi-Fi survey poll),
`_foldAirframeEvidence` folds RID contacts into the airframe classifier
(display-only), and `airframe_overlay.dart` draws RID markers
(`RID · NO ID` for contacts without a serial). Item 1 below is therefore
**harden + label + prove**, not fresh implementation. Do not claim
otherwise in code comments, CHANGELOG, or README.

## What Fieldwatch is (grounding)

OffGridPete/Fieldwatch, MIT license, Android/Kotlin, receive-only Wi-Fi +
Bluetooth LE observer. No dongle, no account, no backend, fully offline.
250+ device signature library in an extensible JSON catalog. Drone
Remote ID decoding. Hunt walk-around heat map with motion-sensor step
tracking between GPS fixes. Live map with path. Offline maps: OSM and
USGS out of the box; Esri/MapTiler/Stadia/Thunderforest only with the
user's own key. Its own honest limits, which Shepherd inherits wherever
they apply: no direction finding, no monitor mode, no cellular,
phone-OS scan quotas hide quiet/randomized radios, matches are
hypotheses, not identity.

## Scope (five items, phone/EUD-first, Dart)

### 1. Remote ID — harden, label, prove (NO re-implementation)
- Audit `remote_id.dart` / `remote_id_service.dart` for malformed and
  short frames; add regression tests (truncated message, bad type
  nibble, oversized pack count, empty service data, stale contact
  expiry). Fix only real bugs found.
- Label RID-derived records in UI-facing strings as cooperative /
  identified (e.g. `COOPERATIVE (RID)`), distinct from mesh tracks.
- Prove the never-override rule with a test: RID evidence must never
  feed detection, the tracker, or the confidence merger, and must
  never suppress or downgrade a mesh track/alert.
- Wi-Fi NAN: NOT implemented. Stock Android does not expose NAN
  Remote ID frames to the app; document this as unavailable, never
  fake it. BLE 5 extended advertising stays platform-dependent and
  must be labeled as such where it surfaces.

### 2. Wi-Fi/BLE signature library — "what's around me"
- New `lib/services/device_signatures.dart`: match phone-visible
  Wi-Fi scan results and BLE advertisements against a catalog and
  return ranked candidate device classes (tracker, camera, body cam,
  drone, router/IoT, unknown) with the matching evidence.
- Built-in catalog as a Dart const (no pubspec change). User-added
  signatures load from a JSON file in the app documents directory
  and merge over the built-in catalog; user entries are labeled
  USER-ADDED wherever they surface.
- Catalog honesty rule: an entry is allowed only if grounded in a
  public assignment (Bluetooth SIG company ID / service UUID, IEEE
  OUI) or explicitly marked UNVERIFIED/COMMUNITY. Never invent an
  OUI-to-product mapping. Every match is labeled a hypothesis, not
  identity, in code and in any UI string the service produces.
- MIT attribution: header comment noting the concept is adapted from
  Fieldwatch (MIT) with no Fieldwatch code or catalog data copied.
- Tests: match on BLE service UUID, match on Wi-Fi OUI/SSID pattern,
  unknown device returns no confident match, user JSON overrides
  built-in, malformed user JSON degrades to built-in only (never
  crashes, never silently drops the whole catalog without a
  surfaced reason).

### 3. Hunt heat-map mode
- New `lib/services/hunt_tracker.dart` (pure Dart core, fully unit
  tested): a selected emitter's RSSI samples accumulate into a
  spatial heat grid (weak-to-strong), with decay/aging so stale
  cells fade; `loudest` cell/point is exposed; proximity is the
  output, never a position fix.
- Step tracking between GPS fixes: a `StepSource` abstraction fed by
  the phone's motion sensors where available. If the `sensors_plus`
  dependency cannot be resolved in the sandbox, the core still
  ships against the abstraction with a documented platform adapter
  stub, and the gap is reported honestly (never faked).
- Feedback: beep/vibrate hooks as pure callbacks the UI can wire
  (no audio plugin added in this build).
- Tests: heat accumulation + decay, loudest-cell selection, step
  integration between fixes, empty/no-sample behavior, out-of-order
  samples.

### 4. Phone-only tier
- New `lib/services/phone_tier.dart`: detects "no mesh/SDR hardware
  attached" and gates a phone-scans-only mode (phone BLE scan +
  phone Wi-Fi survey + Remote ID + signature library + Hunt).
- The mode is honestly labeled PHONE-ONLY / PHONE-RANGE everywhere
  it surfaces: tens of meters, not area coverage; distinct from
  mesh coverage; never presented as mesh-equivalent.
- Tests: tier active with no hardware attached, tier inactive when
  a mesh driver is attached, tier exposes only phone sources (no
  Silvus/SDR/serial drivers), graceful behavior when a scan source
  is unavailable.

### 5. Offline maps pattern
- New `lib/services/offline_map_source.dart`: keyless tile-source
  definitions (OpenStreetMap standard layer, USGS imagery, USGS
  topo — URL templates only, no paid keys, no Esri/MapTiler/Stadia
  built in), a disk cache (http + path_provider, cache-first,
  bounded size, stale-on-error), and a tile-background painter
  usable by Hunt and phone-tier views (CustomPaint-compatible,
  consistent with the app's existing CustomPaint map rendering).
- Offline behavior: cached tiles render without connectivity;
  missing tiles render as an honestly-labeled blank grid, never as
  an invented map. No new paid dependencies.
- Tests: source selection (keyless only by default), cache hit/miss/
  stale behavior, bounded cache eviction, missing-tile fallback.

## Hard rules (all items)

- Defensive-only, RX-only. No transmit, no jamming, no EA, no
  deauth, no spoofing. No new fleet features. No changes to gateway
  UDP JSON, CoT, or ZMeta surfaces.
- Honest limits in code and docs: phone-OS scan quotas, randomized
  MACs, Remote ID only on compliant broadcasting drones, Hunt gives
  proximity not position, phone-tier range is tens of meters.
  No invented performance numbers. Field accuracy is UNVERIFIED
  until hardware runs it.
- Default app behavior unchanged for existing mesh users. All five
  items are additive; anything that changes a screen is opt-in.
- Never-subtractive: corroboration/identification layers must never
  delete or downgrade a detection, track, or alert on their own.
- Fail-safe defaults: missing input degrades to off, never to a
  confident wrong answer. No silently swallowed failures.
- File ownership for this build (avoid merge conflicts):
  Agent A owns item 1 (audit) + item 2 + their tests. Agent B owns
  items 3, 4, 5 + their tests, and pubspec.yaml ONLY if a
  `sensors_plus` (or equivalent) dependency resolves. NEITHER agent
  edits `lib/state/app_state.dart`, CHANGELOG.md, README.md, or
  pubspec.yaml version — the coordinator integrates and bumps.
  Each agent reports exact wiring notes for the coordinator.

## Tests

`flutter analyze` clean. Full `flutter test` passing. New tests for
each item as listed above. Report exact counts from your own runs.
