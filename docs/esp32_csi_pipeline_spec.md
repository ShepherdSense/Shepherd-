# ESP32 CSI Motion Pipeline — Spec

**Status:** implemented in v0.17.0; field validation pending. **RX-only.** The ESP32 sniffs ambient WiFi
CSI and RSSI from packets other radios already transmit; nothing here
adds a transmitter.

## Goal

Port two peer-reviewed, fully-read results into the Shepherd Field Kit
node pipeline so the ESP32 nodes get an *outdoor-usable CSI motion
channel* without the usual CSI pitfalls (CFO/SFO drift, wind clutter,
and unstable weak links):

1. **A phase-cancellation trick** that makes commodity CSI phase
   usable outdoors without regression sanitization (Suzuki et al.).
2. **Cheap link-budget gating** that disables CSI features exactly
   where the physics says they lie — and falls back to the RSSI-only
   tripwire the node already has (commodity-CSI stability study).

The CSI channel stays **corroboration, upgrade-only, never veto** —
the same standing rule as every other sensor in
`docs/sensor_protocol_spec.md` §7.

## Background

### (a) Suzuki et al., arXiv:2606.07347 (2026) — READ IN FULL, CONFIRMED

Model-based outdoor WiFi motion detection using a Raspberry Pi plus a
Buffalo AP at 5.6 GHz, 20 MHz bandwidth. The key results:

- **Symmetric-subcarrier phase averaging.** Phase errors from carrier
  frequency offset (CFO), sampling frequency offset (SFO), and packet
  detection delay manifest as an approximately *linear* phase slope
  across subcarriers: subcarrier `+k` sees `+k·α`, subcarrier `−k`
  sees `−k·α` for the same error slope `α`. Averaging the symmetric
  pair's complex values cancels the slope **without any
  phase-unwrapping regression or sanitization step**. Averaging also
  gives processing gain against noise. This is the paper's central
  trick and it was verified on real outdoor links, not simulated.
- **Hz-deviation metric.** Motion is measured as the *frequency
  deviation* of the averaged phase's time series (not raw phase, not
  amplitude). Reported operating points on an outdoor link:
  - wild crows crossing: **~5 Hz** deviation on the LoS link;
  - an overhead bird at **~4 m altitude, ~5 m off-LoS** — *beyond the
    50th Fresnel zone* — still detectable;
  - SUV intrusion: **> 30 Hz** deviation.
- **Wind gate.** Vegetation flutter was the dominant outdoor false
  positive. A **3.5 m/s wind-speed gate** held false positives to
  **< 0.5%** — when local wind exceeded the gate, motion claims were
  suppressed.

**Honest limit, stated in the paper and load-bearing here:** this is
*meters-class* detection. Bird-sized targets were seen meters from
the link. This reinforces Shepherd's standing honest scope —
**tripwire, not radar**.

### (b) Commodity CSI stability, arXiv:2203.12888 — READ IN FULL, CONFIRMED

Cable-conducted measurements on an Intel 5300 (3×3 MIMO, 20 MHz):

| Condition | Finding |
|---|---|
| Path loss < 60 dB | amplitude STD **< 0.5 dB** |
| Path loss > 60 dB | amplitude STD "increases significantly" |
| Path loss < 50 dB | phase STD **< 2°** |
| Path loss ≈ 60 dB | phase STD **~3°** |
| Path loss > 60 dB | phase STD "increases radically" |
| Inter-chain imbalance > 10 dB | power-ratio deviation "grows dramatically" |
| Inter-chain imbalance > 30 dB | phase **unmeasurable** (zeros reported) |

**Mechanism (CONFIRMED):** one common AGC is set by the *strongest*
chain; weak chains ride a gain they weren't set for. The mitigation is
deliberate: **pad (attenuate) the strongest channel to rebalance**
before CSI use.

**Caveats that limit transfer:**
- Intel 5300, **not** ESP32. The ESP32's CSI path (1T1R, different
  RF front end) was not characterized in this study. **Field knees
  will be WORSE than the cable bench, not better** — the cable run
  had no multipath; the 60 dB knee was reached under *ideal*
  conditions.
