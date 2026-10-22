# LoRa PSK Codec Spec — Shepherd binary codec v2 (encrypted backhaul)

Status: implemented in `field_kit/esp32/lora_node/lora_node.ino` and
`field_kit/esp32/lora_gateway/lora_gateway.ino`. The wrap/unwrap codec
itself lives in ONE shared header,
`field_kit/esp32/shepherd_lora_psk/src/lora_psk_codec.h`, used by both
sketches — it is an Arduino library, so copy
`field_kit/esp32/shepherd_lora_psk/` into your Arduino libraries
folder before compiling either sketch. Companion to
`docs/lora_nodes_spec.md` (Path 2). Host-side test vectors and tests:
`field_kit/esp32/tests/`.

## Why this exists (threat)

Codec v1 put the node ID suffix (the XXXX in `SLN-XXXX`) in plaintext at
bytes [2–3] of every beacon and event packet, and nothing on the LoRa
path was encrypted. Aras et al., *Selective Jamming of LoRaWAN using
Commodity Hardware* (MobiQuitous 2017, arXiv:1712.02141) demonstrated
98–99.9% per-node selective jamming with ~€100 of hardware (RFM95 +
Arduino), enabled precisely by reading the **unencrypted node address**
out of the packet header and jamming only that node's frames. A v1
Shepherd node hands a local adversary the same targeting handle on every
30 s beacon and every tripwire event.

Scope of the fix, honestly stated:

- This is **confidentiality + integrity for our own telemetry** on a
  star backhaul. It removes the plaintext targeting handle and makes
  forged/tampered frames detectable.
- The adversary model is a **local** one: someone within RF range with
  an SDR/commodity LoRa gear. Nothing here concerns the internet.
- Encryption does not stop barrage jamming, and a determined adversary
  can still see that *a* 34-byte frame was transmitted (traffic
  presence), just not whose it is or what it says.
- Shepherd's short packets at SF7 remain in the regime where the Aras
  wormhole/replay variant measurably fails (reaction-time bound) — and
  v2 additionally authenticates frames (below).

## Wire format

### v1 (legacy, unchanged) — 22 bytes

Byte [0] = schema `1`, byte [1] = type (0x01 beacon / 0x02 event),
bytes [2–21] = fields, all big-endian. Layout exactly as documented in
the `lora_node.ino` header. **v1 is not modified by this spec.**

### v2 (PSK) — 34 bytes

```
[0]      schema = 2                                  PLAINTEXT
[1..8]   nonce: boot_ctr u32 BE || frame_ctr u32 BE  PLAINTEXT
[9..29]  ciphertext (21 bytes)
[30..33] CCM tag (4 bytes)
```

- The ciphertext is the AES-128-CCM encryption of the **v1 payload
  bytes [1..21]** — i.e. the type byte and all fields, byte-for-byte
  the same content the v1 encoder produces after the schema byte. The
  v1 encode functions are reused unchanged; v2 is a wrapper.
