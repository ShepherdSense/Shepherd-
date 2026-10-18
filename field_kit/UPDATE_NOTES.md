# Field Kit v1 — update notes (2026-10-16)

## v0.17.0 firmware — ESP32 CSI motion channel (Suzuki pipeline)

**CSI motion channel** in `shepherd_node.ino` (RX-only; sniffs ambient
frames, nothing transmits). Per CSI frame, in/after `csi_cb`: symmetric-
subcarrier averaging `m(k) = (c(+k) + conj(c(-k)))/2` over the 28 valid
20 MHz HT pairs, `arg(m(k))` into per-pair 1 s rings. Once per second:
per-pair Hz-deviation (zero-crossing rate of detrended phase, no
unwrapping), link `dev_hz` = max pair, `pairs_active` above the noise
floor, emitted as `{"type":"sensor_obs","obs":"CSI",...}` on UDP 49160.
`dev_hz` bands are size-class heuristics only — never identity claims;
the 55/60 dB link-budget knees are app-side gates, not firmware.

- **Wind gate**: UART `WIND <name> <wind_ms> [gust_ms]` (text-protocol
  builds); while wind ≥ 3.5 m/s motion claims are suppressed
  (`wind_gated:true`). **No wind source → CSI motion DISABLED by default**
  (fail-safe); the RSSI tripwire is unaffected. WIND lines are forwarded
  as `sensor_obs`/`WIND` so the app merger sees them.
- **`calib` beacon flag**: `/calib?v=1` marks the node as participating
  in the app's vacant-window calibration; RAM-only (cleared on boot,
  auto-expires after 3 min) so a mid-window reboot never contaminates
  the fit.
- **Bench mode** (`-DCSI_BENCH`, off by default, never shipped): pushes
  CSI amplitude reports at 100/250/500/1000 Hz with sequence numbers,
  60 s per step, over UDP 49160; logs offered/sent/drops, per-core CPU
  (idle-hook method), heap low-water, and ambient CSI fps per step.

## v1.2 — SDR bridge for (almost) every SDR (evening)

**Universal SDR bridge** (`field_kit/sdr_bridge/`) — owners of RTL-SDR,
ADALM-Pluto, USRP B200/B210, HackRF, Airspy, LimeSDR, SDRplay, or bladeRF
hardware can now use their radios with Shepherd. Receive only, by
construction (no TX code path exists; the RTL-SDR can't transmit at all).

- `sdr_bridge.py`: sweeps the drone bands (433/915/1290/2437/5780 MHz,
  skipped above each radio's ceiling) or stares at one; per-band energy +
  sub-band peaks over UDP to Shepherd. Backends: rtlsdr, pluto, uhd,
  soapy (HackRF/Airspy/Lime/SDRplay/bladeRF via SoapySDR), simulate
  (scripted synthetic spectrum — verifies the whole pipeline with no
  hardware), auto (first working backend wins).
- `RUN_SDR_BRIDGE.bat`: double-click launcher (venv + deps + run).
- **In-app driver** (`SdrDriver`, in this release's source): each band
  becomes a virtual tripwire link via a polarity trick — negated dBFS
  energy makes an emitter *appearing* read as a link dip, so adaptive
  thresholds, baseline hold, alerts, and the event log work unchanged.
  Band links are deliberately excluded from the position solver (no
  geometry); alerts are the product. Add via Settings → SDR.
- Honest limits: one radio = energy, not direction; sweep gaps are real
  (stare mode closes them for one band); dBFS is gain-relative; know
  your ceiling (an RTL-SDR will never see 2.4 GHz).

## v1.0 — initial field kit (morning)

**ESP32 Shepherd Node firmware** (`field_kit/esp32/`) — flash once, then
every USB plug-in is just power. The node boots, hosts its own WiFi AP,
and runs every sensor it can find:

- Built-in: WiFi CSI/RSSI sniffer with an on-board tripwire detector
  (rolling baseline + MAD threshold, baseline hold during events), and a
  BLE advertisement scanner (new-device hint events).
- SPI auto-detect: nRF24L01 (2.4 GHz band-energy sweep) and CC1101
  (sub-GHz RSSI, default 433.92 MHz) are probed at boot and enabled only
  if the module answers.
- UART: any external module can stream `SENSOR <name> <rssi_dbm>` lines.
- Broadcasts beacons + events on UDP 49160 with a tiny status page at
  http://192.168.4.1. Verified: compiles clean on ESP32 Arduino core
  2.0.17 (huge_app partition).

**Thumb-drive field installer** (`field_kit/thumbdrive/`) —
`INSTALL_SHEPHERD.bat` installs the newest Shepherd on any Windows PC
(checks GitHub for a newer release, builds from the bundled copy
offline), and `FLASH_NODE.bat` flashes the pre-compiled node firmware
with one double-click. No Arduino IDE needed.

**Mesh-mode spec** (`docs/mesh_mode_spec.md`) — automatic
tripwire/mesh switching for 3+ nodes, with the embedded tiny AI
managing the switching and multi-node fusion.

**DF node variant spec** (`docs/df_node_spec.md`) — pseudo-Doppler
direction-finding node for general-direction bearings on external
emitters. v1 honestly scoped as switched-antenna RSSI comparison.

## Notes for testers

- Compiled firmware binaries ship in the field-kit zip (binary upload
  isn't supported in this repo's web flow); the `.ino` source is here
  and builds with the standard ESP32 Arduino core.
- Full zero-click node pickup in the app activates with the ESP32 driver
  (mesh-mode Phase 1). The installer already stages the discovery
  config (`shepherd_field_kit.json`).
- Everything here is defensive-only: sensing and fusion, no transmit.
  See CONTRIBUTING.md.
