# Shepherd ↔ Predator RF Integration — Spec

**Status:** spec, unbuilt. **RX-only, defensive-only, emit-and-listen.** Shepherd
publishes its own tracks as CoT and *listens* for Predator RF's emitter tracks on
the same CoT multicast group. Nothing here transmits beyond our own track events,
jams, deauths, or spoofs. This spec is bilateral: the **Contract** section is the
shared interface both developers build to; **Shepherd-side** is our build;
**Predator-side** is notes for their developer (not our code).

## Goal

One ATAK map, two sensors, zero confusion. Predator RF characterizes *emitters*
(SDR-based SIGINT: what frequency, what signal, TDOA-geolocated position).
Shepherd detects *movers* (device-free RF disturbance: something crossed the
mesh). When a Predator emitter position coincides with a Shepherd mover track,
that is a high-confidence track neither system could make alone — an emitting
mover, localized two independent ways. The integration has three parts:

1. **Shepherd CoT emit** — our tracks onto the TAK network (builds the existing
   `docs/shepherd_cot_output_spec.md`).
2. **Shepherd CoT ingest** — Predator's emitter tracks *into* Shepherd as
   corroboration-only evidence (new).
3. **Shared conventions** — callsign prefixes and CoT types so ATAK's native
   filters switch between the two feeds with one tap (no plugin required).

## Background — what each side already does

- **Predator RF** (JakeTheSnake0245, GPL-3.0): Android/C++ SDR++-based SIGINT
  cockpit + Python backend. Continuous FFT peak detection, signal
  classification, decoder modules (P25/DMR/ADS-B/AIS/…), TDOA multilateration
  (≥2 GPS-synced nodes), track lifecycle state machine. **CoT output already
  built**: GeoChat hit alerts + SA beacons, two-key operator gate, UDP
  multicast / unicast / TCP / TLS to TAK endpoints. Kujhad fleet protocol for
  node coordination; RNS/Reticulum transport with ATAK forwarder.
- **Shepherd** (MIT): device-free RF sensing — tracks objects moving through
  the mesh's RF field via link disturbances. Sees RF-silent targets (fiber-optic
  FPV, RF-quiet terminal phase) that Predator's stack cannot see. CoT emit is
  spec'd (`docs/shepherd_cot_output_spec.md`) but unbuilt; CoT ingest is new.

**Why CoT is the integration layer (not APIs):** Predator exposes a
token-protected REST API (`:8000/api/v1/tracks`), but CoT multicast needs no
credentials, no polling, no version coupling, works phone-to-phone on one
device or across a LAN, and is symmetric with the emit path both sides already
speak. The API stays a future option; CoT is the contract.

**License boundary (load-bearing):** Predator is GPL-3.0; Shepherd is MIT. The
two programs communicate over the CoT wire protocol only — separate processes,
no shared code, no linking. The GPL stays on Predator's side of the wire.
Nothing in this spec combines the codebases.

## Contract (bilateral — both sides build to this)

### Transport
- **Default: UDP multicast `239.2.3.1:6969`** (the standard CoT multicast
  group). Zero-config on a shared LAN; on a single Android phone both apps
  publish/listen on loopback-adjacent multicast.
