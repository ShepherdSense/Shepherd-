# PRC-163 Friendly Ground Tracks — Shepherd

Status: BUILT as v0.23.0 (2026-10-21, pending publish). Companion
to `docs/skydio_integration_spec.md` (the air side). Operator
decision: wire the AN/PRC-163 into Shepherd as friendly ground
tracks — the path the radio can actually support.

## What the 163 contributes — and what it does not

The PRC-163 contributes **PLI presence via TAK/CoT, and nothing
else**:

CONFIRMED (L3Harris Radio Application Handbook Rev G, research
2026-10-07/14):

- The plain USB cable is the CPA **programming interface**
  (12193-0460-A006, serial) — no IP, no SNMP, no CoT by design.
  SNMP is not documented on the 163 at all; the SNMP-probe
  approach is retired.
- The radio lives under a **no-LAN constraint** (operator's,
  standing): it does not go back on a network for Shepherd.
- Real Ethernet would need the USB-to-Ethernet converter
  (12193-0395-A003/0396-A003 or 12246-2000-01) plus the
  12241-1000-01 side adapter — and would still be a management
  path, not a sensing feed.
- The live position path is the waveform: PLI rides the radio's
  waveform to ATAK/WinTAK EUDs; an EUD (or taky on the PC, TCP
  8087) emits it as CoT. One CoT receiver covers the 163 and the
  BEAST+.

So, in the sentence that must never get blurred:

**The 163 is NOT a sensing node.** No link metrics exist for it —
nothing like StreamScape's per-link SNR/MCS is exposed anywhere.
Shepherd cannot sense *with* a 163; it can only show where the
163's carrier is, as reported by the TAK feed. Its presence adds
zero detection capability and its silence removes none.

## The build (v0.23.0)

### Ingest

The v0.22.0 CoT listener already had the platform path (friendly
air, separate from the Predator emitter path). Ground joins it:

- Events typed `a-f-G*` (e.g. `a-f-G-U-C`, friendly ground unit)
  enter the platform path **by type**, exactly as `a-f-A*` does —
  no registry entry is required for the feed to render.
- `PlatformObservation.domain` derives from the type string
  (`a-f-G*` → ground, else air). The type is the source of truth,
  so domain and type can never disagree, and the app-level fold
  routes by domain: ground observations can never become
  airframe records.
- Position, `<track>` course/speed, and `<status>` battery parse
  with the air path's rules, including its documented defaults
  and ambiguity handling.
- The emitter path is semantically untouched (test-pinned both
  ways, as before).

### Records

`GroundTrackRecord` in `lib/services/airframe_identity.dart` —
a sibling of `AirframeRecord` in the same module, because "who
is friendly" is one question with one registry:

- Fields: callsign/uid, CoT type, position, course/speed,
  battery, last-seen, registry entry, friendly basis.
- **No capability class.** Classes A–D classify air evidence;
  a ground track has none to earn. Ground records live in their
  own collection (`AirframeClassifier.groundRecords`), so the
  Drone tab's selector — which reads air records — structurally
  cannot offer a dismount as a streamable airframe.
- Labels: `FRIENDLY (FEED)` for a CoT-sourced track (the feed
  asserts the affiliation; Shepherd did not verify it);
  `FRIENDLY` when the callsign/uid also matches the friendly
  registry — the same registry the air path uses, so a unit the
  operator has named renders named in both domains.
- There is no (claimed) tier on the ground: no unauthenticated
  broadcast path feeds this collection.

### Pruning

Feed-only ground records prune on the Class C window discipline
(the classifier's 10-minute stale window): they are reported
positions, not corroborated assets. Registry-matched ground
records are retained like air friendlies — the registry is the
operator's declared roster, and silence never demotes a friendly
classification. A retained record shows its last reported
position with its age; it does not pretend to be current.

### Rendering

- Tracking map: **person-glyph** dismount markers — never the
  air diamond — in friendly green, callsign label (`NAME · GND`),
  and a course tick when the feed reports a course.
- One toggle: the map layer toggle is renamed AIR → **CONTACTS**.
  It always gated the cooperative-contacts layer (CoT platforms
  + Remote ID); it now says so, and gates the ground markers too.
  One toggle for one layer — no new switch to learn in the field.
- The contacts readout gains a GROUND TRACKS section (label,
  battery, speed, age) with the not-a-sensing-node statement in
  the copy, next to the rows it describes.

### No-suppression invariant (unchanged, re-verified)

Ground records are classifier/display output only. Platform
observations — air or ground — never feed the confidence merger,
never corroborate a track, and never suppress a track or an
alert. There is deliberately no code path from the ground
collection to detection; tests assert both the behavior (ground
evidence creates no airframe record) and the structure (the
merger/tracker sources contain no ground-record references).

### Sim

Simulated mode walks two dismounts carrying "163s"
(SIM-163-A / SIM-163-B) on patrol paths at dismount pace
(~1.4 m/s peak), emitting ATAK-shaped `a-f-G-U-C` datagrams
through a private, real `CotListener` — the demo exercises the
production parse → platform → ground-classifier path end to
end; only the radio is fake. Positions anchor to the GPS origin
when one is set; otherwise a documented arbitrary demo anchor
(Fort Liberty area) is used for projection in sim mode only.
Live mode never invents an origin.

## The Wraith note (air side, future)

Trade-reported 2026-10-21: L3Harris has integrated its Falcon
IV radio + Wraith waveform into the Skydio X10D. IF his X10Ds
carry that fit (a procurement/fit question — his airframes may
predate it), the drone joins the same waveform net as his 163s,
giving the X10D's Class B friendly feed a military-waveform
route to the map that doesn't depend on the controller running
ATAK. That is a tougher pipe for the air side. It changes
nothing about the 163 itself: no metrics surface appears, the
USB/no-LAN facts stand, and the ground path in this spec remains
the whole of the 163 integration.

## Honest limits

- A ground track is only as current as its last PLI event; the
  UI shows age, and a stale marker is a memory, not a fix.
- The feed asserts affiliation. A friendly registry match is the
  operator's own declaration; neither is authentication.
- CoT multicast is unauthenticated on the segment — the existing
  trusted-sources allowlist applies to this path unchanged.
