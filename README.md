# Shepherd

**Device-free RF sensing — a tripwire observatory that sees objects moving through radio noise.**

Shepherd turns the RF links of a mesh radio network into a sensing field. When an object crosses a link, the link's signal dips; Shepherd polls each radio's telemetry, tracks every link against a rolling baseline, and flags disturbances as crossing events — then fuses them into tracks with estimated size, distance, speed, and heading. No cameras, no tags, nothing worn or carried. Just the RF field itself.

Built by **Draco**.

## What it does

- **Alert-first dashboard** — big DETECTED / CLEAR banner, per-radio status cards, live link telemetry.
- **Tracking map** — draggable field map with per-node GPS positions, radio-tomographic shadow heatmap, and deterministic cross-network track solving (grid-search position solver; altitude when nodes are at different heights).
- **Beam 3D** — orbit-able antenna lobe visualization with first Fresnel zone ellipsoids.
- **WiFi Vision** — ambient disturbance sensing via the device's own Wi-Fi adapter (coarse RSSI tripwire, per-AP baselines, disturbance attribution by elimination).
- **Air Threats (defensive)** — rogue AP / evil-twin suspicion and disconnect-burst (deauth-pattern) recognition. Detect-only: Shepherd never transmits.
- **Nearby wireless** — passive BLE advertisement scanning with vendor decoding, plus LAN device sweep.
- **Embedded tiny AI (offline)** — pure-Dart neural nets running fully on-device: a crossing-event classifier and a track-stitching specialist, both trained on synthetic scenarios. No cloud, no LLM.
- **GPS positioning** — walk to each node and capture its position; defended-point marker with INBOUND / OUTBOUND / TRANSITING readouts.
- **ZMeta export (tactical → operational)** — emit-only ZMeta event adapter: detections ship as `OBSERVATION_EVENT`/`INFERENCE_EVENT` over UDP to a ZMeta gateway, which fuses across Shepherd meshes. The tactical→operational link is secured with WireGuard (`field_kit/zmeta_secure/`).
- **Fade-aware tripwire + VRTI** — per-link fade levels judge disturbances against their expected direction (dip vs. rise); a variance channel catches slow movers the mean misses.
- **SDR FHSS signature detector** — band-plan presets (`--plan fpv/dji/longrange/lora`) and rolling sub-band occupancy hints (`fhss-2g4`, `ofdm-5g`, …): signatures, never identity.
- **ELRS Gemini signature detection** — RX-only DSP in the SDR bridge finds LoRa chirp trains (ELRS's LoRa modes) and scores the Gemini dual-emission signature: time-correlated trains on two frequencies (~40 MHz apart @ 2.4 GHz) or two bands at once (2.4 GHz + 900 MHz, GemX). Surfaced as upgrade-only corroboration in the evidence view. The first public ELRS-specific detector; see `docs/elrs_detection_spec.md`.
- **Adaptive baseline + dial-it-in calibration** — per-link reference levels that follow slow environmental drift instead of re-tripping the tripwire; the operator captures a known-clean baseline profile before an event. Calibrates the *reference* — never claims targets, identity, or range.
- **Direction-split RTI imaging** — the shadow heatmap weights disturbances with fade-signed, direction-split, area-normalized weights, so blobs land where the link geometry says they should.
- **ESP32 CSI motion channel** — outdoor-usable Wi-Fi CSI motion sensing on the field-kit nodes: phase-cancellation averaging, a wind gate, and link-budget gates that zero-weight the channel on weak links. Meters-class tripwire — existence evidence, never identity.
- **Doppler-only track refinement** — the SDR bridge measures radial velocity off ambient LTE downlink (~0.16 m/s resolution at 1.86 GHz) as a second opinion on a track's motion. Upgrade-only: agreement can raise confidence, disagreement never deletes a track.
- **WPP-IDP passive radar** — no-clean-reference passive radar on signals of opportunity: per-packet energy → DC removal → STFT chain, with a waveform rule scoring candidate illuminators. Micro-Doppler corroborates *motion*, never *identity*. Meters-to-tens-of-meters.
- **Validation benches** — AERPAW flight-test replay through the fusion machinery (validates the fusion, not the sensing) and an ESP32 500 fps CSI frame-rate go/no-go bench.
- **Operator tools** — event timeline scrubber, alert triage (ACK / false-alarm with tuning stats), spectrum-band panel, node health map, record/replay with "why did it alert" evidence view.

## What it works with

| Hardware | Status | Notes |
|---|---|---|
| Silvus StreamCaster mesh (any node count) | **Live** | One radio's telemetry carries the whole mesh view; tripwire, tracker, and map all scale per-link |
| L3Harris AN/PRC-163 | **In progress** | SNMP discovery probe in `tools/`; driver follows what the radio exposes |
| MPU5 / Wave Relay | **Planned** | Driver stub in the multi-driver framework |
| Meshtastic nodes | **Live** | TCP 4403 client API; GPS auto-placement, coarse link health, LAN auto-detect; USB serial via TCP bridge |
| ESP32 nodes (WiFi / LoRa backhaul) | **Live** | Passive UDP 49160 listener; WiFi-direct nodes and SX1276 LoRa-gateway re-emits, zero config |
| This device's Wi-Fi + BLE | **Live** | Windows via `netsh`; passive scan only |
| ZMeta gateway | **Live** | Emit-only event export (Settings → ZMeta export); gateway fuses across meshes; link secured via WireGuard |

Two mesh nodes = one link = tripwire. Three or more nodes unlock tracking.

## Install

### Windows

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) **outside** OneDrive (e.g. `%LOCALAPPDATA%\flutter`) — OneDrive file-locking breaks Flutter's cache.
2. Enable **Developer Mode** (Settings → System → For developers) — required for plugin symlinks.
3. Clone this repo, then:
   ```
   cd shepherd
   flutter pub get
   flutter run -d windows
   ```
