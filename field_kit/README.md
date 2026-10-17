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

**Honest scope:** ESP32 CSI is coarse — a cheap distributed tripwire
layer, not Silvus-grade MIMO. It reports link disturbances, never
identities. Event classes (PASSING/LINGERING) are crude duration
heuristics shown as estimates.

## Automatic detection

Nodes announce themselves two ways: UDP beacons on port 49160 and mDNS
`_shepherd-node._udp`. The installer writes `shepherd_field_kit.json`
next to the app — the discovery contract the upcoming ESP32Driver
(mesh-mode Phase 1, see `rf_sentry/docs/mesh_mode_spec.md`) reads on
startup. Full zero-click node pickup activates with that driver; this
kit gets the app installed, the nodes flashed, and discovery staged, so
when the driver lands the nodes appear with no further config.

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