- The inter-chain mechanism (common AGC across chains) applies to
  multi-chain hardware. The ESP32 is single-chain, so there is no
  second chain to imbalance *on that node*. The imbalance rule
  transfers to Shepherd only where multiple receive paths meet:
  across the nodes that form one mesh link, or across the SDR
  bridge's multi-channel backends.
- Label this accordingly: the 60 dB rule is a CONFIRMED
  bench knee on *some* commodity WiFi hardware; the ESP32 field
  knee is CLAIMED-until-measured and must be conservatively set
  *below* 60 dB.

## Proposed design

### Signal chain

```
ESP32 promiscuous CSI callback (per-frame, Wi-Fi task)
  → per-pair symmetric-subcarrier averaging  ← firmware-side per-packet
  → per-pair phase time series (1 s rolling window)
  → Hz-deviation metric per AP-link
  → wind gate (local anemometer obs or configured gate)
  → UDP event 127.0.0.1:49160 (type sensor_obs, obs "CSI")
        ↓
node_udp_hub.dart (parse, route)
        ↓
generic_sensor_driver.dart (link health gates: 60 dB / 10 dB)  ← app-side per-link
        ↓
sensor_protocol.dart (typed CSI observation, staleness horizon)
        ↓
confidence_merger.dart §5a/§5b (upgrade-only corroboration of the RF tripwire track)
```

#### Stage 1 — firmware-side per-packet pre-processing

The symmetric-subcarrier averaging lives **in the ESP32 firmware,
per CSI frame, in or right after the CSI callback** (`csi_cb` in
`shepherd_node.ino`). Rationale: it is a per-packet operation on data
that only exists transiently; doing it in firmware halves the bytes
that ever need aggregation and keeps the raw slope-cancellation
exactly where the phase linearity holds (before any averaging across
time or packets could smear it).

Per frame, for each symmetric subcarrier pair `(+k, −k)` in the
20 MHz HT CSI (up to 32 pairs):

1. Take the complex CSI values `c(+k)`, `c(−k)`.
2. Form the averaged value `m(k) = (c(+k) + conj(c(−k))) / 2`. The
   error slope `±k·α` cancels in the sum; the true channel phase
   (even-symmetric under conjugation) adds. No unwrapping, no
   regression fit.
3. Store the phase `arg(m(k))` into a per-pair circular buffer
   (1 s window at the frame arrival rate — timestamps come from
   `nodeNowUs()`, same clock discipline as the existing events).

Once per second (the existing 1 s aggregation cadence in `loop()`):

4. For each pair, compute the **Hz-deviation** of the phase time
   series over the window (zero-crossing rate of the detrended
   phase, or a small FFT — whichever fits the ESP32 budget; the
   metric is what the paper verified, the estimator is free).
5. Take the **max pair deviation** as the link's `dev_hz`, with the
   number of pairs above a noise floor as a secondary field
   (`pairs_active`) — a motion that lights many pairs is harder to
   dismiss than a single-pair flicker.
6. Compare against the wind gate (below). If wind exceeds the gate,
   report `wind_gated: true` and suppress the motion claim for that
   window — fail-silent, never fail-loud.

**Per-channel vs per-AP-link (known implementation deviation):** the
spec above calls for a "Hz-deviation metric per AP-link", but the
shipped firmware (`shepherd_node.ino`) aggregates *all* frames seen on
the channel into one scalar metric labeled `wifi_ch%d`, with no
per-MAC separation. Frames from different APs carry independent
CFO/channel phases, so mixing them muddies the ZCR metric — a known
degradation vs the paper's single-link result. Per-AP (per-source)
rings would multiply RAM unsafely on the ESP32 and are deliberately
NOT implemented; per-AP separation is future work. The Stage 2 wind
gate and the app-side gates apply to this per-channel scalar as-is.

#### Stage 2 — the Hz-deviation metric and the outdoor clutter gate

Operating thresholds, seeded from the paper's outdoor numbers and
labeled as **starting estimates to field-calibrate, not constants**:

