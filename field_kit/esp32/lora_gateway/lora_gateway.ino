/*
 * Shepherd LoRa Gateway (SLG-XXXX) — ESP32 + SX1276
 *
 * Flash once. The gateway boots, hosts WiFi AP "Shepherd-LoRa-XXXX"
 * (password "shepherd-field") so the Shepherd PC just joins it — no STA
 * config needed for basic operation. It listens on LoRa for SLN node
 * packets, decodes them, and re-emits them on UDP broadcast 49160 as the
 * STANDARD Shepherd JSON beacon/event with the ORIGINAL node id
 * ("SLN-XXXX", sensors:["lora"]). It also emits its own gateway beacon
 * ("SLG-XXXX", sensors:["lora-gw"]), runs mDNS "_shepherd-node"/udp/49160,
 * and serves a tiny status page listing recently heard nodes.
 *
 * The gateway NEVER transmits on LoRa (receive-only) and does NO fusion
 * or filtering — it tracks per-node last-heard, nothing more. Nodes never
 * receive on LoRa. Star topology: SLN nodes -> this gateway -> UDP.
 *
 * Wiring (SX1276 module, defaults — change below if your board differs):
 *   VSPI: SCK=18 MISO=19 MOSI=23  (ESP32 default VSPI; SPI.begin(18,19,23))
 *   LoRa: NSS=5, DIO0=26, DIO1=33, RESET=14, BUSY unused
 *
 * Region: pick the SAME region flag as your nodes (default US915):
 */
//#define LORA_REGION_EU868   // 868 MHz — EU 1% duty-cycle rules apply
//#define LORA_REGION_AS433   // 433 MHz — check local rules before use
#define LORA_REGION_US915     // 915 MHz (default)
// Optional: join an existing network instead of hosting the AP:
//#define LORA_GW_STA
//#define LORA_GW_STA_SSID "your-ssid"
//#define LORA_GW_STA_PASS "your-pass"

/*
 * Codec v1 — identical layout to lora_node.ino (kept in sync by hand):
 *
 * BEACON 22 B (0x01): [0]=schema(1) [1]=0x01 [2-3]=node suffix u16
 *   [4-7]=uptime_s u32 [8-9]=event count u16 [10-13]=lat*1e6 i32
 *   [14-17]=lon*1e6 i32 [18]=flags(bit0 GPS fix,bit1 PPS) [19]=fps u8
 *   [20-21]=battery mV u16 (0=unmeasured)
 * EVENT 22 B (0x02): [0]=schema(1) [1]=0x02 [2-3]=node suffix u16
 *   [4-7]=t0 u32 [8-15]=t_us u64 [16-17]=dur*100 u16 [18]=depth*10 u8
 *   [19]=class(0 UNKNOWN,1 PASSING,2 LINGERING) [20]=conf*100 u8
 *   [21]=sensor(0=wifi)
 *
 * Re-emitted JSON is byte-compatible with the SHN node's UDP format; the
 * Shepherd ESP32Driver needs no changes to ingest SLN nodes via LoRa.
 * Unknown schema versions and wrong-length packets are dropped, not
 * guessed at.
 *
 * Codec v2 — PSK (schema byte = 2, 34 B on air; full spec in
 * docs/lora_psk_codec_spec.md): the v1 payload bytes [1-21] arrive
 * AES-128-CCM encrypted under the deployment PSK, because v1's
 * PLAINTEXT node ID at bytes [2-3] is the handle for Aras-style
 * per-node selective jamming (MobiQuitous 2017). Processing order is
 * normative: schema gate FIRST (byte [0] is plaintext precisely so
 * this works), length check, then authenticate-and-decrypt, then a
 * freshness check on the nonce counters, then the decrypted payload
 * is rebuilt into a v1 buffer and run through the SAME decode path
 * below — so the re-emitted JSON is byte-identical to v1. Packets
 * that fail the tag check (wrong PSK, tampered) are dropped and
 * counted, never decoded. v1 packets are still accepted (mixed
 * fleet during migration) and counted as "legacy" on the status page.
 * Set the PSK on this gateway's status page BEFORE setting node PSKs:
 * an old gateway drops schema 2 at the gate, so gateways upgrade
 * first. No PSK set here => v2 frames are dropped (counted) and the
 * status page says so. There is NO default key.
 *
 * Honest scope: this is a protocol bridge, not a network — one gateway,
 * many nodes, Aloha-style uplink with no ACKs or retries. Two nodes that
 * transmit at the same instant collide and both packets are lost (the
 * next beacon 30 s later recovers). Keep node counts modest (a handful
 * per gateway) or stagger nothing — there is no coordination to stagger.
 * Range: same physics as the node (km-class LOS at SF7, less in clutter).
 */

#include <WiFi.h>
#include <WiFiUdp.h>
#include <WebServer.h>
#include <Preferences.h>
#include <SPI.h>
#include <ESPmDNS.h>
#include <RadioLib.h>
#include <lora_psk_codec.h>  // codec v2 unwrap — SHARED with the node
                               // (esp32/shepherd_lora_psk library; see
                               // docs/lora_psk_codec_spec.md)
#include <keyrefresh.h>    // key refresh/rotation — SHARED library
                               // (esp32/shepherd_lora_keyrefresh; see
                               // docs/lora_key_refresh_spec.md)
#include <HTTPClient.h>    // gateway -> node Wi-Fi client (key refresh)
#include "esp_system.h"    // esp_fill_random (rotation CSPRNG)
#include "mbedtls/md.h"    // SHA-256 for the displayed key ID only

#if defined(LORA_REGION_EU868)
  #define LORA_FREQ_MHZ 868.0f
#elif defined(LORA_REGION_AS433)
  #define LORA_FREQ_MHZ 433.0f
#else
  #define LORA_FREQ_MHZ 915.0f
#endif

#define LORA_NSS   5
#define LORA_DIO0  26
#define LORA_DIO1  33
#define LORA_RST   14

#define BEACON_PORT 49160
#define WIFI_CH     6
#define GW_BEACON_MS 30000UL
#define MAX_NODES   16

#define CODEC_SCHEMA   1
#define PKT_BEACON     0x01
#define PKT_EVENT      0x02
#define PKT_BEACON_LEN 22
#define PKT_EVENT_LEN  22

// Codec v2 (PSK wrap) — the wire constants and the wrap/unwrap codec
// live in the SHARED header <lora_psk_codec.h> (esp32/shepherd_lora_psk
// library), used by this gateway and the node so the two can never
// drift apart on the wire format. See docs/lora_psk_codec_spec.md.
using shepherd_psk::getU16;
using shepherd_psk::getU32;

static int32_t getI32(const uint8_t *p) { return (int32_t)getU32(p); }
static uint64_t getU64(const uint8_t *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
  return v;
}

static const char *className(uint8_t c) {
  return c == 1 ? "PASSING" : c == 2 ? "LINGERING" : "UNKNOWN";
}
static const char *sensorName(uint8_t s) {
  return s == 0 ? "wifi" : "unknown";
}

// ---------------- codec v2: PSK state ----------------
static uint8_t  pskKey[16];
static bool     pskSet = false;
static char     pskKeyId[5] = "----";   // first 2 B of SHA-256(key), hex
static uint32_t rxLegacy = 0;           // v1 plaintext packets accepted
static uint32_t rxAuthFail = 0;         // v2 tag-check failures (dropped)
static uint32_t rxReplay = 0;           // v2 stale-counter frames (dropped)
static uint32_t rxNoKey = 0;            // v2 frames dropped: no PSK here
static uint32_t rxNoState = 0;          // v2 frames dropped: freshness state unavailable (fail closed)
static uint32_t pskClearRefused = 0;    // /pskclear attempts refused
static bool     apPassDefault = true;   // ap_pass still the public default