- TAK Server TCP as the enterprise alternative (each side keeps its own
  server config; the contract doesn't change, only the destination).

### Callsign prefixes (the ATAK filter switch)
| Feed | Callsign prefix | Example |
|---|---|---|
| Shepherd tracks | `SHEPHERD-` | `SHEPHERD-T0042` |
| Predator emitter tracks | `PREDATOR-` | `PREDATOR-FHSS2G4` |

- Prefixes are operator-configurable on both sides but default as above.
- ATAK's native map filters (callsign contains `SHEPHERD-` / `PREDATOR-`) are
  the documented "switch between the two" — saved as filter presets by the
  operator. No plugin required.

### CoT type codes
- Shepherd: `a-u-G` (unknown ground) default; `a-u-A` (unknown air) when the
  type guess is drone/fixed-wing/rotary at confidence ≥ 0.5 (per the existing
  CoT output spec). Affiliation always `u` — Shepherd never asserts
  hostile/friendly.
- Predator: its existing types stand; the contract only requires the
  `PREDATOR-` callsign prefix and a `<point>` with lat/lon on emitter-track
  events so Shepherd's ingest can use them.

### Event expectations
- Each side emits one CoT event per track update; track loss is signaled by
  letting the event go stale (no explicit deletes). `stale` = event time +
  30 s default.
- `how="m-g"` (machine-generated) on both sides.
- Position error (`ce`/`le`) populated honestly on every event; fixed defaults
  must be documented, never silent.

## Shepherd-side build

### 1. CoT emit — `lib/services/cot_publisher.dart`
Build `docs/shepherd_cot_output_spec.md` as written (no changes): subscribe to
the fused tracker, throttle 1 Hz/track, XML builder with golden tests, UDP
multicast 239.2.3.1:6969 default + TAK Server TCP option, Settings → Output
toggle (default OFF), dashboard status line, publish floor 0.3. Callsign format
updated to the contract: `SHEPHERD-<trackId>` (no space, per the contract
table — the old spec's `SHEPHERD <trackId>` with a space is superseded).

### 2. CoT ingest — `lib/services/cot_listener.dart` (new)
- Join UDP multicast `239.2.3.1:6969`; parse CoT XML events (position, time,
  callsign, type).
- Keep only events whose callsign starts with the configured emitter prefix
  (default `PREDATOR-`; operator-editable so any CoT emitter can feed it).
- Hold emitter observations in a time window (default 60 s; stale events drop).
- **Emitter–mover coincidence:** when an emitter observation's position is
  within `coincidence_radius_m` (default 50 m, configurable) of an active
  Shepherd track's estimated position, and timestamps overlap within the
  window, emit an `EmitterCoincidence` corroboration into the gated confidence
  merger (`lib/services/confidence_merger.dart`):
  - **Upgrade-only, boost 0.10** (same class as the Doppler refinement layer).
  - **Never originates a track.** An emitter with no Shepherd track produces
    no Shepherd output — it stays visible on the ATAK map via Predator's own
    CoT, not ours.
  - **Never subtractive.** Emitter disappearing changes nothing about the
    Shepherd track.
  - Freshness-weighted like all corroboration (stale emitters → weight 0).
- Evidence-sheet line: "RF emitter reported at this position by PREDATOR-…
  (coincident)" — "consistent with", never identity.

### 3. Settings UI
- Settings → Output gains: CoT toggle (existing), **"Listen for emitter tracks"
  toggle (default OFF)**, emitter callsign prefix field, coincidence radius,
  listen multicast group/port/window fields, plus emit-side track callsign
  prefix (default `SHEPHERD-`, non-empty, no whitespace) and air-type
  confidence threshold fields.
- Dashboard status line extends: "CoT → 239.2.3.1:6969 · 3 publishing ·
  listening (2 emitters tracked)". A failed listen bind shows
  "listening FAILED: <err>" instead of claiming to listen; future-dated
  observations are excluded from the emitter count.

## Predator-side notes (for their developer — not our code)
1. Set the CoT callsign prefix default to `PREDATOR-` on emitter-track events
   (currently GeoChat/SA beacons; the contract needs track events with the
   prefix and a `<point>`).
2. Everything else on their side already exists (CoT output, two-key gate,
   multicast transport). Inbound `SHEPHERD-` tracks arrive as ordinary CoT —
   their RNS ATAK forwarder already handles inbound CoT; no changes needed
   unless they want Shepherd tracks in the Kujhad fleet view.
3. Suggested: their track lifecycle (NEW → TRACKING → STABLE) maps cleanly
   onto stale windows; no contract change needed.

## Honest scope
- Coincidence is spatial proximity of two independent estimates, each with
  stated error — not proof they're the same object. The UI says "coincident",
  never "confirmed".
- Shepherd positions are RF-derived estimates (ce/le on every event); Predator
  positions are TDOA estimates with their own error ellipse. The coincidence
  radius must exceed the sum of both errors or it's numerology — the default
  50 m is a starting point, field-tunable.
- An RF-silent mover will never get emitter corroboration — that's the point
  of Shepherd, not a gap. The merger must not penalize tracks without it.
- Affiliation stays unknown on our side, always. No hostile/friendly
  assertions, no weapon-cueing language, no fire-control-quality claims.
- License boundary: no shared code, no linking, wire protocol only.

## Test plan
1. **XML golden tests** (emit): known track → byte-exact CoT event (modulo
   timestamps); `SHEPHERD-` prefix format; type-code table.
2. **CoT parse tests** (ingest): sample Predator-style events → emitter
   observations extracted; non-matching callsigns ignored; malformed XML
   dropped without crashing the listener.
3. **Coincidence tests**: emitter within radius + fresh → 0.10 boost applied;
   emitter outside radius → 0; stale emitter → 0; emitter with no Shepherd
   track → no output, no track created (regression).
4. **Never-subtractive test**: emitter disappears mid-track → track confidence
   unchanged (not reduced).
5. **Throttle test**: 10 track updates in 200 ms → 1 datagram.
6. **Bench**: two phones (or phone + PC) on one LAN, ATAK-CIV running:
   Shepherd track appears as `SHEPHERD-` marker; simulated Predator CoT
   appears as `PREDATOR-` marker; ATAK callsign filters isolate each feed;
   killing the Shepherd track → marker gone after stale window.
7. **Gate**: no merge until the bench passes with the operator watching
   Shepherd's map and ATAK side by side.

## Out of scope
- Merging the codebases (GPL boundary — never).
- An ATAK plugin for feed switching (native filters cover it; revisit only if
  operators report the filters insufficient).
- Predator REST API ingestion (future option; CoT is the contract).
- TAK Server auth/TLS client certs (deployment config).
- Ingesting any CoT beyond the configured emitter prefix (no BEAST+ ingest
  here — that's the MRSI driver).
