# Field Kit v1 — update notes (2026-10-16)

## v1.1 — AD936x SDR support (evening)

**AD936x spectrum-sensor bridge** (`field_kit/ad936x_bridge/`) — owners of
ADALM-Pluto / USRP B200/B210 hardware can now use their radios with
Shepherd. Receive only, by construction (no TX code path exists).

- `ad936x_bridge.py`: sweeps the drone bands (433/915/1290/2437/5780 MHz)
  or stares at one; per-band energy + sub-band peaks over UDP to Shepherd.
  Backends: pluto (pyadi-iio), uhd (B200/B210), simulate (scripted synthetic
  spectrum — verifies the whole pipeline with no hardware), auto.
- `RUN_AD936X_BRIDGE.bat`: double-click launcher (venv + deps + run).
- **In-app driver** (`Ad936xDriver`, in this release's source): each band
  becomes a virtual tripwire link via a polarity trick — negated dBFS
  energy makes an emitter *appearing* read as a link dip, so adaptive
  thresholds, baseline hold, alerts, and the event log work unchanged.
  Band links are deliberately excluded from the position solver (no
  geometry); alerts are the product. Add via Settings → AD936X.
- Honest limits: one radio = energy, not direction; sweep gaps are real
  (stare mode closes them for one band); dBFS is gain-relative.

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