static bool parseHexKey(const String &s, uint8_t out[16]) {
  if (s.length() != 32) return false;
  for (int i = 0; i < 16; i++) {
    auto hv = [](char c) -> int {
      if (c >= '0' && c <= '9') return c - '0';
      if (c >= 'a' && c <= 'f') return c - 'a' + 10;
      if (c >= 'A' && c <= 'F') return c - 'A' + 10;
      return -1;
    };
    int hi = hv(s[2 * i]), lo = hv(s[2 * i + 1]);
    if (hi < 0 || lo < 0) return false;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return true;
}

static void computeKeyId() {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  uint8_t digest[32];
  if (info && mbedtls_md(info, pskKey, 16, digest) == 0)
    snprintf(pskKeyId, sizeof(pskKeyId), "%02X%02X", digest[0], digest[1]);
}

// Authenticate-and-decrypt is shepherd_psk::unwrap() in the shared
// header <lora_psk_codec.h> — the same code the node wraps with and
// the host C++ test verifies against the frozen vectors.

Preferences prefs;
WebServer server(80);
WiFiUDP udp;
SX1276 radio = new Module(LORA_NSS, LORA_DIO0, LORA_RST, LORA_DIO1);

char gwId[16] = "SLG-0000";
char gwSsid[28] = "";
char gwApPass[64] = "";
uint32_t bootMs = 0;
uint32_t rxOk = 0, rxBad = 0;

// ---------------- key refresh / rotation (lora_key_refresh_spec.md) ----
// This gateway INITIATES refresh/rotation over Wi-Fi: for a session
// it runs APSTA — its own AP moves to 192.168.6.1 (status page stays
// reachable) while its STA joins the target node's AP — then drives
// the stage -> confirm -> commit machine in <keyrefresh.h> from
// loop() (krPump).
//
// HONEST STALL DISCLOSURE (F11 — this comment previously claimed
// "LoRa handling never blocks on Wi-Fi"; that was false): the
// session steps run synchronously inside loop() and each step is a
// blocking HTTP exchange (two sequential posts for Mechanism A,
// 8 s client timeouts — worst case a step stalls loop() for
// ~16 s). While loop() is stalled the LoRa receiver is not
// serviced, so frames arriving during a stall can be MISSED. The
// link is Aloha-lossy by design (no ACKs/retries; the next 30 s
// beacon recovers state), which is what makes this tolerable for a
// maintenance action — it is not free. Splitting the exchanges
// into non-blocking chunks is future work (spec §13).
static shepherd_kr::GwCtx krCtx;
static uint32_t krCtr = 0;              // committed key_counter (NVS kr_ctr)
static uint8_t  krSelfId[8] = {0};      // "SLG-XXXX"
static bool     krPersistFault = false; // promote NVS verify failed (F3)
static uint32_t krPersistFailCount = 0;
#define KR_STAGE_TIMEOUT_MS 120000UL
#define KR_SESSION_STEP_TIMEOUT_MS 45000UL

enum KrPhase : uint8_t {
  KR_PH_NONE = 0,     // no Wi-Fi session
  KR_PH_CONNECT,      // STA joining the node AP
  KR_PH_STEP,         // run the mechanism's Wi-Fi steps (-> window)
  KR_PH_WINDOW,       // staged+confirmed; awaiting operator commit/abort
  KR_PH_COMMIT,       // send /kr/commit, then promote
  KR_PH_ROUND_COMMIT, // round session: send /kr/commit to this node only
  KR_PH_ABORT,        // authenticated /kr/abort, then tear down
  KR_PH_TEARDOWN,     // Wi-Fi restore only (session already resolved)
};
static KrPhase  krPhase = KR_PH_NONE;
static shepherd_kr::KrMechanism krSessMech = shepherd_kr::KR_MECH_NONE;
static char     krNodeSuffix[5] = "";   // "XXXX" of the target SLN
static char     krNodePass[64] = "";    // node AP password (RAM only)
static uint8_t  krNodeId[8] = {0};      // "SLN-XXXX"
static uint8_t  krRotKey[16] = {0};     // Mechanism B: key to push
static bool     krRotKeySet = false;
static uint32_t krPhaseMs = 0;
static bool     krPendingWifi = false;  // F9: APSTA switch deferred to krPump
static bool     krSessRound = false;    // this Wi-Fi session serves the open round

// F2: per-node round status, shown on the status page.
enum KrRoundStatus : uint8_t {
  KR_RS_STAGED = 0, KR_RS_COMMITTED = 1, KR_RS_AWAITING = 2, KR_RS_FAILED = 3
};
struct KrRoundNode { char suffix[5]; uint8_t nodeId[8]; uint8_t status; bool used; };
static KrRoundNode krRoundNodes[16];
static const char *krRoundStatusName(uint8_t s) {
  return s == KR_RS_COMMITTED ? "COMMITTED" : s == KR_RS_AWAITING ? "AWAITING-FRAME"
       : s == KR_RS_FAILED ? "FAILED" : "STAGED";
}
static void krRoundSet(const char *suffix, const uint8_t *nodeId, uint8_t status) {
  int free = -1;
  for (int i = 0; i < 16; i++) {
    if (krRoundNodes[i].used && strcmp(krRoundNodes[i].suffix, suffix) == 0) {
      krRoundNodes[i].status = status;
      return;
    }
    if (!krRoundNodes[i].used && free < 0) free = i;
  }
  if (free >= 0) {
    krRoundNodes[free].used = true;
    snprintf(krRoundNodes[free].suffix, 5, "%s", suffix);
    memcpy(krRoundNodes[free].nodeId, nodeId, 8);
    krRoundNodes[free].status = status;
  }
}
static void krRoundSetBySuffix16(uint16_t suffix, uint8_t status) {
  char s[5];
  snprintf(s, sizeof(s), "%04X", suffix);
  for (int i = 0; i < 16; i++)
    if (krRoundNodes[i].used && strcmp(krRoundNodes[i].suffix, s) == 0) {
      krRoundNodes[i].status = status;
      return;
    }
}

// Persist a promotion (the gateway's ONLY refresh NVS write) and
// adopt the key in RAM. F3: the write is read back and verified,
// mirroring the node. RAM adoption happens even when verification
// fails — the fleet has already moved (the node committed), so
// staying on the old key in RAM would blackhole it immediately —
// but the fault is flagged loudly (status page + counter): a
// reboot would revert this gateway to the OLD persisted key, and
// the operator must fix the flash fault and re-run/repair per
// spec §8/§9. Returns true only when the write verified.
static bool krPersistPromote(const uint8_t key[16], uint32_t ctr) {
  static const char *H = "0123456789abcdef";
  char hex[33];
  for (int i = 0; i < 16; i++) { hex[2 * i] = H[key[i] >> 4]; hex[2 * i + 1] = H[key[i] & 15]; }
  hex[32] = 0;
  prefs.putString("psk_hex", hex);
  prefs.putUInt("kr_ctr", ctr);
  String back = prefs.getString("psk_hex", "");
  bool verified = (back == hex && prefs.getUInt("kr_ctr", 0) == ctr);
  memcpy(pskKey, key, 16);
  pskSet = true;
  computeKeyId();
  krCtr = ctr;
  if (!verified) {
    krPersistFault = true;
    krPersistFailCount++;
    Serial.println("!! KR promote NVS verify FAILED — gateway runs the new key "
                   "from RAM only; a reboot reverts to the OLD key");
  }
  Serial.printf("KR PROMOTED: gateway now on key ID %s ctr=%lu verified=%d\n",
                pskKeyId, (unsigned long)krCtr, verified ? 1 : 0);
  return verified;
}

// Display table ONLY: what the status page shows. It is small (16),
// evicts nothing, and fills with unauthenticated v1 traffic — so codec
// v2 freshness/replay state must NEVER live here (it did, originally:
// a full display table silently disabled the replay check). Freshness
// has its own decoupled storage — see FreshEntry below.
struct HeardNode {
  uint16_t suffix = 0;
  uint32_t lastHeard = 0;   // millis
  uint32_t uptimeS = 0;
  uint16_t evCount = 0;
  float lat = 0, lon = 0;
  uint8_t flags = 0, fps = 0;
  bool used = false;
};
HeardNode nodes[MAX_NODES];

volatile bool rxFlag = false;
void IRAM_ATTR onRx() { rxFlag = true; }

// returns index into nodes[], or -1 when the table is full
// (packet is still re-emitted; only the last-heard table misses it)
int findNodeIdx(uint16_t suffix, uint32_t now) {
  int free = -1;
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].used && nodes[i].suffix == suffix) return i;
    if (!nodes[i].used && free < 0) free = i;
  }
  if (free >= 0) {
    nodes[free].used = true; nodes[free].suffix = suffix;
    nodes[free].lastHeard = now;
  }
  return free;
}

// ---------------- codec v2: freshness state (replay protection) ----
// Dedicated storage for the last accepted (boot_ctr, frame_ctr) per
// node — decoupled from the display table above, on purpose:
//   * entries are created ONLY after a frame passes the CCM tag
//     check, so unauthenticated traffic (v1 stuffing included) can
//     never touch this state;
//   * the replay check consults ONLY this table, so its outcome never
//     depends on display-table luck;
//   * a frame whose freshness cannot be verified (unknown suffix and
//     no free entry) is DROPPED and counted (rxNoState) — fail closed,
//     never silently decoded.
// 48 entries is ~10x the design fleet ("a handful of nodes per
// gateway", docs/lora_psk_codec_spec.md); if a deployment ever
// outgrows it, rxNoState climbing on the status page is the signal.
#define MAX_FRESH 48
struct FreshEntry {
  uint16_t suffix = 0;
  uint32_t bootCtr = 0, frameCtr = 0;
  bool used = false;
  // F1: set when this suffix's entry was rebased at a key-refresh
  // promotion (its node committed and bumped boot_ctr). For a
  // rebased suffix the legacy "lower boot = reflash resync"
  // acceptance is DISABLED: a lower boot counter is a replay of
  // pre-commit traffic, not a resync (spec §8).
  bool krRebased = false;
};
FreshEntry freshTable[MAX_FRESH];

// F1(b): mark a suffix rebased at an explicit-ACK promotion (the
// frame-trigger path rebases inline in handlePacket). The stored
// high-water is kept — the node's post-commit frames carry a
// HIGHER boot counter and pass; captured pre-commit frames at the
// old boot are rejected by the krRebased rule in handlePacket.
static void freshMarkRebased(uint16_t suffix) {
  int fi = -1;
  for (int i = 0; i < MAX_FRESH; i++)
    if (freshTable[i].used && freshTable[i].suffix == suffix) { fi = i; break; }
  if (fi >= 0) {
    freshTable[fi].krRebased = true;
  }
}

