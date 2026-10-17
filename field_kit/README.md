# Shepherd Field Kit

One thumb drive that fields the whole Shepherd sensor layer:

1. **`INSTALL_SHEPHERD.bat`** — double-click on any Windows PC. Installs the
   newest Shepherd (checks GitHub for a newer release, falls back to the
   bundled copy offline), builds it, drops a desktop shortcut, and stages
   the node auto-detection config (`shepherd_field_kit.json`).
2. **`FLASH_NODE.bat`** — double-click with an ESP32 plugged in. Flashes
   the pre-compiled Shepherd Node firmware. No Arduino IDE needed.

## The ESP32 node

Flash once — thereafter every USB plug-in is just power. The node boots,
hosts its own WiFi AP (`Shepherd-SHN-XXXX`, password `shepherd-field` —
change it), sniffs WiFi channel-state (CSI) promiscuously, runs a small
deterministic tripwire at the edge (rolling baseline + MAD threshold,
baseline hold during events), and broadcasts compact beacons/events on
UDP 49160. Status page at http://192.168.4.1 when joined to its AP.

Source: `esp32/shepherd_node/shepherd_node.ino`
Pre-compiled binaries: `thumbdrive/firmware/` (flash with esptool)

**Wiring (SPI modules):** SCK 18, MISO 19, MOSI 23; nRF24L01 CS 4 and
**CE 22** (the node holds CE high — the nRF24 only measures energy while
CE is high; a module with CE tied to 3V3 also works, leave GPIO22
unconnected); CC1101 CS 21. nRF24 and CC1101 channels report energy, so
an emitter appearing raises the reading and fires an event.

**Honest scope:** ESP32 CSI is coarse — a cheap distributed tripwire
layer, not Silvus-grade MIMO. It reports link disturbances, never
identities. Event classes (PASSING/LINGERING) are crude duration
heuristics shown as estimates.

## The SDR bridge

Got an SDR? `sdr_bridge/` turns it into a Shepherd sensor: RTL-SDR,
ADALM-Pluto, USRP B200/B210, HackRF, Airspy, LimeSDR, SDRplay, bladeRF
(the last five via SoapySDR). **Receive only — the bridge never transmits.**

Double-click `RUN_SDR_BRIDGE.bat` on the PC (with `--simulate` for a
hardware-free test; `--backend rtlsdr` / `pluto` / `uhd` /
`soapy --soapy-driver hackrf` for hardware). The bridge sweeps the drone
bands (433 / 915 / 1290 / 2437 / 5780 MHz — skipped above your radio's
ceiling), measures per-band RF energy, and ships readings to Shepherd
over UDP. Shepherd treats each band as a virtual tripwire link — an
emitter *appearing* in a band reads as a link dip, so adaptive
thresholds, baseline hold, alerts, and the event log all work unchanged.
In the app: Settings → add radio → **SDR** (address prefills to
`127.0.0.1:49161`).

**Honest scope:** one radio reports band *energy*, not direction, range,
or identity. Band links are kept out of the position solver (no geometry)
— alerts and the event log are the product. Full spec:
`docs/sdr_driver_spec.md` in the repo.

## Automatic detection

Nodes announce themselves two ways: UDP beacons on port 49160 and mDNS
`_shepherd-node._udp`. The installer writes `shepherd_field_kit.json`
next to the app — the discovery contract the upcoming ESP32Driver
(mesh-mode Phase 1, see `rf_sentry/docs/mesh_mode_spec.md`) reads on
startup. Full zero-click node pickup activates with that driver; this
kit gets the app installed, the nodes flashed, and discovery staged, so
when the driver lands the nodes appear with no further config.


## Secured ZMeta link (tactical → operational)

Shepherd works at the tactical level; a ZMeta gateway fuses detections
across meshes at the operational/strategic level. The link between them
**must** be secured — `zmeta_secure/` has everything:

1. Double-click **`NEW_MESH_KEY.bat`** on the mesh PC to generate its
   WireGuard keypair (private key never leaves that PC).
2. Send only the `.pub` file to the gateway operator.
3. Operator adds a `[Peer]` block to the gateway config and registers the
   mesh in `PEERS.md` (tunnel IP ↔ platform ID binding).
4. In the app: Settings → ZMeta export → point host at the tunnel
   address, tick "link secured".

Full architecture: `docs/zmeta_deployment.md` in the repo.

## Passive radar (R&D prototype)

`passive_radar/` is an offline research prototype — passive coherent
location using broadcast illuminators (FM/DVB-T), receive-only, with a
synthetic demo. Not a field sensor; honest-scope notes in its README.

## LoRa nodes (two ways in)

Whatever LoRa hardware is on hand works as a Shepherd node:

**A. Meshtastic devices (no flashing).** In the app: add radio →
MESHTASTIC → enter the node's LAN IP (or 127.0.0.1 for a USB-bridged
node). "Find radios on LAN" auto-detects them. Nodes appear on the map
from their mesh GPS; you get presence + coarse link health. USB-serial
nodes go through the standard serial-to-TCP bridge.

**B. ESP32 + SX1276 tripwire nodes (flash once).** For real tripwire
sensing at LoRa range:
1. Double-click `FLASH_LORA_GATEWAY.bat` (gateway ESP32) and
   `FLASH_LORA_NODE.bat` (each node ESP32) — pre-compiled firmware in
   `thumbdrive/firmware_lora/`.
2. Join the `Shepherd-LoRa-XXXX` AP from the Shepherd PC
   (password `shepherd-field`).
3. In the app: add radio → ESP32 NODE. Detections stream in, zero config.

The node senses with WiFi (edge tripwire) and uses LoRa purely as
backhaul — compact binary packets, ~22 bytes, beacons every 30 s.
Region is a compile flag (default US 915 MHz). Sources:
`esp32/lora_node/`, `esp32/lora_gateway/`. Full spec:
`docs/lora_nodes_spec.md` in the repo.

**Honest scope:** Meshtastic = coarse presence/health (minute-scale
telemetry), not tripwire-grade. LoRa range is km-class line-of-sight,
less in clutter/urban; the backhaul carries detections only.

## Honest notes

- Windows blocks true USB auto-run (since Win 7, for security). The one
  double-click on `INSTALL_SHEPHERD.bat` IS the install step — there is
  no way around that on stock Windows.
- First run may trip SmartScreen (unsigned script): More info → Run anyway.
- The installer puts Shepherd in `%USERPROFILE%\Shepherd` — outside
  OneDrive, so builds don't fight file sync.
- The GitHub "newer release" check only works once releases are tagged
  in the repo; until then the bundled copy (VERSION file) is used.
- Default AP password is `shepherd-field`. Change it per deployment
  (node stores it in Preferences; re-flash or extend the status page).
