# LoRa Key Refresh Spec — ML-KEM-512 refresh + gateway-pushed rotation for codec v2

Status: **PROTOTYPE**, implemented 2026-10-23 in
`field_kit/esp32/shepherd_lora_keyrefresh/` (shared library),
`field_kit/esp32/lora_node/lora_node.ino`,
`field_kit/esp32/lora_gateway/lora_gateway.ino`. Revised the same
day after two independent reviews (fixes F1–F15: freshness lockout
after commit, fleet rounds, lost-ACK handling, authenticated
abort, identity-bound commit contexts, rotate-reply gating, and
hardening — each section below states the revised behavior).
Host-tested (ACVP known answers + protocol suites,
`field_kit/esp32/tests/`); **on-device behavior is UNVERIFIED
until bench/field hardware runs it.** Companion specs:
`docs/lora_psk_codec_spec.md` (the codec this refreshes keys for)
and `docs/lora_nodes_spec.md` (Path 2 overview).

## 1. Why this exists

Codec v2 (PSK) ships with one per-deployment key, set by hand, with
**no rotation story**: the codec spec's "Out of scope" said so
explicitly. A key that can never change is a key whose compromise
(or suspected compromise) means re-visiting every node by hand, and
whose confidentiality has no post-quantum hedge. This spec adds the
missing operational layer, in two mechanisms that share one
stage → confirm → commit state machine:

- **Mechanism A — ML-KEM-512 per-link key refresh.** A fresh PSK is
  *derived* from a post-quantum KEM exchange (FIPS 203 ML-KEM-512),
  authenticated by the current PSK. Research basis: Azevedo,
  Lagrota & Ribeiro, *Multicore Implementation of ML-KEM on Embedded
  Devices*, SBSeg 2025 (read in full by the research sweep,
  `lane5_encryption.md`, 2026-10-23 update): measured ML-KEM-512
  keygen 5.1 ms / encaps 6.4 ms / decaps 8.1 ms on a dual-core
  ESP32 — a full handshake is ~20 ms of compute, trivially
  affordable for a rare re-key. Their code is **not** used (it has
  no side-channel masking and no reuse license); the implementation
  here is an established portable one (§10).