4. Open the Settings gear → turn off simulated mode → enter your radio IP.

For a standalone install, double-click **`build_exe.bat`** — it compiles a portable release folder and zips it to your Desktop. (Unsigned binary: SmartScreen → *More info → Run anyway*.)

### Android

1. Install the Android SDK and accept licenses.
2. Double-click **`build_apk.bat`** — it checks prerequisites, then builds `shepherd.apk`.
3. Install the APK on the device; grant location permission for GPS node capture.

> **Launcher icons:** the `android/app/src/main/res/mipmap-*/ic_launcher.png`
> files are not stored in this repo (binary upload isn't supported here) —
> copy them from your local project into the same paths before building,
> or regenerate them with
> [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons).

> **Note:** `lib/services/wifi_aware.dart` / `MainActivity.kt` contain experimental Wi-Fi Aware discovery (hand-written, cooperative-only). If the APK build fails in `compileReleaseKotlin`, that file is the first suspect — deleting it and its channel block builds fine without the Aware panel.


## Field Kit

Stand up new sensor nodes and new Shepherd installs without touching a terminal:

- **ESP32 sensor node** — a cheap (~$10 class) auto-join sensor node. Flash it once; after that, every USB plug-in is just power: it boots, hosts its own status page, and auto-joins Shepherd's discovery. On board: a Wi-Fi tripwire detector, a BLE presence scanner, auto-detect plug-in nRF24L01 / CC1101 RF modules, and a simple serial protocol for attached sensors.
- **Thumb-drive installer** — plug the drive into any Windows PC and double-click to install the latest Shepherd and set up automatic node detection.
- **SDR bridge** — owners of RTL-SDR, ADALM-Pluto, USRP B200/B210, HackRF, Airspy, LimeSDR (and friends) can use their radios as Shepherd sensors (receive only). Each watched band becomes a virtual tripwire link; an emitter appearing reads as a link dip.

Download the kit (ZIP): [Shepherd Field Kit v1](https://drive.google.com/file/d/1xcCs_LQVoSrefEfABMa3RTDOGWKvsENd/view?usp=drivesdk)

Sources live in `field_kit/` — firmware, installer scripts, and [update notes](field_kit/UPDATE_NOTES.md). Full in-app auto-detection of these nodes lights up when the ESP32 driver lands (mesh-mode Phase 1).

## Screenshots

See [`docs/screenshots/`](docs/screenshots/) — captured from the live app.

## Honest scope

Shepherd states its limits in the UI, not just here:

- **RF shows a radar scope, not a camera.** Tracks are moving blobs with size/distance/speed/heading estimates — never silhouettes or identities.
- Two nodes cannot triangulate; altitude needs nodes at different heights.
- Wi-Fi RSSI sensing is coarse signal disturbance only: no CSI imaging, no bearing, no object ID.
- Type guesses are heuristic and always labeled low-confidence.
- The embedded AI classifies closed events — it never suppresses alerts.
- RF signatures (ELRS Gemini, FHSS hints) say "consistent with", never "confirmed" — the detector can't distinguish ELRS from other LoRa FHSS emitters with certainty, and the UI enforces that wording.
- Paper accuracy numbers are not transferred: cited figures come from other regimes (30+ node meshes, stationary humans) — Shepherd's 6-node, on-the-move, airborne-target regime re-measures from zero. Features are implemented per spec and bench-tested; field validation is pending.
- Micro-Doppler is never used for identity — it corroborates motion only: "consistent with, never confirmed".
- CSI motion is a meters-class tripwire: existence evidence in the gated merger, never a position fix.
- Doppler disagreement never deletes tracks — the refinement layer is upgrade-only.
- WPP-IDP passive radar is meters-to-tens-of-meters accuracy — never fire-control quality.

## Layout

```
lib/
  screens/    dashboard, tracking, beam 3D, WiFi vision, settings
  services/   radio drivers, tripwire, tracker, AI classifier, BLE, WiFi
  state/      app state + persistence
  models/     LinkSample and tracking models
  theme.dart  dark-mode design system
android/      Android shell (Wi-Fi Aware Kotlin lives here)
tools/        PC-side helpers (SNMP radio probe, etc.)
docs/         specs and screenshots
build_exe.bat / build_apk.bat   one-shot builders
```

## License

MIT — see [LICENSE](LICENSE). Contributions welcome: fork, branch, pull request.
Please read [CONTRIBUTING.md](CONTRIBUTING.md) first — Shepherd stays
defensive-only, and contributions must keep it that way.