- Byte [0] stays plaintext **on purpose**: the gateway's first check is
  the schema gate (drop anything that isn't a known schema), and that
  gate must work before — and without — decryption.
- The nonce is plaintext because nonces are not secret; they must only
  be **unique per key**. It is additionally authenticated (it feeds the
  CCM computation; see below), so it cannot be altered in transit
  without failing the tag check.
- Associated data (AAD) for CCM = the single schema byte (0x02). The
  schema byte is therefore integrity-bound even though it is readable.

### Size / airtime

Expected during design: ~32 bytes. **Actual: 34 bytes.** The +2 over
the estimate buys the 8-byte nonce (below CCM's practical minimum,
nonce-reuse risk stops being negligible) while keeping the standard
4-byte tag. Airtime at SF7 / 125 kHz / CR 4/5: ~77 ms per packet vs
~57 ms for v1. A 30 s beacon cadence is then a 0.257% duty cycle —
still far under the EU868 1% limit and immaterial under US915. Events
remain rare by design.

## Cryptographic choices (and why)

- **Algorithm: AES-128-CCM** (NIST SP 800-38C), key length **128 bits**
  (16 bytes). CCM is the AEAD mode standardized for constrained radio
  links (IEEE 802.15.4 uses it; LoRaWAN's MIC is the same 4-byte class).
  On the ESP32, the mbedTLS CCM implementation runs on the chip's
  **hardware AES accelerator** — no software AES tables, negligible
  CPU/energy cost at one packet per 30 s.
- **Why AEAD and not plain CTR/CBC encryption:** wrong-PSK rejection is
  a hard requirement. With an unauthenticated mode, a gateway holding
  the wrong key would "decrypt" garbage that can accidentally parse as
  a valid packet and be re-emitted. The CCM tag makes decryption
  *verifiable*: wrong key, flipped bit, or altered nonce ⇒ tag check
  fails ⇒ packet dropped and counted, never decoded. Confidentiality
  without integrity would not meet the requirement.
- **Why no padding:** CCM is built on CTR mode — ciphertext length
  equals plaintext length exactly (21 bytes in, 21 bytes out). The
  codec is fixed-size, so there is nothing for padding to do and no
  padding-oracle surface to manage. CBC + PKCS#7 would have cost a
  full extra block (payload 21 → 32 bytes) for zero benefit here.
- **Tag length: 4 bytes (32 bits).** A forgery needs ~2^32 attempts;
  each attempt costs the attacker a full LoRa transmission (~77 ms) at
  a gateway that silently drops and *counts* failures — physically
  absurd to brute-force over this link, and the failure counter makes
  the attempt visible. This matches the LoRaWAN MIC precedent.
- **Nonce: 8 bytes = `boot_ctr` ‖ `frame_ctr`.**
  - `frame_ctr`: 32-bit RAM counter, starts at 0, increments on every
    transmitted packet (beacon or event), never reused within a boot.
  - `boot_ctr`: 32-bit counter persisted in the node's Preferences
    (NVS), incremented **once per boot**. One NVS write per boot is
    negligible flash wear; a per-packet NVS counter would not be.
    The node reads the value back after writing and compares: if the
    write did not land, this boot would reuse a previous boot's
    counters and repeat nonces under the same key — so on a mismatch
    the node refuses to transmit v2 at all, loudly (Serial + status
    page), rather than fall back to anything. (The host-side model
    does not simulate NVS faults; this guard is firmware-only.)
  - The pair makes (key, nonce) reuse impossible in practice without
    trusting a random number generator, and survives reboots —
    the two failure modes of naive counter schemes (reset reuse,
    RNG dependence) are both designed out. 2^32 boots and 2^32
    packets-per-boot are not reachable states for this hardware.
- **Freshness / replay:** after a successful tag check, the gateway
  keeps the last accepted (`boot_ctr`, `frame_ctr`) per node and drops
  frames that are not strictly newer (same boot and counter ≤ last).
  Where that state lives matters, so it is specified:
  - **Dedicated storage.** Freshness state lives in its own 48-entry
    table, written only after a frame passes the tag check — never in
    the gateway's 16-entry "recently heard" display table. (It
    originally lived in the display table, and a display table filled
    by unauthenticated v1 traffic silently disabled the replay check
    for nodes that had no display entry. The display table is
    cosmetics; nothing security-relevant may consult it.)
  - **Fail closed.** If a frame's freshness cannot be established
    (unknown node and the freshness table is full), the frame is
    dropped and counted (`rxNoState` on the status page), never
    decoded. 48 entries is ~10× the design fleet ("a handful per
    gateway"); a climbing no-state counter is the operator's signal.
  - **Persisted across gateway reboots.** The table is written to the
    gateway's NVS on every accepted v2 frame and restored at boot.
    Without this, a reboot forgot every high-water mark and a single
    replayed frame could re-seed a node's mark — locking the genuine
    node out as a "replay" until its frame counter caught up with the
    seed (at the 30 s beacon cadence, a 5000-frame seed is ~41 h of
    lockout). Writes at beacon rate are acceptable: ESP32 NVS is
    log-structured and wear-levelled across its partition, and at
    most one write per 30 s per node this is decades of margin.
  - **Lower-boot resync — stated honestly.** If a frame arrives with
    a `boot_ctr` LOWER than the stored one, the gateway accepts it,
    unconditionally, and rewinds the stored state to that frame's
    counters. The code does not and cannot tell *why* the boot
    counter went backwards. The intended trigger is a node whose NVS
    was wiped (reflash), whose `boot_ctr` restarts low — without
    resync it would be locked out forever. The actual consequence is
    wider: ANY captured frame from an older boot (it must still pass
    the tag check under the current PSK), replayed over the air,
    rewinds that node's state — after which that older boot's frames
    with higher frame counters become acceptable again: a replay
    window for that boot's stale telemetry. Frames from the node's
    current (higher) boot remain acceptable afterwards, so a rewind
    never locks the genuine node out. This is an accepted, disclosed
    trade: replayed content is stale telemetry the app already ages
    out, and the primary design goal is killing the selective-jamming
    handle.

## Key representation and provisioning

- The PSK is a **per-deployment** 128-bit key, written as **32 hex
  characters**. One key per deployment (all nodes + the gateway share
  it); deployments do not share keys with each other.
- Generate it on a PC/phone, e.g. `openssl rand -hex 16`, and treat it
  like a password for the deployment.
- **There is deliberately NO compiled-in default key.** An unconfigured
  device is never silently keyed with a known value. Instead:
  - A node with no PSK **transmits legacy v1 plaintext** and says so
    loudly: a Serial banner at boot and a red warning card on its
    status page ("LoRa PSK NOT SET — transmitting PLAINTEXT v1").
  - A gateway with no PSK decodes v1 only, drops v2 frames (counted,
    shown on its status page), and shows the same NOT SET warning.
- **Setting the key (existing config surfaces only):**
  - Node: join the node AP → status page (192.168.4.1) → "LoRa
    security" card → paste the 32 hex characters → Save. Stored in
    Preferences (`psk_hex`, namespace `sln`); takes effect on reboot.
    A "Clear PSK" button removes it (back to legacy v1) — but only
    via the key-ID confirmation described below.
  - Gateway: identical flow on the gateway status page (namespace
    `slg`). Gateway displays auth-failure / legacy / replay counters
    so a mismatched key is diagnosable from the page.
- **Key ID:** both pages display a 4-hex-char key ID = the first two
  bytes of SHA-256(PSK). It exists so the operator can confirm node
  and gateway hold the *same* key without either page ever displaying
  the key itself. (2 bytes is a human cross-check, not a security
  control.)
- What "never transmitted" means here — stated precisely: the key is
  never transmitted **over LoRa**, never logged, and never shown back.
  It IS transmitted exactly once per device, during provisioning: as
  a cleartext HTTP POST from the operator's browser to the device's
  status page, over the device's own Wi-Fi AP. That AP ships with a
  public default password (`shepherd-field`), so **change the AP
  password before setting the PSK**: join the AP → open the status
  page → in the AP-password card, enter a new password (8–63
  characters, the WPA2 rule; shorter is refused and nothing is
  stored) → Save → reboot the device → rejoin the AP with the new
  password. The new password is stored in Preferences (`ap_pass`, the
  same key boot already read) and takes effect on that reboot; the
  status page always shows which state it is in — "public DEFAULT
  still in use" or "custom set" — and never displays the password
  itself. Changing the AP password is not the whole job: WPA2 still
  admits anyone who knows the password, so also set the PSK in a
  controlled RF environment (close range, before deployment, away
  from unknown radios). Anyone who captures that one POST holds the
  deployment key.
- **Clearing the key is deliberately harder than setting it.** On
  BOTH node and gateway, Clear PSK requires the operator to type the
  currently displayed key ID into a confirmation field. A wrong or
  absent confirmation is refused, counted (shown on the status page),
  and logged on Serial; the key stays set. Rationale: clearing
  silently downgrades the deployment's wire to plaintext, and the
  only other thing guarding the page is the public-default AP
  password.

## Gateway processing order (normative)

1. If byte [0] is not a known schema (1 or 2) → **drop**. (Gate first;
   no decryption is attempted for unknown schemas.)
2. Schema 1 → require length 22 → legacy decode path, unchanged.
   Counted as a legacy packet when it decodes; a malformed schema-1
   frame counts as bad, not legacy (see mixed fleet).
3. Schema 2 → require length 34 → require a locally configured PSK
   (none ⇒ drop, counted) → AES-128-CCM authenticate-and-decrypt with
   AAD = byte [0] → tag failure ⇒ drop, auth-failure counter++, never
   decoded or re-emitted → freshness check against the dedicated,
   NVS-persisted state (unverifiable ⇒ drop + no-state count, never
   decoded) → rebuild the equivalent v1 buffer and hand it to the
   **existing** decode/re-emit path.
4. Because step 3 feeds the same decode path, the gateway's UDP 49160
   JSON output for a v2 packet is **byte-for-byte identical** to the
   output for the equivalent v1 packet. The Shepherd app driver is
   untouched by this change.

## Mixed fleet / transition (normative, deliberately simple)

- **New gateway + old nodes:** works. The gateway accepts v1 and v2
  side by side and counts v1 ("legacy") frames on its status page, so
  the operator can watch the count stop growing as nodes are updated.
- **New node, PSK not yet set + any gateway:** node sends v1; works;
  the node's page and Serial log say PLAINTEXT until the key is set.
- **Node with PSK set + OLD gateway firmware:** the old gateway drops
  schema 2 at its gate — the node appears dead. This is expected, not
  a fault. **Migration order is therefore: (1) flash gateways,
  (2) set the gateway PSK, (3) set each node's PSK.** Do it in that
  order and no node ever disappears.
- **PSK mismatch (node key ≠ gateway key):** every v2 frame fails the
  tag check and is dropped; the gateway's auth-failure counter climbs
  and nothing is re-emitted. The node cannot tell (the backhaul has no
  ACKs — a pre-existing protocol property, not a v2 regression).
  Diagnosis: compare key IDs on the two status pages.
- There is no automatic downgrade: a PSK node never falls back to
  plaintext on its own, and a gateway never "helpfully" guesses.

## Out of scope

- The Wi-Fi-side node callsigns (`SLN-XXXX` shown on the map and pages)
  are a deliberate operator feature and are **unchanged**. v2 protects
  the LoRa wire, not the operator's own displays. (The UDP JSON feed
  on the local AP is likewise unchanged — it is the operator's local
  network, and the app contract depends on it.)
- The Dart app / `esp32_driver.dart`: untouched; JSON shape unchanged.
- Meshtastic (Path 1): untouched; it has its own channel-key model.
- Per-node keys, key rotation protocols, and over-the-air provisioning:
  not in v2. One deployment key, set by hand once, is the design point
  for a handful of nodes per gateway.

## Tests

`field_kit/esp32/tests/` holds three layers, and they prove different
things — read this before trusting any of them:

- **Frozen vectors** (`lora_psk_vectors.json`, generated by
  `make_vectors.py`): the shared ground truth. The reference
  implementation that generates them (`aes_ccm.py`) is anchored to
  published known answers — the FIPS-197 AES KAT and RFC 3610 CCM
  vector #1, both checked in the suite. The test PSK in the vectors
  file is a published test value, **not** a deployment key.
- **Python suite** (`test_lora_psk.py`): runs the vectors through a
  host MODEL of the gateway pipeline (`gateway_model.py`) — round
  trip, gate-before-decrypt, wrong-PSK/tamper rejection, replay
  rejection, freshness storage decoupled from the display table
  (table-full and v1-stuffing cases), freshness persistence across a
  modeled gateway reboot, fail-closed no-state drops, legacy
  acceptance and counter accuracy, byte-identical gateway JSON for
  v1 vs v2. It proves the protocol logic and the gateway behavior
  model. It does NOT prove the C++ codec or the sketches: the model
  is a mirror, maintained by hand, and mirrors can drift.
- **Host C++ test** (`run_cpp_tests.sh` → `test_lora_psk_cpp.cpp`):
  closes the drift hole for the codec itself. It compiles the REAL
  shared header (`shepherd_lora_psk/src/lora_psk_codec.h` — the exact
  code both sketches ship) and asserts `wrap()` reproduces the frozen
  wire bytes exactly, and `unwrap()`/`rebuildV1()` accept and reject
  correctly (wrong PSK; single-bit tampering at the schema, nonce,
  ciphertext, and tag offsets). The header's mbedTLS calls are served
  by a small test double (`tests/stub/`) because the build host has
  no mbedTLS headers to link; the double is itself anchored to
  RFC 3610 vector #1 inside the test, and any error in it fails the
  frozen-vector checks loudly. What this layer does NOT prove: the
  ESP32's own mbedTLS / hardware-AES path (a vendor library, covered
  by its own validation) and anything about the radio link.
- **Sketch builds:** both sketches are compile+link checked against
  the ESP32 Arduino core 2.0.17. That proves the firmware builds; RF
  behavior on real hardware remains a field test, as with the rest of
  Path 2.