// Freshness state is persisted to NVS on every accepted v2 frame and
// restored at boot. Without persistence, a gateway reboot forgot the
// high-water marks and any captured frame could re-seed them — a
// replayed frame dominating the node's current counters locks the
// genuine node out as a "replay" until its counter catches up
// (~41 h at beacon cadence for a 5000-frame seed). Writes happen at
// most at beacon rate (1 per 30 s per node, typically far less);
// ESP32 NVS is log-structured and wear-levelled across its partition,
// so this costs decades of margin for a handful of nodes — the spec
// carries the reasoning.
void freshPersist() {
  prefs.putBytes("freshstate", freshTable, sizeof(freshTable));
}
void freshRestore() {
  FreshEntry tmp[MAX_FRESH];
  size_t n = prefs.getBytes("freshstate", tmp, sizeof(tmp));
  if (n == sizeof(tmp)) memcpy(freshTable, tmp, sizeof(tmp));
}
int freshFind(uint16_t suffix) {
  for (int i = 0; i < MAX_FRESH; i++)
    if (freshTable[i].used && freshTable[i].suffix == suffix) return i;
  return -1;
}
int freshAlloc() {
  for (int i = 0; i < MAX_FRESH; i++)
    if (!freshTable[i].used) return i;
  return -1;
}

void udpSend(const char *json) {
  udp.beginPacket(WiFi.broadcastIP(), BEACON_PORT);
  udp.write((uint8_t *)json, strlen(json));
  udp.endPacket();
}

void reemitBeacon(uint16_t suffix, uint32_t uptimeS, uint16_t evCount,
                  float lat, float lon, uint8_t flags, uint8_t fps) {
  char nid[12]; snprintf(nid, sizeof(nid), "SLN-%04X", suffix);
  char buf[384];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"beacon\",\"node\":\"%s\",\"ip\":\"%s\",\"ch\":%d,"
    "\"fps\":%u,\"events\":%u,\"uptime_s\":%lu,"
    "\"sensors\":[\"lora\"],\"ble_seen\":0,"
    "\"lat\":%.6f,\"lon\":%.6f,\"pps\":%d}",
    nid, WiFi.softAPIP().toString().c_str(), WiFi.channel(),
    fps, evCount, (unsigned long)uptimeS,
    lat, lon, (flags & 0x02) ? 1 : 0);
  udpSend(buf);
  Serial.printf("RX beacon %s ev=%u\n", nid, evCount);
}

void reemitEvent(uint16_t suffix, uint32_t t0, uint64_t tUs, float durS,
                 float depthDb, uint8_t cls, float conf, uint8_t sensor) {
  char nid[12]; snprintf(nid, sizeof(nid), "SLN-%04X", suffix);
  char buf[384];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"event\",\"node\":\"%s\",\"sensor\":\"%s\",\"t0\":%lu,"
    "\"t_us\":%llu,\"dur_s\":%.1f,\"depth_db\":%.1f,"
    "\"class\":\"%s\",\"conf\":%.2f,\"detail\":\"\"}",
    nid, sensorName(sensor), (unsigned long)t0, (unsigned long long)tUs,
    durS, depthDb, className(cls), conf);
  udpSend(buf);
  Serial.printf("RX event %s %s dur=%.1fs depth=%.1fdB\n",
                nid, className(cls), durS, depthDb);
}

// The v1 decode path, unchanged from codec v1: given a complete
// 22-byte v1-layout packet, decode and re-emit it. v2 packets are
// rebuilt into this exact layout after decryption (see handlePacket),
// which is what guarantees byte-identical JSON for both wire versions.
// wireV1 is true ONLY for frames that arrived as wire-format v1: the
// legacy counter increments on this path's SUCCESS branches only, so
// a malformed schema-1 frame counts as bad — never as legacy AND bad.
void decodeV1(const uint8_t *p, size_t len, uint32_t now, bool wireV1) {
  if (p[1] == PKT_BEACON && len == PKT_BEACON_LEN) {
    uint16_t suffix = getU16(p + 2);
    uint32_t uptimeS = getU32(p + 4);
    uint16_t evCount = getU16(p + 8);
    float lat = getI32(p + 10) / 1e6f, lon = getI32(p + 14) / 1e6f;
    uint8_t flags = p[18], fps = p[19];
    int ni = findNodeIdx(suffix, now);
    HeardNode *nd = ni >= 0 ? &nodes[ni] : nullptr;
    if (nd) {
      nd->lastHeard = now; nd->uptimeS = uptimeS; nd->evCount = evCount;
      nd->lat = lat; nd->lon = lon; nd->flags = flags; nd->fps = fps;
    }
    rxOk++;
    if (wireV1) rxLegacy++;
    reemitBeacon(suffix, uptimeS, evCount, lat, lon, flags, fps);
  } else if (p[1] == PKT_EVENT && len == PKT_EVENT_LEN) {
    uint16_t suffix = getU16(p + 2);
    uint32_t t0 = getU32(p + 4);
    uint64_t tUs = getU64(p + 8);
    float durS = getU16(p + 16) / 100.0f;
    float depthDb = p[18] / 10.0f;
    uint8_t cls = p[19], sensor = p[21];
    float conf = p[20] / 100.0f;
    int ni = findNodeIdx(suffix, now);
    if (ni >= 0) nodes[ni].lastHeard = now;
    rxOk++;
    if (wireV1) rxLegacy++;
    reemitEvent(suffix, t0, tUs, durS, depthDb, cls, conf, sensor);
  } else {
    rxBad++;  // unknown type or wrong length — dropped, not guessed at
  }
}

// Entry point for every received LoRa frame. Processing order is
// normative (docs/lora_psk_codec_spec.md): the schema gate fires
// FIRST, on the plaintext byte [0], before any decryption is
// attempted; unknown schemas never reach the crypto code at all.
void handlePacket(const uint8_t *p, size_t len, uint32_t now) {
  if (len < 1) { rxBad++; return; }

  if (p[0] == CODEC_SCHEMA) {              // v1 legacy plaintext
    if (len < 2) { rxBad++; return; }
    decodeV1(p, len, now, true);           // rxLegacy counts on success only
    return;
  }

  if (p[0] == shepherd_psk::SCHEMA_PSK) {  // v2 PSK
    if (len != shepherd_psk::WIRE_LEN) { rxBad++; return; }
    if (!pskSet) { rxNoKey++; return; }    // nowhere to put it — drop
    uint8_t plain[shepherd_psk::PAYLOAD_LEN];
    // Key selection (lora_key_refresh_spec.md S7.2): outside a
    // refresh window this is exactly the historic single-key unwrap.
    // Inside the window (krCtx CONFIRMED) the staged candidate is
    // tried second — the wire has no key-ID field, so acceptance is
    // ordered try-both, both attempts inside the shared library.
    bool usedStaged = false;
    if (!shepherd_kr::gwUnwrapDual(krCtx, pskKey, p, plain, &usedStaged)) {
      rxAuthFail++;
      return;                              // dropped, never decoded
    }
    // Rebuild the equivalent v1 packet for the shared decode path
    // (shared codec — shepherd_psk::rebuildV1).
    uint8_t v1[PKT_BEACON_LEN];
    shepherd_psk::rebuildV1(plain, v1);
    // Freshness: the nonce counters are authenticated now (tag
    // passed). Frames must be strictly newer than the last accepted
    // one from this node, per boot. The check consults ONLY the
    // dedicated freshness table — never the display table — and a
    // frame whose state cannot be established fails closed (drop +
    // rxNoState), never silently decoded. A LOWER boot counter is
    // accepted unconditionally and rewinds the stored state (the
    // node's NVS was wiped / reflashed) — EXCEPT for a suffix whose
    // entry was rebased at a key-refresh promotion (krRebased, F1):
    // there a lower boot is captured pre-commit traffic and is
    // dropped as a replay. The codec spec states the resync
    // acceptance and its replay consequence honestly.
    uint32_t bc = shepherd_psk::getU32(p + shepherd_psk::NONCE_OFF);
    uint32_t fc = shepherd_psk::getU32(p + shepherd_psk::NONCE_OFF + 4);
    uint16_t suffix = shepherd_psk::getU16(v1 + 2);
    int fi = freshFind(suffix);
    // F1(c): a staged-key frame is only a promotion CANDIDATE. The
    // promotion happens AFTER the frame passes freshness under the
    // rebased state — a replay-classified frame must never trigger
    // an irreversible persist. Classification uses the PRE-rebase
    // high-water: counters at or below it (same boot), or any lower
    // boot, are replay-classified for this purpose. (Post-commit
    // frames legitimately carry boot+1: the node bumps boot_ctr
    // persistently at commit, F1(a).) While a ROUND is open (F2),
    // auto-promotion is disabled entirely — the operator promotes.
    bool promoteCandidate = usedStaged &&
                            krCtx.state == shepherd_kr::KR_CONFIRMED &&
                            !krCtx.roundOpen;
    if (promoteCandidate) {
      if (fi >= 0) {
        FreshEntry &fe0 = freshTable[fi];
        if (bc < fe0.bootCtr || (bc == fe0.bootCtr && fc <= fe0.frameCtr)) {
          rxReplay++;
          return;                          // replay — NO promotion, drop
        }
      }
      // F1(b): rebase this suffix's freshness entry — it is seeded
      // below by THIS frame's counters, marked krRebased, and only
      // now does the gateway promote (persist) and close the window.
      uint8_t nk[16]; uint32_t nc = 0;
      if (shepherd_kr::gwPromote(krCtx, nk, &nc) == shepherd_kr::KR_OK) {
        krPersistPromote(nk, nc);
        if (krPhase == KR_PH_WINDOW || krPhase == KR_PH_STEP) krPhase = KR_PH_TEARDOWN;
      }
      if (fi >= 0) {
        FreshEntry &fe = freshTable[fi];
        fe.bootCtr = bc; fe.frameCtr = fc; fe.krRebased = true;
        freshPersist();
        decodeV1(v1, PKT_BEACON_LEN, now, false);
        return;
      }
      // No entry yet: fall through to the standard alloc-and-seed
      // path below (promotion already done; the entry seeds fresh).
    }
    if (fi >= 0) {
      FreshEntry &fe = freshTable[fi];
      if (bc == fe.bootCtr && fc <= fe.frameCtr) {
        rxReplay++;
        return;                            // stale / replayed — drop
      }
      if (bc < fe.bootCtr) {
        if (fe.krRebased) {
          // F1: a refreshed suffix never rewinds — a lower boot is
          // captured pre-commit traffic, not a reflash resync.
          rxReplay++;
          return;
        }
        Serial.printf("PSK ctr resync SLN-%04X (boot %lu < %lu) — state rewound\n",
                      suffix, (unsigned long)bc, (unsigned long)fe.bootCtr);
      }
      fe.bootCtr = bc; fe.frameCtr = fc;
      if (usedStaged && krCtx.roundOpen) {
        // This round node has committed (it transmits the round key
        // with a bumped boot counter): mark it, protect its suffix,
        // and recount committed round nodes from the page table so
        // the count stays exact even across WiFi-session commits.
        fe.krRebased = true;
        krRoundSetBySuffix16(suffix, KR_RS_COMMITTED);
        uint32_t cnt = 0;
        for (int i = 0; i < 16; i++)
          if (krRoundNodes[i].used && krRoundNodes[i].status == KR_RS_COMMITTED) cnt++;
        krCtx.roundCommitted = cnt;
      }
    } else {
      fi = freshAlloc();
      if (fi < 0) { rxNoState++; return; }   // fail closed — never decode unverified
      freshTable[fi].suffix = suffix;
      freshTable[fi].bootCtr = bc;
      freshTable[fi].frameCtr = fc;
      freshTable[fi].used = true;
      freshTable[fi].krRebased = (usedStaged && krCtx.roundOpen);
      if (freshTable[fi].krRebased) krRoundSetBySuffix16(suffix, KR_RS_COMMITTED);
    }
    freshPersist();
    decodeV1(v1, PKT_BEACON_LEN, now, false);
    return;
  }

  rxBad++;  // unknown schema — dropped at the gate, never decrypted
}

