# Device auto-connect spec — v0.19.0

**Ask (Draco, 2026-10-19):** once a device family is integrated (Silvus, MPU5,
…), plugging it in should auto-connect it to Shepherd. Same for the ATAK/TAK
CoT link. No SCAN button, no manual IP entry — it just appears.

## Current state (surveyed 2026-10-19)

| Family | Today | Gap |
|---|---|---|
| ESP32 / LoRa nodes | Auto-join via UDP 49160 beacons. Zero-click. | None — the reference behavior. |
| Silvus | Saved configs auto-start at boot; first-time setup needs manual LAN SCAN. USB-C radio (172.17.97.182) is invisible to the app until configured. | No plug-in detection. |
| MPU5 | Driver is a **stub** (`implemented: false`, throws). Telemetry awaits Draco's SNMP walk file (Oct 8 probe). | Driver itself pending — auto-connect slot reserved only. |
| Meshtastic | LAN scan (TCP 4403) works; USB serial needs a TCP bridge (no serial plugin bundled). | USB-serial plug detection needs a serial plugin — phase 2. |
| SDR bridge | Local bridge on 127.0.0.1:49161; driver polls when configured. | Out of scope (not a plugged radio). |
| TAK/CoT emit | Auto-configures on cold start; reconnects with backoff, but the TCP connect is **lazy** (first track publish). | No eager connect — "TAK link" can read dead until the first track. |
| TAK/CoT listen | 15 s watchdog retry via generation-guarded reconfigure. | None. |

## Design: `DeviceAutoConnect` framework

New file `lib/services/device_autoconnect.dart`. One watcher per family,
all behind a common interface:

```dart
abstract class DeviceWatcher {
  /// Family id: 'silvus' | 'mpu5' | 'meshtastic' | ...
  String get familyId;
  /// One poll tick. Returns validated candidates (address + label).
  Future<List<AutoConnectCandidate>> poll();
}
```

The coordinator (`DeviceAutoConnect`) runs all enabled watchers on a
single ~5 s timer, started at app boot alongside the radio pollers:

- **Validate before auto-add.** A candidate becomes a `RadioConfig` only
  after a real protocol handshake (Silvus: `streamscape_data` snapshot
  with ≥1 node). Never auto-add a ghost.
- **Dedupe by address.** An interface flap must not create a second
  config for the same radio. Match on `driverId + address`.
- **Never auto-delete.** Unplug → driver marked offline, config kept.
  Replug → same config resumes. His radios move; configs must survive.
- **No automatic subnet scanning.** LAN SCAN stays a manual button —
  auto-sweeping a /24 is rude on someone else's network, and his
  deployments are on the move.
- **Per-family toggle** in Settings → Radios → "Auto-connect new
  devices", default ON for Silvus USB. Turning a family off stops its
  watcher; existing configs are untouched.

### Silvus watcher (this release)

USB-C presents the radio as a host network interface in 172.17.97.0/24
(his Radio 1: 172.17.97.182). The watcher:

1. `NetworkInterface.list()` (pure `dart:io`, no plugin).
2. If an interface carries 172.17.97.x, probe 172.17.97.182 via
   SilvusApi — the well-known USB address, and the only host ever
   probed. (An earlier draft also probed the interface gateway;
   narrowed to .182 = less network touch.)
3. On handshake success → auto-add `RadioConfig(driverId: 'silvus',
   address: <ip>, label: 'Silvus USB (auto)')` unless a config with
   that address exists → start its poller.
4. Interface disappears → the poller fails fast (no route) and
   `DriverStatus.error` marks it offline; the config is kept and the
   poller resumes on replug. (An earlier draft stopped the poller;
   keeping it is simpler and the failure is already surfaced.)

Ethernet-connected radios (his Radio 2) keep the manual SCAN path —
their address is stable and the saved config already auto-starts.

### MPU5 watcher (slot reserved)

Driver is a stub pending his SNMP walk data — no watcher is built until
the telemetry driver exists. The framework registers the family id now
so the driver + watcher land together later. **Not claimed as working.**

### Meshtastic USB-serial (phase 2, not this release)

Needs a serial-port plugin (not a current dependency). Documented here
so the gap is explicit; the TCP-bridge path is unchanged.

## ATAK auto-connect (this release)

- **Eager TAK connect:** when CoT emit is enabled, `CotPublisher`
  attempts the TAK TCP connection at configure time (cold start and
  toggle-on), not just on first track publish. Existing backoff
  (`_takNextRetryAt`) still paces retries against a dead server.
- **Status surfacing:** the dashboard radio card gains a "TAK link"
  row (connected / retrying / disabled) fed by the publisher's
  existing `_lastError`/socket state. No new protocol, just visibility.
- Listener path unchanged (15 s watchdog already covers it).

## Honesty rules (standing)

- Auto-connect never invents capability: unvalidated candidates are
  invisible, exactly like an unvalidated LAN scan hit.
- The Settings toggles say what they do: "Auto-connect Silvus USB
  (172.17.97.x)". The MPU5 row reads "driver pending" until the
  telemetry driver lands.
- Nothing here transmits. Watchers are RX-only interface polls and
  API handshakes.

## Tests

- `test/device_autoconnect_test.dart`: candidate matcher (interface
  list → probe targets), dedupe-by-address, never-delete-on-unplug,
  per-family toggle gating. The `NetworkInterface.list()` call sits
  behind an injectable `listInterfaces` function so tests don't touch
  the host.
- `test/cot_eager_connect_test.dart`: publisher attempts TAK connect
  on configure when enabled; respects backoff after failure.

## Publish checklist (v0.19.0)

Version bump + CHANGELOG + README note → independent review → push →
kit zip rebuild (verify VERSION) → Drive update (verify md5) → notify.