- **Mechanism B — gateway-pushed PSK rotation.** The gateway wraps a
  new PSK in the *existing* codec wrap (AES-128-CCM under the
  current PSK) and delivers it. This is the gateway-initiated key
  transport sketched as actionable analysis in the same sweep
  update (from the Sanchez-Iborra et al. EDHOC read): rotation
  without new public-key machinery, for operators who want a
  specific key (generated on a PC, or by the gateway's CSPRNG).

Either mechanism, run per node, moves that node + the gateway to a
new committed key at a new `key_counter`. The fleet procedure is
the Mechanism B **round** (§11): one key staged and committed node
by node while the gateway holds its window open, with the gateway
promoting last, on the operator's explicit command. The fleet key
remains a *single per-deployment key* in the codec's model.

## 2. Transport — Wi-Fi, never LoRa (verified constraint)

`lora_node.ino` has **no LoRa receive path**: nodes are TX-only on
LoRa (beacons/events); the gateway is RX-only on LoRa. There is
therefore no channel on which LoRa could carry a handshake to a
node, and this spec does not invent one:

- **All refresh/rotation traffic runs over the devices' Wi-Fi
  link.** The node serves new endpoints on its *existing* WebServer
  (its AP, `Shepherd-SLN-XXXX`, 192.168.4.1). The gateway initiates
  as a Wi-Fi **client**: for the duration of a session it runs
  APSTA — it keeps its own AP up on a temporary subnet
  (192.168.6.1, so its status page stays reachable) and joins the
  target node's AP as a station (STA interface, 192.168.4.x). The
  two /24s differ precisely so that "192.168.4.1" unambiguously
  means the *node* from the gateway's STA side while the gateway's
  own AP is 192.168.6.1 for the session. On session end (commit,
  abort, or timeout) the gateway restores its AP to 192.168.4.1.
  **Session-start ordering (F9):** the gateway's `/krstart`
  handler sends its HTTP response *before* any AP
  reconfiguration; the APSTA switch happens on the next session
  pump tick. (Previously the AP moved first and the response
  raced the reconfiguration it was announcing.) A consequence
  every operator must know: **clients already associated with the
  gateway AP — including the Shepherd PC — must re-associate and
  DHCP-renew onto 192.168.6.x mid-session** to keep following the
  status page; the page returns to 192.168.4.1 when the session
  ends.
- The Shepherd app's UDP feed pauses its gateway path during a
  session (the gateway AP moved). **Session steps block the
  gateway's `loop()` (F11, honest disclosure):** each step is a
  synchronous HTTP exchange — two sequential posts for Mechanism
  A, with 8 s client timeouts, so a step can stall the loop for
  ~16 s worst case — and **LoRa frames arriving during a stall
  can be missed** (the receiver is not serviced while blocked).
  The link is Aloha-lossy by design: no ACKs, no retries, and the
  next 30 s beacon recovers node state, which is what makes a
  stall tolerable for a maintenance action. It is not free, and
  splitting the exchanges into non-blocking chunks is future work
  (§13). Refresh is a **maintenance action**, run with the node in
  Wi-Fi range of the gateway, not a background process.
- The ML-KEM messages (800 B public key, 768 B ciphertext) are
  ordinary HTTP request/response bodies on the node's WebServer —
  no LoRa fragmentation is needed or attempted (the same sweep
  noted ~1.6 kB of KEM material would need ~48 LoRa frames; that
  path is rejected here by design).

## 3. Roles and identities

- **Node** (`SLN-XXXX`): responder. Generates ephemeral KEM keys
  (Mechanism A), stages candidates, commits on authenticated
  command. Never initiates.
- **Gateway** (`SLG-XXXX`): initiator for both mechanisms.
  Encapsulates (A) or chooses/wraps the new key (B), opens the
  dual-key acceptance window, issues commit/abort.
- **Identity field** (8 bytes, used in the transcript): the device
  ID as ASCII, exactly 8 characters — `SLN-XXXX` / `SLG-XXXX`
  with the device's 4-hex suffix, as already shown on the status
  pages and the map.
- **Current PSK**: the committed codec v2 key on both devices. In
  this protocol it is the **authenticator**: it keys every HMAC
  that authorizes a refresh. A peer that does not hold it cannot
  cause a key change, full stop (§12).

## 4. Mechanism A — wire format

Three HTTP exchanges, gateway → node, binary bodies
(`application/octet-stream`). All integers big-endian.

### 4.1 `POST /kr/begin` — open a refresh, get the ephemeral public key

Request body (12 bytes):

| Bytes | Field |
|---|---|
| 0–7 | gateway identity (8 B ASCII) |
| 8–11 | target `key_counter` (u32 BE) — MUST be greater than the node's committed counter (§8 counter rule) |

Response `200` body (812 bytes):

| Bytes | Field |
|---|---|
| 0–7 | node identity (8 B ASCII) |
| 8–11 | echoed `key_counter` (u32 BE) |
| 12–811 | ML-KEM-512 encapsulation key `ek` (800 B) |

The node generates a **fresh ephemeral ML-KEM-512 keypair** for
this refresh and keeps the decapsulation key in RAM only. Errors:
`409` with a 1-byte result code (§9) — counter mismatch, busy
(another context staged), or crypto failure; nothing is staged.

### 4.2 `POST /kr/encap` — deliver ciphertext + transcript authentication

Request body (800 bytes):

| Bytes | Field |
|---|---|
| 0–767 | ML-KEM-512 ciphertext `ct` (768 B) |
| 768–799 | transcript authentication `auth` (32 B) |

`auth = HMAC-SHA256(current PSK, transcript)` where the
**transcript** is the exact concatenation:

```
transcript = "SHKR1"            (5 B, ASCII domain separator)
           || gateway identity  (8 B)
           || node identity     (8 B)
           || key_counter       (4 B, u32 BE)
           || ek                (800 B)
           || ct                (768 B)
                                            total 1593 B
```

The node rebuilds the transcript from *its own* stored `ek`, the
identity it recorded at `/kr/begin`, its staged counter, and the
received `ct`. Any substitution — a different public key, a
different ciphertext, a different counter, a different identity —
changes the transcript and fails the HMAC. The comparison is
constant-time. On failure the node **aborts the staged context**,
increments its auth-refusal counter, and replies `403` + code.

On success the node decapsulates, derives the candidate (§5),
**stages** it (§7), and replies `200` with the **confirm proof**
(32 B):

```
confirm = HMAC-SHA256(new key, "SHKR1-CONFIRM" || SHA-256(transcript))
```

The gateway verifies `confirm` against its own derived candidate.
Only a node that decapsulated the real shared secret and derived
the same key can produce it. A failed confirm aborts the session
on the gateway side (staged candidate discarded).

### 4.3 Commit / abort — shared with Mechanism B (§7)

`POST /kr/commit` body: the 32-byte commit proof (§7.3).
`POST /kr/abort` body: the 32-byte abort proof (§7.4) when a
staged context exists; empty only when there is nothing staged.
Both are defined once, below.

## 5. Key derivation (Mechanism A) — normative

```
th        = SHA-256(transcript)
salt      = th
info      = "shepherd-kr-v1" (14 B ASCII)
            || SHA-256(current PSK) (32 B)
            || key_counter (4 B, u32 BE)
new key   = HKDF-SHA256(ikm = ML-KEM shared secret (32 B),
                        salt, info, L = 16)
```

- The output is truncated to **16 bytes** — the AES-128 PSK size,
  identical to the existing key model; the codec is untouched.
- Binding: the transcript hash binds the key to this exact
  handshake (identities, counter, `ek`, `ct`); the PSK hash binds
  it to the authorizing key without using that key as key material;
  the counter binds it to this rotation epoch. Replaying an old
  handshake's messages derives a key for a counter the node will
  refuse (§8).
- **Key ID** of the new key follows the existing convention:
  first 2 bytes of SHA-256(new key), displayed as 4 hex chars,
  `----` when no key. The key itself is never displayed, logged,
  or transmitted (the shared secret is never transmitted at all;
  `ek`/`ct` are public KEM values by design).

## 6. Mechanism B — gateway-pushed rotation wire format

The gateway chooses the new 16-byte PSK — from its hardware CSPRNG
(`esp_fill_random`, Wi-Fi up, per Espressif's RNG contract) or
operator-supplied as 32 hex chars on the gateway status page — and
delivers it in **one** message:

### `POST /kr/rotate` — body: 42 bytes (gateway identity + a codec v2 wire packet)

The first 8 bytes are the **gateway identity** (`SLG-XXXX`, ASCII)
— bound into the commit context on both sides (§7.3, F6). The
remaining 34 bytes are exactly a `shepherd_psk::wrap()` packet
under the **current** PSK — the same shared codec code, the same
CCM parameters, **no duplicated crypto**. Its 21-byte CCM
plaintext is:

| Payload byte | Field |
|---|---|
| 0 | magic `0x4B` (`'K'`) |
| 1–4 | target `key_counter` (u32 BE) |
| 5–20 | new PSK (16 B) |

The wrap nonce is a fresh random 64-bit value (two u32 halves);
on this path the nonce fields carry no counter meaning — (key,
nonce) uniqueness is all CCM requires, and a fresh random nonce
per rotation provides it. The new key's ID is not transmitted:
both sides derive it from the key itself by the §5 convention.

The node unwraps with the current PSK. Tag failure ⇒ drop, count,
`403` (KR_ERR_AUTH) — wrong key and tampering are indistinguishable,
exactly as on the LoRa path. Magic or counter violations refuse
with their own codes (§9). On success the candidate is **staged**
on the node (state CONFIRMED directly: the CCM tag under the
current PSK *is* the stage authentication, there is no separate
confirm round) and the node replies `200` with the staged key ID
(2 bytes) + counter (4 B).

**The gateway's dual-key window does NOT open when the rotation
is sent (F7).** On the gateway the candidate sits in STAGED until
the gateway **verifies the `/kr/rotate` reply** — the staged key
ID and counter must match exactly what was pushed — and only then
does the gateway context become CONFIRMED and the window open
(§7.2). A mismatched reply **fails the session at the rotate
step**, aborting the gateway context, incrementing the failure
counters and a dedicated rotate-mismatch counter, both visible on
the gateway status page (§9). The shared commit/abort (§7.3)
then completes or unwinds the rotation.

## 7. The unified state machine

Both mechanisms converge on identical states on both devices:

```
IDLE --stage--> STAGED --confirm--> CONFIRMED --commit--> IDLE (new key committed)
  ^                |                     |
  +--- abort / timeout (any pre-commit state) ------------+
```

### 7.1 STAGE

The candidate key is stored **separately** from the committed key
(RAM only, §8). Transmission and reception continue under the
committed key, byte-for-byte as before. Mechanism A reaches STAGED
on the node at `/kr/begin` and on the gateway at encapsulation;
it reaches CONFIRMED on both sides after the confirm proof
verifies. Mechanism B reaches CONFIRMED **on the node** in one
step (the wrap tag is the stage authentication); **on the gateway
it reaches STAGED when the rotation is made and CONFIRMED only
when the node's reply verifies (F7, §6)**. In a round (§11) the
gateway's context is CONFIRMED with the round key for the round's
whole duration, and each node's own state machine runs exactly
as in a single rotation session.

### 7.2 CONFIRM and the dual-key acceptance window

When the gateway's context is CONFIRMED, its LoRa unwrap path
becomes **dual-key**: for each v2 frame it tries the **committed**
key first, then the **staged** key. (The codec wire format has no
key-ID field, so acceptance is necessarily ordered try-both; the
first key whose CCM tag verifies wins. A frame that verifies under
the staged key increments a visible `dual-key frames` counter.)
The node has no LoRa receive path and no window: it keeps
*transmitting* under the committed key until commit. The window
exists so that the instant the node commits (and starts sending
under the new key), the gateway already accepts those frames —
and, symmetrically, frames sent just before commit under the old
key still decode. **Outside CONFIRMED, the gateway is exactly the
old single-key gateway.** For Mechanism B the gateway reaches
CONFIRMED only via the verified `/kr/rotate` reply (§6, F7) —
never merely by sending the rotation. During a fleet **round**
(§11) the window stays open for the whole round.

Outside a round, a first valid v2 frame under the staged key is
also a promotion trigger (§7.3), equivalent to the explicit
commit ACK — subject to the freshness ordering of §8 (F1): the
frame must first pass the freshness check under the rebased
state, and a replay-classified frame never promotes. **During a
round, this auto-promotion is disabled**; staged-key frames only
mark their node COMMITTED in the round table.

### 7.3 COMMIT

The gateway sends `POST /kr/commit` with:

```
commit_ctx = SHA-256(transcript)                                   (Mechanism A)
           | SHA-256("SHKR1-ROT" || gwId || nodeId || ctr BE)      (Mechanism B)
commit     = HMAC-SHA256(staged key, "SHKR1-COMMIT" || commit_ctx)
```

The Mechanism B context **binds both identities** (F6): a commit
proof made for one node cannot be replayed to another node, even
at the same counter with the same fleet key. (Mechanism A's
transcript hash already binds both identities, §4.2.)

Only a peer holding the staged candidate can produce this. The
node verifies it (constant-time), then **commits**: the staged key
replaces the committed key, `key_counter` becomes the target,
**both are persisted to NVS (§8) — together with a persistent
`boot_ctr` bump (F1, §8)**, ephemeral material is scrubbed, and
the node replies `200`. Its next LoRa transmission uses the new
key with the bumped boot counter and a restarted frame counter.
**If the node's commit persist fails its read-back verification,
the node keeps running the OLD key and replies NON-200 (§9, F3)**
— it never acknowledges a commit it did not durably take. The
gateway promotes its staged key to committed (and persists)
when the node's `200` arrives, or when the first v2 frame
verifies under the staged key and passes the §8 freshness
ordering — whichever comes first — and closes the window.

**Lost commit ACK (F4).** If the gateway's `/kr/commit` POST
fails or times out, delivery is ambiguous: the node may have
committed and its `200` been lost. The gateway therefore does
**not** abort the context. It keeps the context CONFIRMED with
the window open, marks the session **"awaiting frame
confirmation"** (visible on the status page, counted), and the
frame trigger above can still promote. Only an operator abort or
the 120 s window expiry tears the session down. The same rule
applies per node inside a round: a lost ACK marks that node
AWAITING-FRAME, and a staged-key frame from it flips the entry
to COMMITTED.

A commit proof that fails verification is refused and counted;
the staged context **survives** a bad commit attempt (an attacker
who does not hold the candidate cannot force an abort with junk,
and a retried honest commit can still land before timeout).

### 7.4 Timeout / abort / revert

- The staged context on **each** device expires **120 s** after
  staging (configurable only in code, `KR_STAGE_TIMEOUT_MS`).
  Expiry == abort: staged material scrubbed, state IDLE, committed
  key and counter **untouched**. **Exception (F2): a gateway
  ROUND context does not auto-expire** — a round is
  operator-paced (a fleet takes as long as it takes) and ends
  only on Promote, Abort, or reboot (a reboot is a safe abort:
  the staged round key was never persisted). Node-side staged
  contexts inside a round still expire at 120 s, which is
  harmless because round sessions commit each node immediately
  after staging it.
- `POST /kr/abort` (or the gateway status page's Abort control)
  unwinds both sides the same way. **The abort is authenticated
  (F5):** when the node holds a staged context, the request must
  carry a 32-byte abort proof in the same style as the commit
  proof — `HMAC-SHA256(staged key, "SHKR1-ABORT" || commit_ctx)`
  for a CONFIRMED context, or, for a STAGED Mechanism A context
  (no candidate exists yet), an HMAC under the **current PSK**
  over `SHA-256("SHKR1-ABORT-CTX" || target counter BE)`. A bad
  or missing proof is refused and counted and the staged context
  **survives** (same rule as a bad commit proof). With **no**
  staged context, `/kr/abort` is a **no-op success** — there is
  nothing to protect, and a gateway whose own context is already
  gone can always clean up. Inside a round, each node's abort
  proof uses that node's identity-bound context (F6).
- The committed key is **never deleted before commit**, on either
  device, by any path in this spec. A node that is unreachable
  mid-rotation simply stays on the old key; a gateway that loses
  the session keeps the old key; when the operator retries, the
  target counter is still committed+1 and the retry is a fresh,
  ordinary session. **A failed or partial rotation cannot brick a
  node** and cannot strand the fleet on mismatched keys beyond the
  window the dual-key acceptance covers.

## 8. `key_counter` and NVS persistence — normative

- `key_counter` is a u32, **monotonic**, persisted in NVS on both
  devices (node namespace `sln`, gateway `slg`, key `kr_ctr`). It
  counts *committed* refreshes/rotations. A device whose PSK was
  provisioned by hand (the original codec flow) starts at
  `kr_ctr = 0`.
- **Counter rule (revised, F2): a stage is accepted iff
  `target > committed`, at every entry point, for both
  mechanisms; commit sets `committed := target`.** Any target
  `<= committed` is refused as a rollback/replay (KR_ERR_COUNTER,
  counted). Gaps are accepted deliberately: every stage payload
  is authenticated under the current shared key (transcript HMAC
  or CCM tag), so a skipped counter is just an unused number —
  it cannot be replayed later (it is `<= committed` by then) and
  rollback remains impossible. The rule exists so a node that
  lagged a round can join a later one without counter surgery.
  Sessions the gateway initiates still use `committed + 1` in
  the normal case.
- **Counter wrap:** `key_counter` is a u32. At
  `committed == 0xFFFFFFFF` every possible target is
  `<= committed`, so all staging refuses — refresh is
  (astronomically) exhausted and recovery is manual
  re-provisioning (below). No wrap-around is permitted or
  attempted; at one refresh per day the counter outlasts the
  hardware by ~10⁷ years, so this is a stated bound, not a plan.
- **Freshness and the commit boot bump (F1).** The codec's
  freshness state is the per-suffix `(boot_ctr, frame_ctr)`
  high-water at the gateway. A node commit therefore **bumps
  `boot_ctr` persistently** (NVS `boot_ctr`, written and
  read-back-verified together with the key and counter) and
  restarts `frame_ctr` at 0: post-commit frames arrive as
  `(boot+1, 0..)`, strictly newer than any pre-commit high-water.
  (Without the bump — the original defect — every post-commit
  frame looked like a replay until `frame_ctr` re-climbed past
  its pre-commit value: hours of silent outage at beacon
  cadence.) At promotion (either trigger) the gateway **rebases**
  that suffix's freshness entry: it is seeded by the promoting
  frame itself (frame trigger) or kept and marked *rebased*
  (commit-ACK trigger). For a **rebased** suffix, the codec's
  legacy "lower boot counter = reflash resync" acceptance is
  **disabled**: a lower boot counter is captured pre-commit
  traffic and is dropped as a replay. Promotion happens **only
  after** the promoting frame passes this freshness ordering —
  a replay-classified frame never triggers a persist (§7.3).
- **Committed state is the only state persisted**: (`psk_hex`,
  `kr_ctr`, and at node commit the bumped `boot_ctr`) are written
  together, at commit/promote, and read at boot. **Staged state
  is never written to NVS.** Therefore a reboot anywhere before
  commit restores exactly the old key and old counter — the
  staged candidate does not, and cannot, promote itself across
  a reboot.
- **Divergence recovery (stated exactly).** A node and the
  gateway diverge when one has committed a key/counter the other
  has not (e.g. a reboot *after* the node's commit but before
  the gateway's promote, a lost ACK followed by window expiry).
  Recovery, by case:
  - **Lagging node (its committed counter is behind the round's,
    but it still holds the fleet key the gateway still has
    committed):** while a round is open — i.e. **pre-promotion**,
    when the gateway's committed key is still the key the node
    holds — the node **joins the later round** by the ordinary
    per-node round session (§11) and commits into it. This works
    precisely because promotion has not happened yet; the round
    payload unwraps under the shared committed key.
  - **A node that missed a completed round entirely** (the
    gateway promoted without it), or any node whose committed
    key no longer equals the gateway's committed key for any
    reason: it can no longer unwrap rotation payloads, and it is
    recovered by the **existing manual `/psk` provisioning
    flow** — set the gateway's current fleet key on the node's
    status page (and on the gateway's, if the gateway is the one
    that diverged), reboot it, confirm the key IDs and counters
    on both status pages, and include it in the next round or
    session normally. There is no protocol shortcut for a node
    that cannot authenticate under the current key, and this
    spec does not invent one (§13).
- Manual PSK set/clear on the status pages (pre-existing behavior)
  does not change `kr_ctr`; an operator who hand-changes the key
  should expect the next refresh to target `kr_ctr + 1` as usual.

## 9. Failure modes — every one fails closed

| Failure | Detection | Result | Code |
|---|---|---|---|
| Counter `<=` committed | stage-time check (§8 rule: accept iff `target > committed`) | refused + counted, nothing staged | `KR_ERR_COUNTER` (1) |
| Wrong-PSK transcript HMAC (A) | constant-time compare | node aborts context, counted | `KR_ERR_AUTH` (2) |
| Tampered `ek` (A) | transcript rebuild differs → HMAC fails | as above | `KR_ERR_AUTH` |
| Tampered `ct` (A) | HMAC fails (and decap would yield garbage ss) | as above | `KR_ERR_AUTH` |
| Tampered rotation payload (B) | CCM tag | refused + counted, nothing staged | `KR_ERR_AUTH` |
| Rotation magic wrong (B) | payload byte 0 after valid unwrap | refused + counted | `KR_ERR_FORMAT` (4) |
| Confirm proof wrong (A) | gateway compare | gateway aborts session | `KR_ERR_AUTH` |
| Rotate reply mismatch (B) | gateway compares the `/kr/rotate` reply (staged key ID + counter) against what it pushed (F7) | session fails **at the rotate step**; gateway context aborted; failure + dedicated mismatch counters incremented (page-visible) | `KR_ERR_AUTH` |
| Commit proof wrong | node compare | refused + counted; context kept until timeout (retry can land) | `KR_ERR_AUTH` |
| Abort proof wrong or missing | node compare (F5) | refused + counted; context kept until timeout | `KR_ERR_AUTH` |
| Commit ACK lost (gateway side) | `/kr/commit` POST fails/times out after possible delivery (F4) | **NOT a teardown:** gateway stays CONFIRMED, window open, session marked "awaiting frame confirmation" (counted, page-visible); frame trigger can still promote; operator abort or window expiry ends it | — (held) |
| Message in wrong state | state check | refused + counted | `KR_ERR_STATE` (3) |
| Any `/kr/*` call with no PSK set | uniform guard, both sketches (F8) | `403` before any state is touched | `KR_ERR_STATE` (3) |
| Stage timeout (120 s) | expiry check in loop | both sides revert to committed key | — (abort) |
| Node unreachable mid-session | gateway HTTP timeout | gateway aborts its side; node context expires on its own clock | — (abort) |
| Primitive failure (KEM/HKDF/CCM) | return codes | refused, nothing staged | `KR_ERR_CRYPTO` (5) |
| NVS write fault at NODE commit | read-back verify of (`psk_hex`, `kr_ctr`, bumped `boot_ctr`) at commit (F3) | node keeps running the **OLD key in RAM**, attempts a best-effort restore of the previous persisted values, flags the fault loudly on its status page + Serial, and replies **NON-200** — the gateway therefore does not promote and stays in-window (F4); the operator fixes the flash fault and re-runs the session | — (flagged) |
| NVS write fault at GATEWAY promote | read-back verify of (`psk_hex`, `kr_ctr`) at promote (F3) | gateway **adopts the new key in RAM** (the fleet already moved; staying behind would blackhole it), flags the fault loudly on the status page with a dedicated counter + Serial: a reboot would revert this gateway to the OLD persisted key, after which §8 recovery applies; fix the flash fault and re-run/repair | — (flagged) |

No failure path in this table deletes the committed key, stages
an unauthenticated candidate, or falls back to plaintext.
**No v1-plaintext fallback is introduced anywhere**: a device with
no PSK keeps exactly the codec spec's pre-existing loud-plaintext
behavior, and refresh endpoints refuse to run without a committed
PSK (there is no authenticator to authenticate with).

Status surfaces (both devices, in the existing "LoRa security"
card idiom): current key ID, staged key ID (or `----`), committed
`key_counter`, refresh state (`IDLE`/`STAGED`/`CONFIRMED`),
per-code refusal counters, failure counter, completed refresh /
rotation counts, and (gateway) dual-key frame count. The gateway
page additionally shows a **KR session-failure counter and the
last failure's reason string** (failures were Serial-only before
F10), the rotate-reply mismatch count, the lost-ACK count, an
"awaiting frame confirmation" marker when F4 applies, the
promote-persist fault flag/counter when F3 applies, and — during
a round — the round target counter, round key ID, and the
**per-node round status table** (STAGED / COMMITTED /
AWAITING-FRAME / FAILED). The node's page shows its last KR
failure reason the same way. Keys are never displayed; the
node's AP password rules from the codec spec apply unchanged to
these endpoints (they sit behind the same AP).

## 10. Implementation

- **ML-KEM-512**: PQClean `crypto_kem/ml-kem-512/clean` (portable
  C), vendored unmodified into
  `esp32/shepherd_lora_keyrefresh/src/mlkem/` at upstream commit
  `0586a824fc0d49df0b6b6e9179d8d15d06d0974f`. License: public
  domain / CC0 (`src/mlkem/LICENSE` preserved in-tree; provenance
  and the mlkem-native comparison in the library's `VENDOR.md`).
  The only Shepherd-authored files in that folder are the RNG
  shim: `randombytes.h` + `kr_randombytes.c` (`esp_fill_random`
  on device — Wi-Fi is up, satisfying Espressif's HWRNG entropy
  precondition — `/dev/urandom` on host). PQClean's own
  `randombytes.c` is not vendored.
- **SHA-256 / HMAC / HKDF**: mbedTLS from the ESP32 Arduino core
  (`mbedtls/md.h`) — the same library the codec already uses for
  CCM. One build-system fact, recorded honestly: core 2.0.17
  builds its mbedTLS **without** `MBEDTLS_HKDF_C` (no
  `mbedtls_hkdf` symbol in the prebuilt `libmbedcrypto`), so the
  library composes HKDF-SHA256 from the core's HMAC per RFC 5869
  (extract + expand, ~20 lines, anchored to RFC 5869 case 1 in
  both host suites). The identical code path runs on device and
  in tests. ML-KEM's internal SHA3/SHAKE comes from the vendored
  implementation (FIPS 202 code in-tree).
- **Mechanism B wrap**: `shepherd_psk::wrap/unwrap`, untouched,
  from the codec library. **The codec library is byte-stable**:
  this work changes neither its header nor its vectors, and its
  suites pass unchanged (§14).
- **Protocol/state machine**: `src/keyrefresh.h`, header-only,
  pure byte-buffer logic (no Wi-Fi/NVS/Arduino types), shared by
  both sketches and the host tests — the same "one implementation,
  no drift" pattern as the codec. The round state (open/abort
  rules), the rotate-reply verification, the abort proofs, the
  lost-ACK marker, and the identity-bound rotation contexts all
  live in this header; the sketches own transport, the per-node
  round table, freshness storage, and persistence.

## 11. Migration and operations order

1. Flash the **gateway** first (same rule as codec v2): it gains
   the dual-key window and the refresh controls; with no session
   running it behaves byte-identically to the current gateway.
2. Flash nodes. A flashed node with no session running behaves
   byte-identically to the current node.
3. Ensure every device holds the current PSK (existing flow) and
   read each status page: committed counter should read `0`
   everywhere before the first refresh.
4. Per node, from the gateway's status page: enter the node
   suffix + its AP password, choose **Start refresh** (Mechanism
   A) or **Push rotation** (Mechanism B; gateway-CSPRNG key or a
   pasted 32-hex key), watch the state reach CONFIRMED, then
   **Commit**. Verify the node's page afterwards: key ID changed,
   counter incremented, LoRa beacons decoding at the gateway.
5. **Fleet convergence: Mechanism B rounds (the supported fleet
   pattern, F2).** The gateway holds ONE committed key (the
   codec's fleet-key model). To move the whole fleet to a new
   key, the operator runs a **round**:
   1. **Open the round** on the gateway status page (Mechanism B
      only). The round's target counter is `C = gateway
      committed + 1` and there is **ONE round key** for the whole
      round (gateway CSPRNG, or a pasted 32-hex key). Opening the
      round opens the gateway's dual-key window with the round
      key staged; the gateway's *committed* key does not change.
   2. **Per node**, run the ordinary gateway session (node suffix
      + AP password, **Push rotation**). While a round is open
      the session *joins the round*: it stages the round key on
      that node at counter `C` (F7 reply verification applies)
      and **commits that node immediately — without promoting
      the gateway**. The gateway's status page tracks each node's
      round status (STAGED / COMMITTED / AWAITING-FRAME /
      FAILED). Already-committed nodes (new key) and
      not-yet-visited nodes (old key) **both keep decoding**
      through the dual-key window for the whole round; the
      frame-triggered auto-promotion is **disabled** during a
      round, so the first node's commit can no longer wedge the
      rest (the original defect this design replaces).
   3. **Promote** (explicit operator action): the gateway sets
      `committed := round key, key_counter := C`, closes the
      window, and scrubs the round state. Every committed node
      and the gateway are now on the same key at the same
      counter.
   4. **Abort** (explicit operator action), with the chosen,
      safer semantics: **a round may be aborted only before any
      node has committed into it.** Aborting scrubs the gateway's
      round state immediately (window closes, round key wiped);
      nodes that staged but did not commit hold a RAM-only
      candidate that can never be committed afterwards (the
      gateway no longer stages its key, so no valid commit proof
      can be produced) and that expires within 120 s on the
      node's own clock — nothing on those nodes was ever
      committed, so the fleet simply stays on the old key.
      **Once any node has committed, abort is refused**: only
      Promote, or per-node recovery (§8), remains — an abort then
      would strand the committed nodes on a key the gateway no
      longer holds.
   A node the operator skips stays on the old key and goes dark
   at the gateway once the gateway promotes — the same visible,
   diagnosable state as a PSK mismatch in the codec spec; its
   recovery is §8 (manual `/psk` provisioning, since it missed
   the completed round). A lagging node that still holds the
   current fleet key can instead join a *later* round
   pre-promotion (§8).
   **Sessions and rounds are mutually exclusive:** the gateway
   runs one Wi-Fi session at a time (the existing single session
   machine); while a round is open, sessions join the round and
   Mechanism A is unavailable.
   **Mechanism A is per-link by construction**: two refreshes
   derive two different keys. It is a **per-link prototype** —
   the right tool for a gateway↔single-node link or a bench
   pair (§13) — never a fleet procedure. The fleet procedure is
   Mechanism B rounds, above. A per-node key table on the
   gateway (which would make Mechanism A fleet-wide) is future
   work, stated in §13 — not silently implied here.

## 12. Security analysis

- **Authentication, endpoint by endpoint** (corrected to match
  the implementation exactly — an earlier draft implied the
  abort was unauthenticated while claiming blanket coverage):
  - `POST /kr/begin` (node): no body authentication of its own —
    it only *starts* a context and returns a fresh ephemeral
    public key; nothing is staged that can be committed from it
    alone. It refuses when no PSK is set (uniform guard, below)
    or another context is staged. Abuse ceiling: DoS by holding
    the single context slot (the gateway sees the failure).
  - `POST /kr/encap` (node): the transcript HMAC under the
    **current PSK** (§4.2) — a peer without the PSK cannot get a
    candidate staged.
  - `POST /kr/rotate` (node): AES-128-CCM tag under the
    **current PSK** (the codec wrap) — same statement.
  - `POST /kr/commit` (node): HMAC under the **candidate** key
    over the identity-bound context (§7.3) — proof of shared
    derivation / possession.
  - `POST /kr/abort` (node): HMAC abort proof (§7.4) — under the
    **candidate** key for a CONFIRMED context, under the
    **current PSK** for a STAGED Mechanism A context; a no-op
    success when nothing is staged.
  - The gateway's operator endpoints (`/krstart`, `/krcommit`,
    `/krabort`, `/krroundstart`, `/krroundpromote`,
    `/krroundabort`) are not protocol messages: they sit behind
    the gateway's own AP, like every other status-page control
    since codec v1 (the AP-password caveat below applies).
  - **Uniform guard (F8):** every `/kr/*` endpoint in both
    sketches refuses with `403` when no PSK is set, before any
    state is touched — there is no authenticator to authenticate
    with.
  An attacker without the current PSK can at most trigger
  refusals (counted, visible) — the classic DoS-only residue of
  any authenticated protocol on an open AP.
- **Ephemeral-key RAM exposure window (F14)**: the node's
  ephemeral ML-KEM decapsulation key exists **only in RAM**, from
  `/kr/begin` until the context ends (encap, abort, or the 120 s
  timeout) — a worst-case exposure window of **≤ 120 s** per
  refresh, on a physically capturable device that already holds
  the fleet PSK in flash; the refresh does not worsen the capture
  story below. The key is scrubbed on every context exit, as are
  the shared-secret and HKDF temporaries in the library on both
  success and failure paths.
- **Forward / post-quantum properties**: Mechanism A's candidate
  is derived from an ML-KEM shared secret; a future quantum
  adversary who recorded the Wi-Fi exchange and *later* obtains
  the PSK still cannot recover the shared secret from `ek`/`ct`
  (that is the KEM's job), so rotated keys gain a harvest-now
  hedge the static PSK never had. Mechanism B's candidate travels
  *under* the current key: it inherits exactly the current key's
  confidentiality — no better, no worse.
- **Rollback**: the persisted monotonic counter refuses replays
  of old sessions and old rotation payloads, including honestly
  wrapped ones (§9, tested).
- **No downgrade**: there is no message that clears a key, lowers
  a counter, or negotiates plaintext. The pre-existing manual
  Clear-PSK (key-ID-confirmed) remains the only way back to v1,
  and it is an operator action, not a protocol outcome.
- **Side channels, stated honestly**: PQClean's portable C is not
  constant-time-hardened to the standard of a masked
  implementation, and the nodes are physically capturable field
  devices holding the fleet key in flash regardless — the
  deployment's capture story (revoke by re-keying the fleet,
  per the EG-2002 analysis in the research lane) is unchanged by
  this spec. Power-analysis resistance of the KEM on ESP32 is
  **not claimed**. Azevedo et al.'s implementation was excluded
  for exactly this reason combined with its license; choosing
  PQClean trades their multicore speed for auditability, it does
  not magically add masking.
- **The Wi-Fi provisioning caveat carries over**: refresh runs
  over the node's AP, whose password may still be the public
  default. The protocol's HMACs mean a passive observer of a
  refresh learns no key material (A) or only CCM ciphertext (B),
  but the codec spec's standing advice stands: change the AP
  password before relying on any of this, and refresh in a
  controlled RF environment.

## 13. Honest limits

- **Prototype.** Host-verified logic; zero on-device runs so far.
  Wi-Fi APSTA behavior, HTTP body handling at 812 B, ML-KEM stack
  usage on the real core, and NVS interplay are all UNVERIFIED
  until hardware says otherwise.
- **One gateway context.** The gateway stages one session at a
  time, holds one committed fleet key, and its dual-key window
  covers exactly one staged candidate. Multi-node fleets converge
  by the Mechanism B **round** of §11 — sequential per-node
  sessions under operator control, not orchestration.
  **Mechanism A is a per-link prototype** (a gateway↔single-node
  link, a bench pair); fleet-wide Mechanism A would need a
  per-node key table on the gateway, which is future work.
- **Gateway-committed / node-committed divergence** after a
  precisely-timed reboot (§8) needs the manual `/psk` fallback
  stated in §8. The window and counters make it *visible*; they
  do not make it impossible.
- **Session steps block the gateway loop** (§2, F11): LoRa
  frames arriving during a session step's HTTP exchange can be
  missed. The link's Aloha-lossy design bounds the damage; it
  does not eliminate it. Non-blocking (chunked) session steps
  are future work.
- **`LORA_GW_STA` build variant (F12):** KR session initiation
  is **compile-time disabled** in that variant (the status page
  says so, and `/krstart` + the round endpoints refuse), because
  the variant hosts no gateway AP for the APSTA session dance —
  without the disable, the session path would try to raise a
  softAP with an empty SSID. Flash the AP variant to refresh
  keys.
- **Bench checklist addition (F13):** before any field reliance,
  measure the **stack high-water mark** of the gateway and node
  loop tasks (e.g. `uxTaskGetStackHighWaterMark`) *during a live
  session, including a status-page render mid-session* — the
  status handlers are the fattest stack consumers in both
  sketches (gateway `handleRoot` peak locals were reduced from
  7,744 B to a single 6,144 B buffer by F13; the node handler
  uses a single 4,600 B buffer), and host compilation proves
  nothing about on-device stack headroom.
- **Traffic analysis**: as the research sweep noted (rotating
  identifiers do not anonymize an emitter), rotating the PSK does
  not unlink the node's RF fingerprint. This spec protects key
  freshness and content, not emitter identity.
- **Sizes/timing**: KEM compute is ~20 ms per handshake per the
  SBSeg measurements on this chip class; the 812 B begin-response
  is the largest object this protocol moves. No LoRa airtime is
  consumed by either mechanism, ever.
- **EDHOC / DTLS / WireGuard were not adopted** for this link, for
  the reasons the sweep recorded (message size, stack weight,
  termination point); this spec is intentionally the smallest
  authenticated rotation that fits the existing codec and pages.

## 14. What this does NOT encrypt

Draco's standing interop rule: **encryption lives inside the fleet
only.** This spec changes key management for the LoRa backhaul
codec and *nothing else*. The following surfaces are deliberately
**untouched, open-standard, and unencrypted by this work**, so
that other systems can keep connecting to Shepherd exactly as
they do today:

- **Gateway UDP 49160 JSON** — the gateway's re-emitted
  beacons/events remain **byte-identical** to before (the refresh
  code never touches JSON construction; dual-key selection happens
  inside unwrap, before the unchanged decode path, exactly like
  today's single-key unwrap).
- **CoT multicast 239.2.3.1:6969** — Shepherd↔Predator / TAK
  interop traffic: unchanged.
- **ZMeta adapter / ingest and invite-code pairing** — the
  tactical→operational link, its HTTPS ingest, platform binding,
  and pairing ceremony: unchanged.
- **Shepherd↔Predator same-LAN auto-discovery** — unchanged.
- **The Dart app** — no changes, and **no protocol-visible
  difference**: the JSON it consumes is byte-identical before,
  during, and after a refresh (§14's gateway item above). Stated
  precisely, the app *can* perceive a refresh only indirectly and
  operationally, never in content: during a session the gateway
  AP moves to 192.168.6.1 (so the app's gateway path pauses and
  it must re-associate like any other client, §2), and frames
  missed during a blocking session step (§2/§13) simply never
  arrive. A refreshed fleet and an unrefreshed one emit exactly
  the same JSON.

Why: every one of those is a surface *others* connect to. Putting
fleet keys on them would trade away interoperability — the thing
that makes Shepherd composable — to encrypt links whose threat
model is already served by their own layers (or by being
operator-local). Per-fleet keys stop at the fleet boundary; that
is the design, not an omission.

## 15. Tests

`field_kit/esp32/tests/`, extending (never replacing) the codec
suites, which pass unchanged:

- **ML-KEM known answers** (`test_keyrefresh_cpp.cpp` against
  `mlkem_kat_vectors.json`): the REAL vendored C code vs the
  official **NIST ACVP** ML-KEM-512 vectors (FIPS 203 keyGen and
  encapDecap internalProjection sets, excerpts retrieved
  2026-10-23): derand keygen → `(ek, dk)`, derand encap →
  `(ct, ss)`, decap → `ss`. The mbedTLS test doubles are anchored
  first (FIPS 180-4 SHA-256, RFC 4231 HMAC #1, RFC 5869 HKDF #1,
  RFC 3610 CCM #1 via the codec suite).
- **Handshake** (C++ on the real header + Python model): happy
  path derives the identical key + key ID on both sides; wrong-PSK
  authenticator, tampered `ek`, tampered `ct`, tampered counter
  each fail closed with their distinct codes. The tampered-`ek`
  C++ test deterministically exercises the node's HMAC refusal
  (it asserts encapsulation succeeds first, since PQClean's KEM
  entry points always return 0); a mutation spot-check —
  removing the node's HMAC comparison in a *copy* of the library —
  fails 6 checks including that one, proving the tamper tests are
  not vacuous.
- **Rotation**: happy path through the real codec wrap; CCM
  tamper; replayed payload; rollback (`counter <= committed`)
  refused on both sides; staged-not-committed revert on timeout.
- **Counter rule (F2)**: gap counters (`committed + 2`) accepted
  at stage on both mechanisms and both sides; `<= committed`
  refused distinctly.
- **Commit/abort authentication**: a bad commit proof leaves the
  staged context alive and a retried honest commit lands (F15);
  abort requires the staged-key proof when a context exists and
  is a no-op success without one (F5); a commit proof made for
  node A is refused by node B (F6 identity binding).
- **Rotate-reply gate (F7)**: the gateway window stays closed
  after the rotation is made; a reply with a wrong key ID or
  counter fails the session at the rotate step with the mismatch
  counter incremented.
- **Freshness after commit (F1)**: a freshness-aware gateway
  model in both suites — a node at `(boot, frame) = (7, 2800)`
  refreshes; its commit bumps the boot counter; post-commit
  frames `(8, 0..)` decode; replayed old frames are rejected
  under either key; a replay-classified staged-key frame never
  promotes; the promoting frame itself is delivered.
- **Lost ACK (F4)**: after a simulated lost commit ACK the
  gateway context stays CONFIRMED and awaiting-frame, the window
  still accepts the staged key, and the frame trigger promotes.
  Gateway-side staged-context expiry is covered in both suites.
- **Rounds (F2)**: a 3-node round in both suites — mid-round,
  old-key nodes keep decoding and committed nodes decode on the
  round key while the gateway is *not* promoted; abort is
  permitted before the first node commit and refused after;
  after the explicit promote, only the round key decodes.
- **Window & persistence**: dual-key acceptance (both keys in the
  window, only new after commit, only old after abort); committed
  state survives a modeled reboot; staged state never promotes
  itself across one.
- **Regression**: codec Python suite (21 tests) and C++ suite
  (34 checks) pass unchanged; the codec header and its frozen
  vectors are untouched.