| `dev_hz` band | Meaning | Action |
|---|---|---|
| < 3 Hz | below the paper's bird floor | noise; no claim |
| 3–10 Hz | small-mover band (crow-class ~5 Hz) | weak corroboration |
| 10–30 Hz | person/animal class (between paper's bird and SUV) | moderate corroboration |
| > 30 Hz | vehicle-class intrusion (paper's SUV floor) | strong corroboration |

**Wind gate:** the firmware accepts a `WIND` observation (new
protocol verb, see schemas) carrying local `wind_ms`. While
`wind_ms ≥ 3.5` (Suzuki's gate), CSI motion claims are suppressed —
the window is still counted for false-positive statistics but
contributes zero weight to the merger. **Without a wind source the
CSI motion features are disabled by default** (fail-safe): the node
reports `wind_gated: true` permanently rather than guessing. Wire
format (defense-in-depth): while `wind_gated` is true the node emits
`dev_hz: 0.0` and `pairs_active: 0` with `wind_gated: true` kept, so a
consumer that ignores the flag sees no claim rather than a computed
value. Wind sources in order of preference: a cheap anemometer module on the
node's UART (text `SENSOR`/`WIND` protocol), an operator-set static
gate ("always gated in this climate"), or — last resort, documented
as such — a weather-API value pushed to the app and forwarded in
beacons.

#### Stage 3 — app-side link-budget gating (the cheap check)

The 60 dB / 10 dB gates live **app-side, per link, in the generic
sensor driver** — *not* in the firmware — because the decision inputs
(per-link RSSI, per-node beacon signal levels) already exist there
and the computation is trivial.

Per ESP32 link, each second:

1. **Path-loss estimate:** from the link's RSSI and the known/assumed
   TX power of the sniffed AP (beacon-reported or configured).
   - If estimated path loss **> 60 dB**: CSI statistics are
     **disabled for that link** — `dev_hz` observations are logged
     but carry zero merger weight. The RSSI-only tripwire for that
     link continues unchanged (regression-prohibited: gating must
     never take away a capability that worked).
   - **Conservative default 55 dB** until the ESP32 field knee is
     measured: the 60 dB knee was cable-conducted, no multipath, on
     better silicon. Field is worse. A 5 dB safety margin is cheap
     insurance; narrowing it is field-test follow-up work.
2. **Imbalance check (multi-path analogue of the paper's >10 dB
   rule):** compare the link's RSSI against the node's link-median
   RSSI.
   - If the spread between the strongest and weakest link into the
     same node exceeds **10 dB** (e.g. one antenna shadowed), the
     **weak link's CSI-differential features are disabled** —
     exactly the paper's mechanism translated: one gain-control
     regime is serving two very different signal levels, and the
     phase/imbalance numbers on the weak end are untrustworthy.
   - On multi-channel SDR bridge backends where several receive
     channels share an AGC, the rule applies literally: per-channel
     imbalance > 10 dB → pad the strong channel or drop CSI stats
     on the weak one.
   - **Documented caveat:** the single-chain ESP32 has no on-node
     inter-chain imbalance. The on-node rule is vacuous there; the
     cross-link analogue above is what protects the pipeline.
3. The gate decisions are themselves observable: each gate flip
   (enable/disable per link) emits a health event the dashboard can
   show, so an operator sees *why* a node's CSI channel went quiet —
   "LINK GATED: path loss 63 dB" beats a silent feature.

### Where the confidence math hooks in (§5a/§5b)

The CSI corroboration feeds the existing gated merger
(`lib/services/confidence_merger.dart`) as **existence evidence** —
the same standing shape as `§5a`:

- `e_csi`: non-negative boost from the `dev_hz` band table above,
  capped below camera-motion class (a CSI deviation is corroboration,
  not a sighting). Suggested banding: weak 0.05 / moderate 0.10 /
  strong 0.15 — tunable, and never breaching the merger's +0.35 total
  cap together with other sources.
- Gate weight `w_csi = freshness · health · quality`:
  - **freshness:** 30 s staleness horizon (the ENERGY-class cadence —
    CSI arrives ~1 Hz, slower than the tripwire);
  - **health:** link not link-budget-gated, source polling recently;
  - **quality:** geometry alignment — for CSI this is the *link
    association*: the motion is attributed to the sniffed AP link,
    so quality is the link-geometry overlap of that link with the
    track (same machinery as virtual-link scoring in the SDR path).
- The `wind_gated` flag and any link-budget gate force
  `w_csi = 0` — the AV-FDTI zero-weight case.
- While the track is **INCONSISTENT** (§5b), all upgrades suspend:
  `C_display = C_RF`. Upgrading a misassociated track on CSI
  evidence is exactly the failure the consistency monitor exists to
  prevent.
- Never subtractive (merger property), never identity
  (`C_max = 0.95`).

### SENSOR protocol changes (relates to `sensor_protocol_spec.md` §5a/§5b)

Two new `obs` verbs on the UDP JSON path (port 49160, `type`:
`sensor_obs`), additive and forward-compatible (old app builds skip
unknown verbs per the §1c parser contract):

```json
{"type":"sensor_obs","obs":"CSI","sensor":"csi_ap_buffalo",
 "dev_hz":12.4,"pairs_active":19,"path_loss_db":54.0,"link":"ap:buffalo",
 "wind_ms":1.8,"wind_gated":false,
 "lat":35.10,"lon":-78.90,"t":1760000000.0}

{"type":"sensor_obs","obs":"WIND","sensor":"anem_1",
 "wind_ms":4.2,"gust_ms":6.1,
 "lat":35.10,"lon":-78.90,"t":1760000000.0}
```

| obs | fields |
|---|---|
| CSI | `dev_hz` (req), `pairs_active` (opt), `path_loss_db` (opt — firmware's estimate, app re-derives), `link` (opt, AP/link id), `wind_ms` (opt), `wind_gated` bool (opt, default true-fail-safe when wind unknown) |
| WIND | `wind_ms` (req), `gust_ms` (opt) |

The firmware's UART text path gains matching one-liners for the
wired-anemometer case: `WIND anem1 4.2 6.1` (`name wind_ms [gust_ms]`),
parsed like the existing `SENSOR` lines.

Staleness horizons: CSI 30 s (ENERGY-class), WIND 5 min (weather
changes slowly; a stale wind reading fails safe to `wind_gated`).

The §5a gate-factor table and the §5b consistency section need no
structural change — this spec only *instantiates* them for a new
evidence type. A one-paragraph §5a addendum naming CSI's
`freshness/health/quality` semantics (as above) is the expected
protocol-spec edit.

## Honest-scope limits

- **Tripwire, not radar.** CONFIRMED by the source paper: bird-sized
  movers at meters from the link; vehicle-class at tens of meters at
  most. The spec DOCUMENTS meters-class range explicitly — a CSI
  channel that "sees 200 m" would be fabrication. It detects
  *disturbance on a link*, not a target at a coordinate.
- **No imagery, no identity, no classification of what moved.**
  `dev_hz` bands are *size-class heuristics with confidence*, never
  "crow detected" / "vehicle confirmed". UI wording follows the
  ELRS honesty-contract pattern ("consistent with small-mover
  disturbance").
- **Wind gate is load-bearing, not cosmetic.** Without wind data the
  feature is *off*, not degraded. An operator who deploys in 5 m/s
  wind with no anemometer has an RSSI tripwire, not a CSI motion
  channel — and the spec says so on the dashboard.
- **The 60 dB knee is not an ESP32 number.** CONFIRMED on Intel 5300
  cable bench; field knees on ESP32 hardware will be worse. The
  conservative 55 dB default is a placeholder for a measured number,
  and the spec mandates re-measuring it (test plan, item 4).
- **Encrypted networks change nothing.** The pipeline uses CSI
  phase/amplitude of ambient frames — never payload content. WPA3,
  WPA2, open: same channel math. (Same standing answer as the
  mesh-link question: encryption hides content, not the RF shadow.)
- **Single antenna, no bearing.** An ESP32 CSI link gives a scalar
  disturbance metric. Direction comes only from multi-link fusion
  in the app layer — and even that yields a blob/track estimate,
  never an identified object.

## Test / validation plan

Pass criteria are concrete; a test that cannot fail its criterion is
not a test.

1. **Slope-cancellation unit test** (host-side, synthetic). Inject a
   synthetic CSI frame set with a pure CFO/SFO/packet-delay phase
   slope (α sweeping ±30°/subcarrier — worse than any real link) plus
   a fixed true channel. *Pass:* after symmetric-pair averaging, the
   residual per-pair phase error is < 2° (the paper's healthy-link
   noise floor) across all 32 pairs. *Fail direction:* if it fails,
   the trick doesn't transfer to 20 MHz ESP32 CSI and the design
   stops here.
2. **Hz-deviation discrimination bench.** Two-node outdoor link,
   3–10 m. Human walks the LoS (repeatable, ~1.2 m/s), then a thrown
   object / released bird-class proxy at 4–5 m off-LoS. *Pass:*
   walker windows show `dev_hz` ≥ 10 Hz in ≥ 8 of 10 trials with
   latency < 2 s; no-walk windows (calm, < 2 m/s wind) show
   `dev_hz` < 3 Hz in ≥ 95 of 100 one-second windows. *Documents the
   meters-class limit in our own data.*
3. **Wind-gate false-positive run.** Fan/leaf-blower producing
   3.5–5 m/s at the link with vegetation proxy in the Fresnel zone,
   200 one-second windows. *Pass:* motion-claim false-positive rate
   < 0.5% per window *with* the gate active; *control fail* recorded
   with the gate forced off to prove the gate is doing the work
   (expected: elevated false positives — that is the point of the
   gate).
4. **Link-budget gate field measurement (the ESP32 knee).**
   Attenuate a test link stepwise (distance + RF shielding) while a
   controlled mover crosses. *Pass:* CSI motion-detection Pd drops
   to noise at or before 60 dB estimated loss — confirming the
   conservative 55 dB default sits on the safe side — and the
   gate disables CSI stats automatically at the threshold in ≥ 19 of
   20 trials. *Regression:* the RSSI-only tripwire still fires on
   the same crossings after gating (gating must never subtract
   capability).
5. **Imbalance gate test.** Shadow one antenna of a two-antenna
   test node (or mismatch link levels > 10 dB across links into one
   node). *Pass:* the weak link's CSI features auto-disable with a
   visible "LINK GATED" health event; no phantom motion claims from
   the weak link in 100 windows.
6. **Merger property tests** (app-side, host). *Pass:* CSI evidence
   is never subtractive (`C_display ≥ C_RF` fuzz-tested), the +0.35
   total cap holds with CSI + ELRS + camera evidence combined, and
   forcing `wind_gated`/link-gated/inconsistent states zeroes the
   CSI weight exactly (the AV-FDTI zero-weight case).
7. **No-wind fail-safe.** Boot a node with no wind source.
   *Pass:* CSI motion features report disabled and the dashboard
   says so; the node still delivers RSSI tripwire events.

## Files (existing + proposed touch points)

- `field_kit/esp32/shepherd_node/shepherd_node.ino` — symmetric-pair
  averaging in/after `csi_cb`, 1 s `dev_hz` aggregation in `loop()`,
  wind-gate suppression, `WIND` UART parse, `CSI`/`WIND` UDP JSON
  emission on 49160.
- `lib/services/node_udp_hub.dart` — parse/route the new `CSI` and
  `WIND` `sensor_obs` verbs.
- `lib/services/generic_sensor_driver.dart` — per-link health:
  path-loss estimate, 55 dB conservative CSI gate, 10 dB imbalance
  gate, gate-flip health events.
- `lib/services/sensor_protocol.dart` — typed `CsiObservation` /
  `WindObservation`, 30 s / 5 min staleness horizons, parser contract
  per §1c.
- `lib/services/confidence_merger.dart` — `e_csi` boost banding,
  `w_csi` gates (§5a); suspension on INCONSISTENT (§5b).
- `docs/sensor_protocol_spec.md` — §5a addendum (CSI gate semantics);
  §1b field table (new verbs).
- Proposed tests: `test/csi_pipeline_test.dart` (merger properties,
  gate logic, parser contract), firmware bench notes in
  `field_kit/UPDATE_NOTES.md`.
