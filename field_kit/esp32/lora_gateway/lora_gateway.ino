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
uint32_t bootMs = 0;
uint32_t rxOk = 0, rxBad = 0;

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
};
FreshEntry freshTable[MAX_FRESH];

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
    if (!shepherd_psk::unwrap(pskKey, p, plain)) {  // wrong PSK or tampered
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
    // node's NVS was wiped / reflashed); the spec states this
    // acceptance and its replay consequence honestly rather than
    // pretending it is narrow.
    uint32_t bc = shepherd_psk::getU32(p + shepherd_psk::NONCE_OFF);
    uint32_t fc = shepherd_psk::getU32(p + shepherd_psk::NONCE_OFF + 4);
    uint16_t suffix = shepherd_psk::getU16(v1 + 2);
    int fi = freshFind(suffix);
    if (fi >= 0) {
      FreshEntry &fe = freshTable[fi];
      if (bc == fe.bootCtr && fc <= fe.frameCtr) {
        rxReplay++;
        return;                            // stale / replayed — drop
      }
      if (bc < fe.bootCtr) {
        Serial.printf("PSK ctr resync SLN-%04X (boot %lu < %lu) — state rewound\n",
                      suffix, (unsigned long)bc, (unsigned long)fe.bootCtr);
      }
      fe.bootCtr = bc; fe.frameCtr = fc;
    } else {
      fi = freshAlloc();
      if (fi < 0) { rxNoState++; return; }   // fail closed — never decode unverified
      freshTable[fi].suffix = suffix;
      freshTable[fi].bootCtr = bc;
      freshTable[fi].frameCtr = fc;
      freshTable[fi].used = true;
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

void handleRoot() {
  char rows[1600]; rows[0] = 0; size_t ro = 0;
  uint32_t now = millis();
  for (int i = 0; i < MAX_NODES && ro < sizeof(rows) - 120; i++) {
    if (!nodes[i].used) continue;
    char nid[12]; snprintf(nid, sizeof(nid), "SLN-%04X", nodes[i].suffix);
    ro += snprintf(rows + ro, sizeof(rows) - ro,
      "<tr><td>%s</td><td>%lus ago</td><td>%u</td><td>%u</td>"
      "<td>%.4f,%.4f%s</td></tr>",
      nid, (unsigned long)((now - nodes[i].lastHeard) / 1000),
      nodes[i].fps, nodes[i].evCount, nodes[i].lat, nodes[i].lon,
      (nodes[i].flags & 0x01) ? "" : " (no fix)");
  }
  char html[3840];
  snprintf(html, sizeof(html),
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
    "<th>Events</th><th>Lat,Lon</th></tr>%s</table></div>"
    "<div class=card>Join this AP from the Shepherd device.<br>"
    "Decoded packets re-emitted on UDP %d as standard Shepherd JSON.</div>",
    gwId, LORA_FREQ_MHZ, (unsigned long)((millis() - bootMs) / 1000),
    (unsigned long)rxOk,
    (unsigned long)(rxBad + rxAuthFail + rxReplay + rxNoKey + rxNoState),
    rows[0] ? rows : "", BEACON_PORT);
  if (!rows[0]) {
    // no nodes yet — the %s above printed empty; table shows headers only
  }
  size_t o = strlen(html);
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
    snprintf(html + o, sizeof(html) - o,
      "<div class=card>LoRa security: PSK <b>SET</b> (key ID %s) — v2 packets "
      "decrypted after the schema gate.<br>"
      "Drop breakdown: malformed %lu &nbsp; auth failures %lu &nbsp; replay "
      "drops %lu &nbsp; no-key %lu &nbsp; no-state %lu &nbsp; clear refusals %lu<br>"
      "Legacy v1 heard %lu<br>"
      "<form method=post action=/psk><input name=k maxlength=32 "
      "placeholder='new 32-hex PSK'> <button>Replace PSK</button></form>"
      "<form method=post action=/pskclear><input name=confirm maxlength=4 "
      "placeholder='type key ID to confirm'> <button>Clear PSK</button></form></div>"
      "</body></html>",
      pskKeyId, (unsigned long)rxBad, (unsigned long)rxAuthFail,
      (unsigned long)rxReplay, (unsigned long)rxNoKey,
      (unsigned long)rxNoState, (unsigned long)pskClearRefused,
      (unsigned long)rxLegacy);
  } else {
    snprintf(html + o, sizeof(html) - o,
      "<div class=card><span class=warn>LoRa PSK NOT SET — encrypted (v2) node "
      "packets are DROPPED at this gateway (%lu dropped so far). Legacy v1 is "
      "still decoded (%lu heard).</span><br>"
      "Set the deployment key here FIRST, then the same key on each node "
      "(32 hex chars):<br>"
      "<form method=post action=/psk><input name=k maxlength=32 "
      "placeholder='32 hex characters'> <button>Save PSK</button></form>"
      "Takes effect on reboot.</div></body></html>",
      (unsigned long)rxNoKey, (unsigned long)rxLegacy);
  }
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
  String pass = prefs.getString("ap_pass", "shepherd-field");
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