void sendGwBeacon() {
  char buf[384];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"beacon\",\"node\":\"%s\",\"ip\":\"%s\",\"ch\":%d,"
    "\"fps\":0,\"events\":%lu,\"uptime_s\":%lu,"
    "\"sensors\":[\"lora-gw\"],\"ble_seen\":0,"
    "\"lat\":0.000000,\"lon\":0.000000,\"pps\":0}",
    gwId, WiFi.softAPIP().toString().c_str(), WiFi.channel(),
    (unsigned long)rxOk, (unsigned long)((millis() - bootMs) / 1000));
  udpSend(buf);
}

void handlePskSave() {
  String k = server.arg("k"); k.trim();
  uint8_t tmp[16];
  if (!parseHexKey(k, tmp)) {
    server.send(400, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "PSK must be exactly 32 hex characters. <a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  prefs.putString("psk_hex", k);
  server.send(200, "text/html",
    "<html><body style='background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px'>"
    "PSK saved. <b>Reboot the gateway</b> to start decrypting v2 packets, then "
    "set the SAME key on each node. <a href=/ style='color:#a855f7'>Back</a></body></html>");
}
// Clearing the PSK downgrades the whole deployment's wire, so
// reaching this page is not enough (the AP password is a public
// default): the operator must type the currently displayed key ID
// into the confirmation field. A wrong or absent confirmation is
// refused, counted, and logged — the key stays set.
static bool confirmMatchesKeyId() {
  String c = server.arg("confirm"); c.trim(); c.toUpperCase();
  return pskSet && c.length() > 0 && c == String(pskKeyId);
}

void handlePskClear() {
  if (!pskSet) {
    server.send(200, "text/html",
      "<html><body style='background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px'>"
      "No PSK is set on this gateway — nothing to clear. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  if (!confirmMatchesKeyId()) {
    pskClearRefused++;
    Serial.printf("PSK clear REFUSED (bad key-ID confirmation) — refusals: %lu\n",
                  (unsigned long)pskClearRefused);
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Clear REFUSED: type the key ID shown on the status page into the "
      "confirmation box, exactly as displayed. The PSK was NOT cleared. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  Serial.println("PSK cleared by operator (key-ID confirmation matched)");
  prefs.remove("psk_hex");
  server.send(200, "text/html",
    "<html><body style='background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px'>"
    "PSK cleared. Reboot the gateway — v2 packets will be dropped until a key "
    "is set again. <a href=/ style='color:#a855f7'>Back</a></body></html>");
}

// AP password change. ap_pass lives in Preferences and is read once
// at boot (setup), so a change takes effect on reboot — the page says
// so, plainly. The submitted value is only stored: never echoed into
// a response, never printed on Serial, never shown on the status page
// (the page reports only "public DEFAULT in use" vs "custom set").
void handleApPassSave() {
  String p = server.arg("ap");
  if (p.length() < 8 || p.length() > 63) {
    server.send(400, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "AP password must be 8-63 characters (the WPA2 rule). Nothing was "
      "saved. <a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  prefs.putString("ap_pass", p);
  Serial.println("AP password changed by operator (takes effect on reboot)");
  server.send(200, "text/html",
    "<html><body style='background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px'>"
    "AP password saved. It takes effect on <b>reboot</b> — after rebooting "
    "you will need to rejoin this AP with the new password. "
    "<a href=/ style='color:#a855f7'>Back</a></body></html>");
}

// ---- key-refresh failure surfacing (F10) ----
// Session failures were Serial-only; they are now counted and the
// last reason is kept for the status page.
static uint32_t krFailCount = 0;
static char     krLastFail[72] = "";
static void krNoteFail(const char *why) {
  krFailCount++;
  snprintf(krLastFail, sizeof(krLastFail), "%s", why);
  Serial.printf("KR failure #%lu: %s\n", (unsigned long)krFailCount, why);
}

// ---- key-refresh Wi-Fi session machinery ----
static void krWifiSessionBegin() {
  char nodeSsid[24];
  snprintf(nodeSsid, sizeof(nodeSsid), "Shepherd-SLN-%s", krNodeSuffix);
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAPConfig(IPAddress(192, 168, 6, 1), IPAddress(192, 168, 6, 1),
                    IPAddress(255, 255, 255, 0));
  WiFi.softAP(gwSsid, gwApPass, WIFI_CH);
  WiFi.begin(nodeSsid, krNodePass);
  Serial.printf("KR session: AP moved to 192.168.6.1, joining node AP %s\n", nodeSsid);
}
static void krWifiSessionEnd() {
  WiFi.disconnect(true);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1),
                    IPAddress(255, 255, 255, 0));
  WiFi.softAP(gwSsid, gwApPass, WIFI_CH);
  krPhase = KR_PH_NONE;
  krSessRound = false;
  memset(krNodePass, 0, sizeof(krNodePass));
  // F14: scrub the operator/CSPRNG rotation key at every session
  // end. (Round sessions never use krRotKey — the round key lives
  // in krCtx until the round itself ends — so this is always safe.)
  memset(krRotKey, 0, sizeof(krRotKey));
  krRotKeySet = false;
  Serial.println("KR session: Wi-Fi restored (AP back on 192.168.4.1)");
}

// Minimal binary HTTP POST to the node (192.168.4.1 on its AP).
// Returns the HTTP status, or -1 on transport failure. Response
// bytes (binary — never String) are copied when resp != nullptr.
static int krPost(const char *path, const uint8_t *body, size_t blen,
                  uint8_t *resp, size_t *rlen, size_t rmax) {
  HTTPClient http;
  char url[48];
  snprintf(url, sizeof(url), "http://192.168.4.1%s", path);
  http.setTimeout(8000);
  if (!http.begin(url)) return -1;
  http.addHeader("Content-Type", "application/octet-stream");
  int code = http.POST((uint8_t *)body, blen);
  if (resp && code > 0) {
    WiFiClient *stream = http.getStreamPtr();
    size_t got = 0;
    uint32_t t0 = millis();
    while (got < rmax && millis() - t0 < 8000) {
      int avail = stream->available();
      if (avail > 0) {
        int rd = stream->read(resp + got, rmax - got);
        if (rd > 0) { got += (size_t)rd; t0 = millis(); }
      } else if (!http.connected()) break;
      else delay(5);
    }
    *rlen = got;
  }
  http.end();
  return code;
}

static void krFailSession(const char *why) {
  krNoteFail(why);  // F10: counted + last-reason, not Serial-only
  Serial.printf("KR session FAILED: %s — aborting (committed key unchanged)\n", why);
  if (krSessRound) {
    // A failed per-node round session must NOT tear down the round:
    // the round context (window, other nodes) survives; this node
    // is marked FAILED and can be retried (spec §11).
    krRoundSet(krNodeSuffix, krNodeId, KR_RS_FAILED);
    krPhase = KR_PH_TEARDOWN;
    krPhaseMs = millis();
    return;
  }
  shepherd_kr::gwAbort(krCtx);
  krPhase = KR_PH_ABORT;
  krPhaseMs = millis();
}

// Mechanism steps, run from krPump when the STA link is up. Each
// step is one short HTTP exchange (blocking — see the F11 stall
// disclosure at the top of this section). Single sessions land in
// KR_PH_WINDOW (staged + window open); round rotation sessions go
// on to KR_PH_ROUND_COMMIT (the node is committed into the round
// immediately; the GATEWAY does not promote).
static void krRunSteps() {
  using namespace shepherd_kr;
  if (krSessMech == KR_MECH_KEM) {
    uint32_t target = krCtr + 1;
    uint8_t body[12];
    memcpy(body, krSelfId, 8);
    putU32(body + 8, target);
    uint8_t resp[812]; size_t rlen = 0;
    int code = krPost("/kr/begin", body, sizeof(body), resp, &rlen, sizeof(resp));
    if (code != 200 || rlen != sizeof(resp)) { krFailSession("begin"); return; }
    if (memcmp(resp, krNodeId, 8) != 0 || shepherd_kr::getU32(resp + 8) != target) {
      krFailSession("begin identity/counter mismatch"); return;
    }
    const uint8_t *ek = resp + 12;
    uint8_t ct[CT_LEN], auth[32];
    if (gwEncap(krCtx, pskKey, krCtr, krSelfId, krNodeId, target, ek,
                millis(), ct, auth) != KR_OK) { krFailSession("encap"); return; }
    uint8_t body2[CT_LEN + 32];
    memcpy(body2, ct, CT_LEN); memcpy(body2 + CT_LEN, auth, 32);
    uint8_t confirm[32]; size_t clen = 0;
    code = krPost("/kr/encap", body2, sizeof(body2), confirm, &clen, sizeof(confirm));
    if (code != 200 || clen != 32) { krFailSession("encap delivery"); return; }
    if (gwVerifyConfirm(krCtx, confirm) != KR_OK) { krFailSession("confirm"); return; }
    Serial.println("KR refresh: node CONFIRMED — dual-key window OPEN");
    krPhase = KR_PH_WINDOW;
    krPhaseMs = millis();
    return;
  }
  // KR_MECH_ROT (single session or one node of an open round)
  uint8_t wire[shepherd_psk::WIRE_LEN];
  uint32_t na = esp_random(), nb = esp_random();
  if (krSessRound) {
    uint8_t ctx[32];
    if (gwRoundMakeRotation(krCtx, pskKey, krNodeId, na, nb, wire, ctx) != KR_OK) {
      krFailSession("round make rotation"); return;
    }
    memset(ctx, 0, sizeof(ctx));  // recomputed on demand at commit
  } else {
    if (!krRotKeySet) {
      esp_fill_random(krRotKey, sizeof(krRotKey));  // Wi-Fi is up: HWRNG contract holds
    }
    if (gwMakeRotation(krCtx, pskKey, krCtr, krSelfId, krNodeId, krRotKey,
                       krCtr + 1, na, nb, millis(), wire) != KR_OK) {
      krFailSession("make rotation"); return;
    }
  }
  // F6: the request body is gwId[8] || wire[34] — the node's commit
  // context binds this gateway's identity and its own.
  uint8_t body[8 + shepherd_psk::WIRE_LEN];
  memcpy(body, krSelfId, 8);
  memcpy(body + 8, wire, sizeof(wire));
  uint8_t resp[6]; size_t rlen = 0;
  int code = krPost("/kr/rotate", body, sizeof(body), resp, &rlen, sizeof(resp));
  if (code != 200 || rlen != sizeof(resp)) { krFailSession("rotate delivery"); return; }
  // F7: the dual-key window opens ONLY after the node's reply —
  // staged key ID (2 B) + staged counter (4 B) — verifies against
  // what was pushed. A mismatch fails the session HERE, at the
  // rotate step, counted in krCtx.rotateMismatch + krFailCount.
  if (krSessRound) {
    if (!shepherd_kr::krReplyMatches(krCtx.stagedKey, krCtx.targetCounter,
                                     resp, shepherd_kr::getU32(resp + 2))) {
      krCtx.rotateMismatch++;
      krFailSession("rotate reply mismatch (round)");
      return;
    }
    krRoundSet(krNodeSuffix, krNodeId, KR_RS_STAGED);
    shepherd_kr::gwRoundNoteStaged(krCtx);
    Serial.println("KR round: node STAGED into the round — committing it now");
    krPhase = KR_PH_ROUND_COMMIT;
    krPhaseMs = millis();
    return;
  }
  if (gwConfirmRotation(krCtx, resp, shepherd_kr::getU32(resp + 2)) != KR_OK) {
    krFailSession("rotate reply mismatch");
    return;
  }
  Serial.println("KR rotation: node STAGED + reply verified — dual-key window OPEN");
  krPhase = KR_PH_WINDOW;
  krPhaseMs = millis();
}

static void krPump() {
  uint32_t now = millis();
  // F9: the APSTA reconfiguration deferred by handleKrStart (which
  // sent its HTTP response first) happens here, on the pump tick.
  if (krPendingWifi) {
    krPendingWifi = false;
    krWifiSessionBegin();
    krPhaseMs = now;
  }
  switch (krPhase) {
    case KR_PH_NONE: break;
    case KR_PH_CONNECT:
      if (WiFi.status() == WL_CONNECTED) { krPhase = KR_PH_STEP; krPhaseMs = now; }
      else if (now - krPhaseMs > KR_SESSION_STEP_TIMEOUT_MS) krFailSession("STA join timeout");
      break;
    case KR_PH_STEP: krRunSteps(); break;
    case KR_PH_WINDOW:
      if (shepherd_kr::gwExpired(krCtx, now, KR_STAGE_TIMEOUT_MS)) {
        Serial.println("KR window EXPIRED — reverting (committed key unchanged)");
        krNoteFail("window expired");
        krPhase = KR_PH_ABORT; krPhaseMs = now;
      }
      break;
    case KR_PH_COMMIT: {
      uint8_t cauth[32];
      if (shepherd_kr::gwMakeCommitAuth(krCtx, cauth) != shepherd_kr::KR_OK) {
        krFailSession("commit auth"); break;
      }
      uint8_t resp[1]; size_t rlen = 0;
      int code = krPost("/kr/commit", cauth, 32, resp, &rlen, sizeof(resp));
      if (code == 200) {
        uint8_t nk[16]; uint32_t nc = 0;
        if (shepherd_kr::gwPromote(krCtx, nk, &nc) == shepherd_kr::KR_OK) {
          krPersistPromote(nk, nc);
          // F1(b), ACK path: rebase the node's freshness entry.
          uint16_t sfx = (uint16_t)strtoul(krNodeSuffix, NULL, 16);
          freshMarkRebased(sfx);
        }
        krPhase = KR_PH_TEARDOWN;
      } else {
        // F4: the POST failed or timed out AFTER possible delivery
        // — the node may have committed and its 200 was lost. Do
        // NOT abort the context: stay CONFIRMED with the window
        // open, marked awaiting frame confirmation; the first
        // staged-key frame still promotes (handlePacket). Only an
        // operator abort or the window expiry tears this down.
        shepherd_kr::gwNoteCommitAckLost(krCtx);
        krNoteFail("commit ACK lost — awaiting frame confirmation (session stays open)");
        Serial.println("KR commit: ACK lost — session held in-window, awaiting frame confirmation");
        krPhase = KR_PH_WINDOW;
        krPhaseMs = now;
      }
      break;
    }
    case KR_PH_ROUND_COMMIT: {
      uint8_t cauth[32];
      if (shepherd_kr::gwRoundCommitAuth(krCtx, krNodeId, cauth) != shepherd_kr::KR_OK) {
        krFailSession("round commit auth"); break;
      }
      uint8_t resp[1]; size_t rlen = 0;
      int code = krPost("/kr/commit", cauth, 32, resp, &rlen, sizeof(resp));
      if (code == 200) {
        krRoundSet(krNodeSuffix, krNodeId, KR_RS_COMMITTED);
        shepherd_kr::gwRoundNoteCommitted(krCtx);
        Serial.printf("KR round: node %s COMMITTED into the round (gateway NOT promoted)\n",
                      krNodeSuffix);
      } else {
        // Same lost-ACK logic as F4, per node: the node may have
        // committed. Mark AWAITING-FRAME — a staged-key frame from
        // it flips the entry to COMMITTED in handlePacket — and
        // carry on with the round.
        krRoundSet(krNodeSuffix, krNodeId, KR_RS_AWAITING);
        krNoteFail("round commit ACK lost — node awaiting frame confirmation");
      }
      krPhase = KR_PH_TEARDOWN;  // Wi-Fi session ends; the ROUND stays open
      break;
    }
    case KR_PH_ABORT: {
      // F5: authenticate the abort with the staged-key proof (the
      // node verifies it like a commit proof). With no staged
      // context locally, send an empty body — the node's
      // no-context abort is a no-op success.
      uint8_t proof[32]; size_t plen = 0;
      if (krCtx.state != shepherd_kr::KR_IDLE &&
          shepherd_kr::gwMakeAbortAuth(krCtx, pskKey, proof) == shepherd_kr::KR_OK)
        plen = 32;
      uint8_t resp[1]; size_t rlen = 0;
      krPost("/kr/abort", proof, plen, resp, &rlen, sizeof(resp));  // best effort
      memset(proof, 0, sizeof(proof));
      shepherd_kr::gwAbort(krCtx);
      krWifiSessionEnd();
      break;
    }
    case KR_PH_TEARDOWN: krWifiSessionEnd(); break;
  }
}

// ---- key-refresh status-page controls ----
static bool parseSuffix4(const String &s, char out[5]) {
  if (s.length() != 4) return false;
  for (int i = 0; i < 4; i++) {
    char c = s[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
      return false;
    out[i] = (char)toupper(c);
  }
  out[4] = 0;
  return true;
}
void handleKrStart() {
  // F8: uniform !pskSet -> 403 guard on every KR endpoint.
  if (!pskSet) {
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Key refresh requires a committed PSK. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
#ifdef LORA_GW_STA
  // F12: in the STA variant there is no gateway AP to move, and
  // krWifiSessionBegin would softAP with an empty SSID — session
  // initiation is compile-time disabled here instead (spec §13).
  server.send(403, "text/html",
    "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
    "Key refresh is DISABLED in the LORA_GW_STA build variant: sessions "
    "need the gateway AP (APSTA), which this variant does not host. "
    "<a href=/ style='color:#a855f7'>Back</a></body></html>");
  return;
#endif
  if (krPhase != KR_PH_NONE) {
    server.send(409, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Another key-refresh session is already running. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  char suffix[5];
  if (!parseSuffix4(server.arg("suffix"), suffix)) {
    server.send(400, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Node suffix must be 4 hex characters. <a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  String mech = server.arg("mech");
  if (krCtx.roundOpen) {
    // F2: sessions and rounds are mutually exclusive — while a
    // round is open, per-node sessions JOIN the round and are
    // rotation-only (Mechanism A is per-link; spec §11/§13).
    if (mech == "kem") {
      server.send(409, "text/html",
        "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
        "A fleet round is open: ML-KEM refresh is unavailable until the "
        "round is promoted or aborted. <a href=/ style='color:#a855f7'>Back</a></body></html>");
      return;
    }
    krSessRound = true;
  } else {
    if (krCtx.state != shepherd_kr::KR_IDLE) {
      server.send(409, "text/html",
        "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
        "A key-refresh context is already staged. "
        "<a href=/ style='color:#a855f7'>Back</a></body></html>");
      return;
    }
    krSessRound = false;
    String nk = server.arg("newkey"); nk.trim();
    memset(krRotKey, 0, sizeof(krRotKey));
    krRotKeySet = false;
    if (mech == "rot" && nk.length() > 0) {
      if (!parseHexKey(nk, krRotKey)) {
        server.send(400, "text/html",
          "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
          "New key must be 32 hex characters (or blank for gateway-generated). "
          "<a href=/ style='color:#a855f7'>Back</a></body></html>");
        return;
      }
      krRotKeySet = true;
    }
  }
  snprintf(krNodeSuffix, sizeof(krNodeSuffix), "%s", suffix);
  memcpy(krNodeId, "SLN-", 4);
  memcpy(krNodeId + 4, suffix, 4);  // 8-byte identity field, no NUL
  String pass = server.arg("nappass");
  pass.toCharArray(krNodePass, sizeof(krNodePass));
  krSessMech = krSessRound ? shepherd_kr::KR_MECH_ROT
             : (mech == "rot") ? shepherd_kr::KR_MECH_ROT : shepherd_kr::KR_MECH_KEM;
  krPhase = KR_PH_CONNECT;
  krPhaseMs = millis();
  // F9: send the HTTP response BEFORE any AP reconfiguration — the
  // APSTA switch is deferred to the next krPump tick (krPendingWifi).
  // Previously the AP moved first and this response raced the
  // reconfiguration it announced. Clients already associated with
  // the gateway AP (including the Shepherd PC) must re-associate /
  // DHCP-renew onto 192.168.6.x mid-session (spec §2).
  krPendingWifi = true;
  server.send(200, "text/html",
    "<html><body style='background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px'>"
    "Key-refresh session started. <b>During the session this page is at "
    "http://192.168.6.1</b> (the gateway AP moved); it returns to "
    "192.168.4.1 when the session ends. Your device must re-associate "
    "to the gateway AP and renew DHCP onto 192.168.6.x to follow it. "
    "Watch the Key refresh card there, then Commit or Abort. "
    "<a href='http://192.168.6.1/' "
    "style='color:#a855f7'>Open the session page</a></body></html>");
}
void handleKrCommit() {
  if (!pskSet) {  // F8 uniform guard
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Key refresh requires a committed PSK. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  if (krPhase == KR_PH_WINDOW) { krPhase = KR_PH_COMMIT; krPhaseMs = millis(); }
  server.sendHeader("Location", "/", true);
  server.send(302, "text/plain", "");
}
void handleKrAbort() {
  if (!pskSet) {  // F8 uniform guard
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Key refresh requires a committed PSK. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  if (krPhase != KR_PH_NONE) { krPhase = KR_PH_ABORT; krPhaseMs = millis(); }
  server.sendHeader("Location", "/", true);
  server.send(302, "text/plain", "");
}

// ---- F2: fleet round controls (Mechanism B) ----
void handleKrRoundStart() {
  if (!pskSet) {  // F8 uniform guard
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Key refresh requires a committed PSK. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
#ifdef LORA_GW_STA
  server.send(403, "text/html",  // F12: disabled in the STA variant
    "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
    "Key refresh is DISABLED in the LORA_GW_STA build variant. "
    "<a href=/ style='color:#a855f7'>Back</a></body></html>");
  return;
#endif
  if (krPhase != KR_PH_NONE || krCtx.state != shepherd_kr::KR_IDLE || krCtx.roundOpen) {
    server.send(409, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "A session or round is already active. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  uint8_t roundKey[16];
  String nk = server.arg("newkey"); nk.trim();
  if (nk.length() > 0) {
    if (!parseHexKey(nk, roundKey)) {
      server.send(400, "text/html",
        "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
        "Round key must be 32 hex characters (or blank for gateway-generated). "
        "<a href=/ style='color:#a855f7'>Back</a></body></html>");
      return;
    }
  } else {
    esp_fill_random(roundKey, sizeof(roundKey));  // Wi-Fi is up: HWRNG contract holds
  }
  uint32_t target = krCtr + 1;  // ONE round key at ONE target counter
  shepherd_kr::KrResult r =
      shepherd_kr::gwRoundBegin(krCtx, krCtr, krSelfId, roundKey, target, millis());
  memset(roundKey, 0, sizeof(roundKey));  // the ctx holds the only copy now
  if (r != shepherd_kr::KR_OK) {
    krNoteFail("round begin refused");
    server.send(409, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Round could not be opened. <a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  for (int i = 0; i < 16; i++) krRoundNodes[i].used = false;
  Serial.printf("KR ROUND OPEN: target ctr=%lu — stage+commit nodes, then Promote\n",
                (unsigned long)target);
  server.sendHeader("Location", "/", true);
  server.send(302, "text/plain", "");
}
void handleKrRoundPromote() {
  if (!pskSet) {  // F8 uniform guard
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Key refresh requires a committed PSK. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  if (krCtx.roundOpen && krPhase == KR_PH_NONE) {
    uint8_t nk[16]; uint32_t nc = 0;
    if (shepherd_kr::gwPromote(krCtx, nk, &nc) == shepherd_kr::KR_OK) {
      krPersistPromote(nk, nc);
      // F1(b): every round-committed suffix keeps its rebased guard.
      for (int i = 0; i < 16; i++)
        if (krRoundNodes[i].used && krRoundNodes[i].status == KR_RS_COMMITTED)
          freshMarkRebased((uint16_t)strtoul(krRoundNodes[i].suffix, NULL, 16));
      for (int i = 0; i < 16; i++) krRoundNodes[i].used = false;
      Serial.println("KR ROUND PROMOTED: gateway joined the round key");
    }
  }
  server.sendHeader("Location", "/", true);
  server.send(302, "text/plain", "");
}
void handleKrRoundAbort() {
  if (!pskSet) {  // F8 uniform guard
    server.send(403, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Key refresh requires a committed PSK. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  if (!krCtx.roundOpen) {
    server.sendHeader("Location", "/", true);
    server.send(302, "text/plain", "");
    return;
  }
  if (krPhase != KR_PH_NONE) {
    server.send(409, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Finish or abort the active node session before aborting the round. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  // Chosen semantics (spec §11): abort is permitted only BEFORE any
  // node has committed into the round. After that, a gateway-side
  // abort would strand the committed nodes on a key the gateway no
  // longer holds — only Promote (or per-node recovery) remains.
  if (!shepherd_kr::gwRoundAbortPermitted(krCtx)) {
    server.send(409, "text/html",
      "<html><body style='background:#111;color:#f87171;font-family:sans-serif;padding:24px'>"
      "Round abort REFUSED: a node has already committed into this round. "
      "Promote the round, or recover the diverged nodes individually "
      "(spec §11). The round was NOT aborted. "
      "<a href=/ style='color:#a855f7'>Back</a></body></html>");
    return;
  }
  // Gateway-side scrub is immediate. Nodes that STAGED but did not
  // commit hold a RAM-only candidate that can never be committed
  // now (the gateway no longer stages its key) and expires within
  // 120 s on its own clock (spec §11).
  shepherd_kr::gwAbort(krCtx);
  for (int i = 0; i < 16; i++) krRoundNodes[i].used = false;
  Serial.println("KR ROUND ABORTED (no node had committed) — gateway scrubbed");
  server.sendHeader("Location", "/", true);
  server.send(302, "text/plain", "");
}

void handleRoot() {
  // F13 stack fix: this handler previously held TWO large locals at
  // once — html[6144] + rows[1600] = 7744 B — on the ~8 KB Arduino
  // loop-task stack, before any snprintf/libc usage. The node rows
  // are now rendered DIRECTLY into the single html buffer: peak
  // locals 6144 B (was 7744 B, -1600 B). The node sketch's
  // handleRoot was already single-buffer (html[4600]).
  char html[6144];
  size_t o = 0;
  o += snprintf(html + o, sizeof(html) - o,
    "<html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<meta http-equiv=refresh content=10>"
    "<style>body{background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px}"
    "h1{color:#a855f7}.card{background:#1c1c22;padding:16px;border-radius:12px;margin:12px 0}"
    ".warn{color:#f87171;font-weight:bold}"
    "input{background:#222;color:#eee;border:1px solid #444;padding:6px;width:280px}"
    "button{background:#7c3aed;color:#fff;border:0;padding:6px 14px;border-radius:6px}"
    "table{border-collapse:collapse}td,th{padding:6px 10px;border:1px solid #333;text-align:left}</style>"
    "</head><body><h1>Shepherd LoRa Gateway %s</h1>"
    "<div class=card>LoRa %.1f MHz RX-only, star topology<br>"
    "Uptime %lu s &nbsp; Packets ok %lu &nbsp; dropped %lu</div>"
    "<div class=card><table><tr><th>Node</th><th>Last heard</th><th>fps</th>"
    "<th>Events</th><th>Lat,Lon</th></tr>",
    gwId, LORA_FREQ_MHZ, (unsigned long)((millis() - bootMs) / 1000),
    (unsigned long)rxOk,
    (unsigned long)(rxBad + rxAuthFail + rxReplay + rxNoKey + rxNoState));
  {
    uint32_t now = millis();
    for (int i = 0; i < MAX_NODES; i++) {
      if (!nodes[i].used) continue;
      char nid[12]; snprintf(nid, sizeof(nid), "SLN-%04X", nodes[i].suffix);
      o += snprintf(html + o, sizeof(html) - o,
        "<tr><td>%s</td><td>%lus ago</td><td>%u</td><td>%u</td>"
        "<td>%.4f,%.4f%s</td></tr>",
        nid, (unsigned long)((now - nodes[i].lastHeard) / 1000),
        nodes[i].fps, nodes[i].evCount, nodes[i].lat, nodes[i].lon,
        (nodes[i].flags & 0x01) ? "" : " (no fix)");
      if (o >= sizeof(html) - 220) break;  // keep room for the cards below
    }
  }
  o += snprintf(html + o, sizeof(html) - o,
    "</table></div>"
    "<div class=card>Join this AP from the Shepherd device.<br>"
    "Decoded packets re-emitted on UDP %d as standard Shepherd JSON.</div>",
    BEACON_PORT);
  if (apPassDefault) {
    o += snprintf(html + o, sizeof(html) - o,
      "<div class=card>AP password: <span class=warn>public DEFAULT still "
      "in use</span> — change it below, especially before setting the "
      "LoRa PSK.<br>"
      "<form method=post action=/appass><input type=password name=ap "
      "maxlength=63 placeholder='new AP password (8-63 chars)'> "
      "<button>Save AP password</button></form>"
      "Takes effect on reboot — you will need to rejoin the AP with the "
      "new password.</div>");
  } else {
    o += snprintf(html + o, sizeof(html) - o,
      "<div class=card>AP password: <b>custom set</b> (never shown).<br>"
      "<form method=post action=/appass><input type=password name=ap "
      "maxlength=63 placeholder='new AP password (8-63 chars)'> "
      "<button>Replace AP password</button></form>"
      "Takes effect on reboot — you will need to rejoin the AP with the "
      "new password.</div>");
  }
  if (pskSet) {
    o += snprintf(html + o, sizeof(html) - o,
      "<div class=card>LoRa security: PSK <b>SET</b> (key ID %s) — v2 packets "
      "decrypted after the schema gate.<br>"
      "Drop breakdown: malformed %lu &nbsp; auth failures %lu &nbsp; replay "
      "drops %lu &nbsp; no-key %lu &nbsp; no-state %lu &nbsp; clear refusals %lu<br>"
      "Legacy v1 heard %lu<br>"
      "<form method=post action=/psk><input name=k maxlength=32 "
      "placeholder='new 32-hex PSK'> <button>Replace PSK</button></form>"
      "<form method=post action=/pskclear><input name=confirm maxlength=4 "
      "placeholder='type key ID to confirm'> <button>Clear PSK</button></form></div>",
      pskKeyId, (unsigned long)rxBad, (unsigned long)rxAuthFail,
      (unsigned long)rxReplay, (unsigned long)rxNoKey,
      (unsigned long)rxNoState, (unsigned long)pskClearRefused,
      (unsigned long)rxLegacy);
  } else {
    o += snprintf(html + o, sizeof(html) - o,
      "<div class=card><span class=warn>LoRa PSK NOT SET — encrypted (v2) node "
      "packets are DROPPED at this gateway (%lu dropped so far). Legacy v1 is "
      "still decoded (%lu heard).</span><br>"
      "Set the deployment key here FIRST, then the same key on each node "
      "(32 hex chars):<br>"
      "<form method=post action=/psk><input name=k maxlength=32 "
      "placeholder='32 hex characters'> <button>Save PSK</button></form>"
      "Takes effect on reboot.</div>",
      (unsigned long)rxNoKey, (unsigned long)rxLegacy);
  }
  if (pskSet) {
#ifdef LORA_GW_STA
    // F12: session initiation is compile-time disabled in this variant.
    o += snprintf(html + o, sizeof(html) - o,
      "<div class=card>Key refresh: <span class=warn>DISABLED in the "
      "LORA_GW_STA build variant</span> — sessions need the gateway AP "
      "(APSTA), which this variant does not host.</div>");
#else
    char stagedId[5] = "----";
    if (krCtx.state != shepherd_kr::KR_IDLE)
      shepherd_kr::keyIdHex(krCtx.stagedKey, stagedId);
    const char *stName = krCtx.state == shepherd_kr::KR_CONFIRMED ? "CONFIRMED"
                       : krCtx.state == shepherd_kr::KR_STAGED ? "STAGED" : "IDLE";
    const char *phName = krPhase == KR_PH_NONE ? "no session"
                       : krPhase == KR_PH_WINDOW ? "WINDOW OPEN (dual-key)"
                       : krPhase == KR_PH_CONNECT ? "connecting" : "in session";
    o += snprintf(html + o, sizeof(html) - o,
      "<div class=card>Key refresh: state <b>%s</b> &nbsp; session %s &nbsp; "
      "committed key_counter %lu &nbsp; staged key ID %s<br>"
      "Completed: ML-KEM refresh %lu &nbsp; rotation %lu &nbsp; dual-key "
      "frames %lu<br>"
      "Refusals: auth %lu &nbsp; counter %lu &nbsp; state %lu &nbsp; failures %lu<br>"
      "Session failures: %lu &nbsp; rotate-reply mismatches: %lu &nbsp; "
      "commit ACKs lost: %lu<br>%s%s%s",
      stName, phName, (unsigned long)krCtr, stagedId,
      (unsigned long)krCtx.okKem, (unsigned long)krCtx.okRot,
      (unsigned long)krCtx.dualKeyFrames,
      (unsigned long)krCtx.refuseAuth, (unsigned long)krCtx.refuseCounter,
      (unsigned long)krCtx.refuseState, (unsigned long)krCtx.failures,
      (unsigned long)krFailCount, (unsigned long)krCtx.rotateMismatch,
      (unsigned long)krCtx.commitAckLost,
      krLastFail[0] ? "Last failure: " : "",
      krLastFail[0] ? krLastFail : "",
      krCtx.awaitingFrame ? "<br><b>Awaiting frame confirmation</b> — a "
      "commit ACK was lost; the window stays open until a new-key frame "
      "promotes, you Abort, or the window expires." : "");
    if (krPersistFault) {
      o += snprintf(html + o, sizeof(html) - o,
        "<br><span class=warn>KR promote NVS FAULT (%lu) — this gateway "
        "runs the promoted key from RAM only; a reboot reverts it to "
        "the previous key. Fix the flash fault and re-run/repair "
        "(spec §9).</span>", (unsigned long)krPersistFailCount);
    }
    if (krCtx.roundOpen) {
      char roundId[5];
      shepherd_kr::keyIdHex(krCtx.stagedKey, roundId);
      o += snprintf(html + o, sizeof(html) - o,
        "<br><b>FLEET ROUND OPEN</b> — round key ID %s &nbsp; target "
        "key_counter %lu &nbsp; nodes staged %lu &nbsp; committed %lu<br>"
        "Stage+commit each node with the session form below (rotation, "
        "round key). The gateway promotes ONLY when you press Promote. "
        "Abort is available only until the first node commits.<br>",
        roundId, (unsigned long)krCtx.targetCounter,
        (unsigned long)krCtx.roundStaged, (unsigned long)krCtx.roundCommitted);
      for (int i = 0; i < 16; i++) {
        if (!krRoundNodes[i].used) continue;
        o += snprintf(html + o, sizeof(html) - o, "SLN-%s: %s<br>",
                      krRoundNodes[i].suffix,
                      krRoundStatusName(krRoundNodes[i].status));
        if (o >= sizeof(html) - 260) break;
      }
      if (krPhase == KR_PH_NONE) {
        o += snprintf(html + o, sizeof(html) - o,
          "<form method=post action=/krroundpromote style='display:inline'>"
          "<button>Promote round (gateway joins the round key)</button></form> "
          "<form method=post action=/krroundabort style='display:inline'>"
          "<button>Abort round</button></form>");
      }
    } else if (krPhase == KR_PH_NONE) {
      o += snprintf(html + o, sizeof(html) - o,
        "<br><form method=post action=/krroundstart>"
        "<input name=newkey maxlength=32 placeholder='round key 32 hex (optional)'> "
        "<button>Open fleet round (Mechanism B)</button></form>"
        "A round stages ONE new key on many nodes at the next counter; "
        "the gateway promotes last, on your command.");
    }
    if (krPhase == KR_PH_NONE) {
      o += snprintf(html + o, sizeof(html) - o,
        "<form method=post action=/krstart>"
        "<input name=suffix maxlength=4 placeholder='node suffix (4 hex)'> "
        "<input type=password name=nappass maxlength=63 placeholder='node AP password'> "
        "<input name=newkey maxlength=32 placeholder='rotation key 32 hex (optional)'> "
        "<button name=mech value=kem>Start ML-KEM refresh</button> "
        "<button name=mech value=rot>Push rotation</button></form>"
        "Starting a session moves this page to 192.168.6.1 until it ends; "
        "your device must re-associate and renew DHCP to follow it.</div>");
    } else if (krPhase == KR_PH_WINDOW) {
      o += snprintf(html + o, sizeof(html) - o,
        "<form method=post action=/krcommit style='display:inline'>"
        "<button>Commit</button></form> "
        "<form method=post action=/krabort style='display:inline'>"
        "<button>Abort</button></form></div>");
    } else {
      o += snprintf(html + o, sizeof(html) - o,
        "<form method=post action=/krabort style='display:inline'>"
        "<button>Abort session</button></form></div>");
    }
#endif
  }
  snprintf(html + o, sizeof(html) - o, "</body></html>");
  server.send(200, "text/html", html);
}
void setup() {
  Serial.begin(115200);
  bootMs = millis();
  prefs.begin("slg", false);

  String gid = prefs.getString("gw_id", "");
  if (gid.length() == 0) {
    uint8_t mac[6]; esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    char tmp[16]; snprintf(tmp, sizeof(tmp), "SLG-%02X%02X", mac[4], mac[5]);
    gid = tmp; prefs.putString("gw_id", gid);
  }
  gid.toCharArray(gwId, sizeof(gwId));
  memcpy(krSelfId, gwId, 8);
  krCtr = prefs.getUInt("kr_ctr", 0);
  String pass = prefs.getString("ap_pass", "shepherd-field");
  pass.toCharArray(gwApPass, sizeof(gwApPass));
  apPassDefault = (pass == "shepherd-field");
  if (apPassDefault)
    Serial.println("!! AP password is the public DEFAULT — change it on the status page.");

  // Codec v2 PSK (same key as the nodes; set on the status page).
  String pskHex = prefs.getString("psk_hex", "");
  if (pskHex.length() > 0 && parseHexKey(pskHex, pskKey)) {
    pskSet = true; computeKeyId();
  } else if (pskHex.length() > 0) {
    Serial.println("!! stored psk_hex is malformed (need 32 hex chars) — ignoring it");
  }

  // Codec v2 freshness state (NVS-persisted; see freshPersist) —
  // restore the per-node high-water marks so a reboot does not reopen
  // the replay window.
  freshRestore();
  {
    int restored = 0;
    for (int i = 0; i < MAX_FRESH; i++) if (freshTable[i].used) restored++;
    if (restored)
      Serial.printf("PSK freshness state restored from NVS: %d node(s)\n", restored);
  }

#ifdef LORA_GW_STA
  WiFi.mode(WIFI_STA);
  WiFi.begin(LORA_GW_STA_SSID, LORA_GW_STA_PASS);
  Serial.print("Joining STA");
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) {
    delay(500); Serial.print(".");
  }
  Serial.println(WiFi.status() == WL_CONNECTED ? " connected" : " FAILED");
#else
  WiFi.mode(WIFI_AP);
  char ssid[28]; snprintf(ssid, sizeof(ssid), "Shepherd-LoRa-%s", gwId + 4);
  snprintf(gwSsid, sizeof(gwSsid), "%s", ssid);
  WiFi.softAP(ssid, pass.c_str(), WIFI_CH);
  Serial.printf("AP %s up at %s\n", ssid, WiFi.softAPIP().toString().c_str());
#endif

  SPI.begin(18, 19, 23);
  int st = radio.begin(LORA_FREQ_MHZ, 125.0, 7, 5, 0x12, 10, 8);
  radio.setCRC(true);
  if (st == RADIOLIB_ERR_NONE) {
    radio.setDio0Action(onRx, RISING);
    radio.startReceive();
    Serial.printf("LoRa RX up: %.1f MHz SF7/125kHz\n", LORA_FREQ_MHZ);
  } else {
    Serial.printf("LoRa FAILED: %d — check wiring\n", st);
  }

  if (MDNS.begin(gwId)) MDNS.addService("shepherd-node", "udp", BEACON_PORT);

  udp.begin(BEACON_PORT);
  server.on("/", handleRoot);
  server.on("/psk", HTTP_POST, handlePskSave);
  server.on("/pskclear", HTTP_POST, handlePskClear);
  server.on("/appass", HTTP_POST, handleApPassSave);
  server.on("/krstart", HTTP_POST, handleKrStart);
  server.on("/krcommit", HTTP_POST, handleKrCommit);
  server.on("/krabort", HTTP_POST, handleKrAbort);
  server.on("/krroundstart", HTTP_POST, handleKrRoundStart);
  server.on("/krroundpromote", HTTP_POST, handleKrRoundPromote);
  server.on("/krroundabort", HTTP_POST, handleKrRoundAbort);
  server.begin();
  if (pskSet) {
    Serial.printf("LoRa PSK SET (key ID %s) — codec v2 decryption on\n", pskKeyId);
  } else {
    Serial.println("!! LoRa PSK NOT SET — v2 (encrypted) packets will be DROPPED !!");
    Serial.println("!! Set a deployment PSK on the status page (LoRa security card).");
  }
  Serial.printf("Shepherd LoRa gateway %s ready\n", gwId);
}

void loop() {
  static uint32_t lastGwBeacon = 0;
  uint32_t now = millis();

  server.handleClient();
  krPump();

  if (rxFlag) {
    rxFlag = false;
    size_t len = radio.getPacketLength();
    uint8_t buf[64];
    if (len > sizeof(buf)) len = sizeof(buf);
    int st = radio.readData(buf, len);
    if (st == RADIOLIB_ERR_NONE) handlePacket(buf, len, now);
    else rxBad++;
    radio.startReceive();
  }

  if (now - lastGwBeacon >= GW_BEACON_MS) {
    lastGwBeacon = now;
    sendGwBeacon();
  }
}
