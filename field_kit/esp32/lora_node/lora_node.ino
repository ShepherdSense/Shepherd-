/*
 * Shepherd LoRa Node (SLN-XXXX) — ESP32 + SX1276
 *
 * Flash once. Afterwards every USB plug-in is just power: the node boots,
 * hosts its own WiFi AP (for a local status page), sniffs WiFi RSSI in
 * promiscuous mode through a rolling-median/MAD edge tripwire (same approach
 * as the SHN node — baseline hold during events), and reports every
 * detection as a compact BINARY packet over LoRa to an SLG gateway.
 *
 * LoRa is the BACKHAUL, not the sensor. Nothing about LoRa is sensed.
 * The node does NOT mesh LoRa-to-LoRa: star topology, node -> gateway only,
 * gateway is receive-only on LoRa. The node also emits the standard
 * Shepherd JSON beacons/events on its own AP's UDP broadcast 49160, so a
 * PC joined directly to the node sees it exactly like an SHN node
 * (the gateway re-emits the same JSON from LoRa, byte-compatible).
 *
 * Wiring (SX1276 module, defaults — change below if your board differs):
 *   VSPI: SCK=18 MISO=19 MOSI=23  (ESP32 default VSPI; SPI.begin(18,19,23))
 *   LoRa: NSS=5, DIO0=26, DIO1=33, RESET=14, BUSY unused
 *   GPS (optional, always compiled, silent when absent):
 *     Serial1 RX=25 <- GPS_TX (9600 NMEA). The GPS TX pin (ESP->GPS) is
 *     left unconnected (-1) because GPIO26 is taken by LoRa DIO0 — the
 *     GPS module needs no configuration commands, NMEA RX + PPS is enough.
 *     PPS=27 (rising edge) disciplines the microsecond event clock.
 *
 * Region: pick ONE of these (default US915):
 */
//#define LORA_REGION_EU868   // 868 MHz — EU 1% duty-cycle rules apply
//#define LORA_REGION_AS433   // 433 MHz — check local rules before use
#define LORA_REGION_US915     // 915 MHz (default)

/*
 * Shepherd LoRa codec v1 (binary, big-endian). Documented byte by byte.
 *
 * BEACON packet — 22 bytes (0x01):
 *   [0]    schema version = 1
 *   [1]    packet type = 0x01 (beacon)
 *   [2-3]  node suffix uint16 (the XXXX in SLN-XXXX, e.g. "A3F1"->0xA3F1)
 *   [4-7]  uptime_s uint32
 *   [8-9]  event count since boot uint16
 *   [10-13] lat * 1e6 int32 (0 when no GPS fix)
 *   [14-17] lon * 1e6 int32 (0 when no GPS fix)
 *   [18]   flags: bit0 = GPS fix, bit1 = PPS locked, bits 2-7 reserved 0
 *   [19]   tripwire samples/sec uint8 (fps in the JSON beacon)
 *   [20-21] battery mV uint16 (0 = not measured)
 *
 * EVENT packet — 22 bytes (0x02):
 *   [0]    schema version = 1
 *   [1]    packet type = 0x02 (event)
 *   [2-3]  node suffix uint16
 *   [4-7]  t0 uint32 (node seconds at event start — the JSON "t0")
 *   [8-15] t_us uint64 (microsecond node clock at event start,
 *          PPS-disciplined when GPS present, micros() free-run otherwise)
 *   [16-17] dur_s * 100 uint16 (max 655.35 s; longer clamps at 0xFFFF)
 *   [18]   depth_db * 10 uint8 (max 25.5 dB; deeper clamps at 0xFF)
 *   [19]   class enum: 0=UNKNOWN, 1=PASSING, 2=LINGERING
 *   [20]   conf * 100 uint8 (max 100)
 *   [21]   sensor enum: 0=wifi (1..7 reserved)
 *
 * A second schema version will bump byte [0]; the gateway drops any
 * packet whose schema it does not understand instead of mis-decoding it.
 *
 * Codec v2 — PSK wrap (schema byte = 2), full spec in
 * docs/lora_psk_codec_spec.md. v1 put the node ID in PLAINTEXT at
 * bytes [2-3] of every packet; Aras et al. (MobiQuitous 2017) showed
 * that is exactly the handle needed for ~EUR100 per-node selective
 * jamming. When a deployment PSK is set (status page, see below), the
 * v1 payload bytes [1-21] are AES-128-CCM encrypted under that key:
 *
 * WIRE packet — 34 bytes (0x02):
 *   [0]     schema version = 2 (PLAINTEXT — the gateway's schema gate
 *           must fire before any decryption; also the CCM AAD)
 *   [1-8]   nonce: boot_ctr uint32 || frame_ctr uint32 (big-endian,
 *           plaintext — nonces are unique, not secret; boot_ctr is
 *           persisted in Preferences and bumped once per boot,
 *           frame_ctr is a RAM counter bumped per packet)
 *   [9-29]  ciphertext: CCM of v1 bytes [1-21] (type + all fields)
 *   [30-33] CCM tag (4 bytes — wrong key or any tamper => the gateway
 *           drops the packet; unauthenticated modes cannot do that)
 *
 * No PSK set => this node transmits legacy v1 plaintext and says so
 * loudly (Serial banner + status page). There is NO default key.
 *
 * Duty-cycle math (why a 30 s beacon cadence is polite):
 *   SF7 / 125 kHz / CR 4/5, 22-byte payload => ~57 ms airtime.
 *   One beacon per 30 s = 0.19% duty cycle — far under the 1% EU868
 *   limit and a rounding error under US915. With a PSK set the wire
 *   packet is 34 bytes => ~77 ms => 0.257% duty cycle — same story.
 *   Events add one packet's airtime each and
 *   are rare by design (a tripwire that fires constantly is broken).
 *   Higher SF = more range, much more airtime: SF12 would be ~1.3 s per
 *   packet, which blows the EU 1% budget at this cadence — if you raise
 *   SF, slow the beacon cadence in BEACON_MS below.
 *
 * Range expectations (honest): SF7 at 915 MHz with a quarter-wave whip
 * is km-class line-of-sight in the open, a few hundred metres through
 * light clutter, and tens of metres in dense urban/forest. SF9-SF12 buys
 * range at the cost of airtime (see above). This link carries EVENTS ONLY
 * — no firmware updates, no bulk data, no acknowledgements.
 *
 * Power (honest): light sleep is deliberately NOT used — the WiFi
 * promiscuous sniffer must stay in RX to trip. Expect ~120-170 mA @ 5 V
 * on a typical ESP32 devkit (WiFi RX + periodic LoRa TX). Plan USB power
 * or a battery sized for that, not coin cells.
 *
 * Flash-once defaults: AP "Shepherd-SLN-XXXX", password "shepherd-field",
 * WiFi channel 6, status page at 192.168.4.1. No serial config needed.
 * The deployment LoRa PSK (32 hex chars, same on every node + the
 * gateway) is set on that status page under "LoRa security" and stored
 * in Preferences; generate one with `openssl rand -hex 16`.
 */

#include <WiFi.h>
#include <WiFiUdp.h>
#include <WebServer.h>
#include <Preferences.h>
#include <SPI.h>
#include <esp_wifi.h>
#include <RadioLib.h>
#include <lora_psk_codec.h>  // codec v2 wrap — SHARED with the gateway
                               // (esp32/shepherd_lora_psk library; see
                               // docs/lora_psk_codec_spec.md)
#include <keyrefresh.h>    // key refresh/rotation — SHARED library
                               // (esp32/shepherd_lora_keyrefresh; see
                               // docs/lora_key_refresh_spec.md)
#include "mbedtls/md.h"    // SHA-256 for the displayed key ID only

// ---------------- region / frequency ----------------
#if defined(LORA_REGION_EU868)
  #define LORA_FREQ_MHZ 868.0f
  #define LORA_TX_DBM   14     // EU868: 14 dBm ERP limit
#elif defined(LORA_REGION_AS433)
  #define LORA_FREQ_MHZ 433.0f
  #define LORA_TX_DBM   14
#else
  #define LORA_FREQ_MHZ 915.0f
  #define LORA_TX_DBM   17
#endif

// ---------------- pins ----------------
#define LORA_NSS   5
#define LORA_DIO0  26
#define LORA_DIO1  33
#define LORA_RST   14
#define GPS_RX     25
#define GPS_TX     -1     // unconnected; GPIO26 is LoRa DIO0 (see header)
#define GPS_PPS    27

#define BEACON_PORT  49160
#define WIFI_CH      6
#define BEACON_MS    30000UL
#define SAMPLE_MS    250UL    // tripwire metric every 250 ms => 4 fps

// ---------------- codec ----------------
#define CODEC_SCHEMA   1
#define PKT_BEACON     0x01
#define PKT_EVENT      0x02
#define PKT_BEACON_LEN 22
#define PKT_EVENT_LEN  22

// Codec v2 (PSK wrap) — the wire constants and the wrap/unwrap codec
// live in the SHARED header <lora_psk_codec.h> (esp32/shepherd_lora_psk
// library), used by this node and the gateway so the two can never
// drift apart on the wire format. See docs/lora_psk_codec_spec.md.

enum EvClass : uint8_t { CLS_UNKNOWN = 0, CLS_PASSING = 1, CLS_LINGERING = 2 };
enum SensorId : uint8_t { SEN_WIFI = 0 };

static void putU16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xFF; }
static void putU32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = (v >> 16) & 0xFF; p[2] = (v >> 8) & 0xFF; p[3] = v & 0xFF;
}
static void putI32(uint8_t *p, int32_t v) { putU32(p, (uint32_t)v); }
static void putU64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (v >> (56 - 8 * i)) & 0xFF;
}

static void encodeBeacon(uint8_t *p, uint16_t suffix, uint32_t uptimeS,
                         uint16_t evCount, float lat, float lon, uint8_t flags,
                         uint8_t fps, uint16_t vbatMv) {
  p[0] = CODEC_SCHEMA; p[1] = PKT_BEACON;
  putU16(p + 2, suffix);
  putU32(p + 4, uptimeS);
  putU16(p + 8, evCount);
  putI32(p + 10, (int32_t)roundf(lat * 1e6f));
  putI32(p + 14, (int32_t)roundf(lon * 1e6f));
  p[18] = flags; p[19] = fps;
  putU16(p + 20, vbatMv);
}

static void encodeEvent(uint8_t *p, uint16_t suffix, uint32_t t0,
                        uint64_t tUs, float durS, float depthDb,
                        uint8_t cls, float conf, uint8_t sensor) {
  p[0] = CODEC_SCHEMA; p[1] = PKT_EVENT;
  putU16(p + 2, suffix);
  putU32(p + 4, t0);
  putU64(p + 8, tUs);
  uint32_t d = (uint32_t)roundf(durS * 100.0f);
  putU16(p + 16, d > 0xFFFF ? 0xFFFF : (uint16_t)d);
  uint32_t dp = (uint32_t)roundf(depthDb * 10.0f);
  p[18] = dp > 0xFF ? 0xFF : (uint8_t)dp;
  p[19] = cls;
  uint32_t cf = (uint32_t)roundf(conf * 100.0f);
  p[20] = cf > 100 ? 100 : (uint8_t)cf;
  p[21] = sensor;
}

// ---------------- codec v2: PSK state + wrap ----------------
// pskSet == false is a first-class, LOUD state (legacy v1 plaintext),
// never a silent fallback to a default key — there is no default key.
static uint8_t  pskKey[16];
static bool     pskSet = false;
static char     pskKeyId[5] = "----";   // first 2 B of SHA-256(key), hex
static uint32_t bootCtr = 0;            // persisted, +1 per boot
static uint32_t frameCtr = 0;           // RAM only, +1 per packet
static bool     bootCtrOk = true;       // boot_ctr NVS write verified
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

// Encrypt a complete 22-byte v1 packet into its 34-byte v2 wire form,
// via the SHARED codec (shepherd_psk::wrap — same code the gateway's
// unwrap and the host C++ test use). The sketch owns the counters:
// frameCtr advances ONLY on success, so a failed wrap never burns a
// nonce. Returns false (packet must NOT be sent) on crypto failure.
static bool wrapPsk(const uint8_t *plain22, uint8_t *wire) {
  if (!shepherd_psk::wrap(pskKey, bootCtr, frameCtr, plain22, wire))
    return false;
  frameCtr++;
  return true;
}

// ---------------- globals ----------------
Preferences prefs;
WebServer server(80);
WiFiUDP udp;
SX1276 radio = new Module(LORA_NSS, LORA_DIO0, LORA_RST, LORA_DIO1);

char nodeId[16] = "SLN-0000";
uint16_t nodeSuffix = 0;
uint32_t bootMs = 0;
uint32_t eventCount = 0;
uint32_t txOk = 0, txErr = 0;
float lastMetric = 0;
uint32_t pktSeen = 0;

// ---------------- key refresh / rotation (spec: lora_key_refresh_spec.md) --
// Transport is this device's Wi-Fi WebServer (the node has NO LoRa
// receive path — refresh can never arrive over LoRa). The protocol
// and state machine live in the SHARED library <keyrefresh.h>; this
// sketch owns the HTTP endpoints, the identities, and NVS. The
// committed counter is the ONLY refresh state persisted; the staged
// context is RAM-only, so a reboot before commit is a safe abort.
static shepherd_kr::NodeCtx krCtx;
static uint32_t krCtr = 0;              // committed key_counter (NVS kr_ctr)
static uint8_t  krSelfId[8] = {0};      // "SLN-XXXX"
static bool     krPersistFault = false; // commit NVS verify failed
static char     krLastFail[48] = "";    // F10: last KR failure, page-visible
#define KR_STAGE_TIMEOUT_MS 120000UL

static void krIdFromNodeId() { memcpy(krSelfId, nodeId, 8); }

static void krNoteFail(const char *what, shepherd_kr::KrResult r) {
  snprintf(krLastFail, sizeof(krLastFail), "%s (code %d)", what, (int)r);
  Serial.printf("KR failure: %s\n", krLastFail);
}

// Persist a freshly committed key + counter (the ONLY NVS write the
// refresh machinery ever makes) and adopt them as the live PSK.
//
// F1(a): the commit ALSO bumps boot_ctr persistently (same
// write-then-read-back-verify discipline as the boot-time bump).
// Without the bump, the gateway's per-suffix freshness high-water
// (boot_ctr, frame_ctr) would reject every post-commit frame — the
// node restarts frame_ctr at 0 under the SAME boot counter — as a
// replay, for hours of silent outage.
//
// All-or-nothing (F3): psk_hex, kr_ctr and the bumped boot_ctr are
// written, then ALL are read back and verified. Only on full
// success are the new key/counters adopted in RAM. On any mismatch:
// krPersistFault is flagged (status page + Serial), a best-effort
// restore of the previous persisted values is attempted, RAM keeps
// running the OLD key/counters, and false is returned so the
// /kr/commit handler replies NON-200 — the gateway then stays in
// its dual-key window instead of promoting onto a key this node
// did not durably take (spec §9).
static bool krPersistCommit(const uint8_t key[16], uint32_t ctr) {
  static const char *H = "0123456789abcdef";
  char hex[33];
  for (int i = 0; i < 16; i++) { hex[2 * i] = H[key[i] >> 4]; hex[2 * i + 1] = H[key[i] & 15]; }
  hex[32] = 0;
  uint32_t newBoot = bootCtr + 1;
  prefs.putString("psk_hex", hex);
  prefs.putUInt("kr_ctr", ctr);
  prefs.putUInt("boot_ctr", newBoot);
  String back = prefs.getString("psk_hex", "");
  if (back != hex || prefs.getUInt("kr_ctr", 0) != ctr ||
      prefs.getUInt("boot_ctr", 0) != newBoot) {
    krPersistFault = true;
    // Best-effort restore of the pre-commit persisted state so a
    // reboot does not land on a half-written mix.
    static const char *H2 = "0123456789abcdef";
    char oldHex[33];
    for (int i = 0; i < 16; i++) { oldHex[2 * i] = H2[pskKey[i] >> 4]; oldHex[2 * i + 1] = H2[pskKey[i] & 15]; }
    oldHex[32] = 0;
    prefs.putString("psk_hex", oldHex);
    prefs.putUInt("kr_ctr", krCtr);
    prefs.putUInt("boot_ctr", bootCtr);
    Serial.println("!! KR commit NVS verify FAILED — node keeps the OLD key; commit NOT acknowledged");
    return false;
  }
  memcpy(pskKey, key, 16);
  pskSet = true;
  computeKeyId();
  krCtr = ctr;
  bootCtr = newBoot;  // F1(a): post-commit frames are (boot+1, 0..)
  frameCtr = 0;       // new key + bumped boot => fresh nonce space
  return true;
}


// GPS / clock
float gpsLat = 0, gpsLon = 0;
bool gpsFix = false;
volatile uint32_t ppsEdges = 0;
uint32_t ppsSeen = 0;
static uint64_t ppsBaseUs = 0;
static uint32_t ppsBaseMicros = 0;

void IRAM_ATTR ppsIsr() { ppsEdges++; }
uint64_t nodeNowUs() {
  if (ppsSeen == 0) return (uint64_t)micros();
  uint32_t now = micros();
  return ppsBaseUs + (uint64_t)(now - ppsBaseMicros);
}

// ---------------- WiFi RSSI capture ----------------
volatile int32_t rssiSum = 0;
volatile uint32_t rssiN = 0;

void wifiCb(void *buf, wifi_promiscuous_pkt_type_t type) {
  (void)type;
  int8_t r = ((wifi_promiscuous_pkt_t *)buf)->rx_ctrl.rssi;
  rssiSum += r;
  rssiN++;
}

// ---------------- MAD tripwire (compact) ----------------
#define HIST_N 24
#define MAX_EVENT_MS 60000UL
struct Tripwire {
  float hist[HIST_N]; int n = 0, i = 0;
  bool open = false;
  float peak = 0, base = 0;
  uint32_t t0 = 0, quiet = 0;
  uint64_t t0us = 0;
  // returns 1 when an event just closed (dur/depth/cls valid)
  int push(float m, uint32_t now, float &durS, float &depthDb, uint8_t &cls) {
    int closed = 0;
    if (n >= 8) {
      float s[HIST_N], dev[HIST_N];
      for (int j = 0; j < n; j++) s[j] = hist[j];
      for (int a = 1; a < n; a++) {
        float kv = s[a]; int b = a - 1;
        while (b >= 0 && s[b] > kv) { s[b + 1] = s[b]; b--; }
        s[b + 1] = kv;
      }
      float med = (n % 2) ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) * 0.5f;
      for (int j = 0; j < n; j++) dev[j] = fabsf(hist[j] - med);
      for (int a = 1; a < n; a++) {
        float kv = dev[a]; int b = a - 1;
        while (b >= 0 && dev[b] > kv) { dev[b + 1] = dev[b]; b--; }
        dev[b + 1] = kv;
      }
      float mad = (n % 2) ? dev[n / 2] : (dev[n / 2 - 1] + dev[n / 2]) * 0.5f;
      if (mad < 0.15f) mad = 0.15f;
      float thr = med + 4.0f * mad;
      if (!open && m > thr) {
        open = true; t0 = now; t0us = nodeNowUs(); peak = m; base = med;
        quiet = 0;
      } else if (open) {
        if (m > peak) peak = m;
        if (now - t0 > MAX_EVENT_MS) {
          // Level never came back (node moved, lasting interference):
          // close and relearn the baseline at the new level, otherwise the
          // channel stays open forever and goes deaf.
          durS = (now - t0) / 1000.0f;
          depthDb = peak - base; cls = CLS_LINGERING;
          open = false; closed = 1; n = 0; i = 0;
        } else if (m < med + (thr - med) * 0.5f) {
          if (!quiet) quiet = now;
          if (now - quiet > 3000) {
            durS = (now - t0) / 1000.0f;
            depthDb = peak - base;
            cls = durS < 8 ? CLS_PASSING : CLS_LINGERING;
            open = false; closed = 1;
          }
        } else quiet = 0;
      }
    }
    if (!open) { hist[i] = m; i = (i + 1) % HIST_N; if (n < HIST_N) n++; }
    return closed;
  }
};
Tripwire tw;

// ---------------- GPS NMEA (minimal $GxGGA) ----------------
char nmeaLine[128]; int nmeaLen = 0;
static float nmeaDeg(const char *f) {  // ddmm.mmmm -> decimal degrees
  float v = atof(f);
  int d = (int)(v / 100);
  return d + (v - d * 100) / 60.0f;
}
void gpsPoll() {
  while (Serial1.available()) {
    char c = Serial1.read();
    if (c == '\n' || nmeaLen >= (int)sizeof(nmeaLine) - 1) {
      nmeaLine[nmeaLen] = 0; nmeaLen = 0;
      if (strncmp(nmeaLine, "$GPGGA,", 7) == 0 ||
          strncmp(nmeaLine, "$GNGGA,", 7) == 0) {
        // $GxGGA,time,lat,N/S,lon,E/W,fix,...
        char *t = strtok(nmeaLine, ",");
        char *fld[10]; int fi = 0;
        while ((t = strtok(NULL, ",")) && fi < 10) fld[fi++] = t;
        if (fi >= 6 && fld[5][0] >= '1' && fld[5][0] <= '5') {
          float la = nmeaDeg(fld[1]); if (fld[2][0] == 'S') la = -la;
          float lo = nmeaDeg(fld[3]); if (fld[4][0] == 'W') lo = -lo;
          gpsLat = la; gpsLon = lo; gpsFix = true;
        }
      }
    } else if (c != '\r') nmeaLine[nmeaLen++] = c;
  }
  static uint32_t lastPpsCheck = 0;
  uint32_t now = millis();
  if (now - lastPpsCheck > 2500) {  // PPS seen recently?
    lastPpsCheck = now;
    noInterrupts(); uint32_t e = ppsEdges; interrupts();
    if (e > 0) {
      ppsSeen = e;
      ppsBaseUs += 1000000ULL;   // one more second of disciplined time
      ppsBaseMicros = micros();
      noInterrupts(); ppsEdges = 0; interrupts();
    }
  }
}

// ---------------- UDP JSON (standard Shepherd format) ----------------
void udpSend(const char *json) {
  udp.beginPacket(WiFi.broadcastIP(), BEACON_PORT);
  udp.write((uint8_t *)json, strlen(json));
  udp.endPacket();
}
void sendJsonBeacon() {
  char buf[384];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"beacon\",\"node\":\"%s\",\"ip\":\"%s\",\"ch\":%d,"
    "\"fps\":%d,\"events\":%lu,\"uptime_s\":%lu,"
    "\"sensors\":[\"wifi\"],\"ble_seen\":0,"
    "\"lat\":%.6f,\"lon\":%.6f,\"pps\":%d}",
    nodeId, WiFi.softAPIP().toString().c_str(), WiFi.channel(),
    1000 / (int)SAMPLE_MS, (unsigned long)eventCount,
    (unsigned long)((millis() - bootMs) / 1000),
    gpsLat, gpsLon, ppsSeen > 0 ? 1 : 0);
  udpSend(buf);
}
void sendJsonEvent(uint32_t t0, uint64_t tUs, float durS, float depthDb,
                   uint8_t cls, float conf) {
  const char *clsS = cls == CLS_PASSING ? "PASSING"
                   : cls == CLS_LINGERING ? "LINGERING" : "UNKNOWN";
  char buf[384];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"event\",\"node\":\"%s\",\"sensor\":\"wifi\",\"t0\":%lu,"
    "\"t_us\":%llu,\"dur_s\":%.1f,\"depth_db\":%.1f,"
    "\"class\":\"%s\",\"conf\":%.2f,\"detail\":\"\"}",
    nodeId, (unsigned long)t0, (unsigned long long)tUs,
    durS, depthDb, clsS, conf);
  udpSend(buf);
}

// ---------------- LoRa TX ----------------
void loraTx(const uint8_t *p, size_t len) {
  int st = radio.transmit(p, len);
  if (st == RADIOLIB_ERR_NONE) txOk++; else txErr++;
  Serial.printf("LoRa TX %u B -> %d\n", (unsigned)len, st);
}
// Every codec packet (beacon and event are both 22 B in v1) goes out
// through here: PSK set => 34 B encrypted v2 wire form; no PSK =>
// legacy v1 plaintext, exactly as before. A crypto failure drops the
// packet rather than ever sending it half-wrapped.
void txCodec(const uint8_t *plain22) {
  if (!pskSet) { loraTx(plain22, PKT_BEACON_LEN); return; }
  if (!bootCtrOk) {
    // boot_ctr could not be verified in NVS (setup) — transmitting
    // now could reuse a (key, nonce) pair from a previous boot, which
    // breaks CCM outright. Refuse: drop, count, stay loud. NEVER fall
    // back to plaintext instead (no silent downgrade).
    txErr++;
    Serial.println("LoRa TX REFUSED: boot_ctr unverified (nonce-reuse risk)");
    return;
  }
  uint8_t wire[shepherd_psk::WIRE_LEN];
  if (wrapPsk(plain22, wire)) loraTx(wire, sizeof(wire));
  else { txErr++; Serial.println("PSK wrap FAILED — packet not sent"); }
}
void sendLoraBeacon() {
  uint8_t p[PKT_BEACON_LEN];
  uint8_t flags = (gpsFix ? 0x01 : 0) | (ppsSeen > 0 ? 0x02 : 0);
  encodeBeacon(p, nodeSuffix, (millis() - bootMs) / 1000, (uint16_t)eventCount,
               gpsLat, gpsLon, flags, 1000 / (int)SAMPLE_MS, 0);
  txCodec(p);
}
void sendLoraEvent(uint32_t t0, uint64_t tUs, float durS, float depthDb,
                   uint8_t cls, float conf) {
  uint8_t p[PKT_EVENT_LEN];
  encodeEvent(p, nodeSuffix, t0, tUs, durS, depthDb, cls, conf, SEN_WIFI);
  txCodec(p);
}

// ---------------- status page ----------------
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
    "PSK saved. <b>Reboot the node</b> to start encrypted TX, and set the SAME "
    "key on the gateway. <a href=/ style='color:#a855f7'>Back</a></body></html>");
}
// Clearing the PSK downgrades this node's wire to plaintext, so
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
      "No PSK is set on this node — nothing to clear. "
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
    "PSK cleared. Reboot the node — it returns to PLAINTEXT codec v1. "
    "<a href=/ style='color:#a855f7'>Back</a></body></html>");
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

// ---- key-refresh endpoints (raw binary bodies via upload handler) ----
static uint8_t krBody[832];
static size_t krBodyLen = 0;
static bool krBodyOverflow = false;
void krUpload() {
  HTTPUpload &up = server.upload();
  if (up.status == UPLOAD_FILE_START) { krBodyLen = 0; krBodyOverflow = false; }
  else if (up.status == UPLOAD_FILE_WRITE) {
    if (krBodyLen + up.currentSize <= sizeof(krBody)) {
      memcpy(krBody + krBodyLen, up.buf, up.currentSize);
      krBodyLen += up.currentSize;
    } else krBodyOverflow = true;
  }
}
static void krSendCode(int http, shepherd_kr::KrResult r) {
  uint8_t b = (uint8_t)r;
  server.send_P(http, "application/octet-stream", (const char *)&b, 1);
}
static void krSendBin(int http, const uint8_t *p, size_t n) {
  server.send_P(http, "application/octet-stream", (const char *)p, n);
}
static int krHttpFor(shepherd_kr::KrResult r) {
  using namespace shepherd_kr;
  return r == KR_ERR_AUTH ? 403 : r == KR_ERR_FORMAT ? 400 : 409;
}

void handleKrBegin() {
  using namespace shepherd_kr;
  if (!pskSet) { krSendCode(403, KR_ERR_STATE); return; }  // F8 uniform guard
  if (krBodyOverflow || krBodyLen != 12) { krSendCode(400, KR_ERR_FORMAT); return; }
  uint32_t counter = shepherd_kr::getU32(krBody + 8);
  uint8_t ek[shepherd_kr::EK_LEN];
  KrResult r = nodeBeginKem(krCtx, krCtr, krSelfId, krBody, counter, millis(), ek);
  if (r != KR_OK) { krNoteFail("begin refused", r); krSendCode(krHttpFor(r), r); return; }
  uint8_t resp[812];
  memcpy(resp, krSelfId, 8);
  shepherd_kr::putU32(resp + 8, counter);
  memcpy(resp + 12, ek, shepherd_kr::EK_LEN);
  krSendBin(200, resp, sizeof(resp));
  Serial.printf("KR begin: refresh staged target ctr=%lu (peer %.8s)\n",
                (unsigned long)counter, (const char *)krBody);
}
void handleKrEncap() {
  using namespace shepherd_kr;
  if (!pskSet) { krSendCode(403, KR_ERR_STATE); return; }  // F8 uniform guard
  if (krBodyOverflow || krBodyLen != shepherd_kr::CT_LEN + 32) { krSendCode(400, KR_ERR_FORMAT); return; }
  uint8_t confirm[32];
  KrResult r = nodeAcceptEncap(krCtx, pskKey, krBody, krBody + shepherd_kr::CT_LEN, confirm);
  if (r != KR_OK) { krNoteFail("encap refused", r); krSendCode(krHttpFor(r), r); return; }
  krSendBin(200, confirm, 32);
  Serial.println("KR encap: candidate STAGED + confirmed (TX still on committed key)");
}
void handleKrRotate() {
  using namespace shepherd_kr;
  if (!pskSet) { krSendCode(403, KR_ERR_STATE); return; }  // F8 uniform guard
  // F6: the body is gwId[8] || codec wire packet[34] — the gateway
  // identity is bound into the commit context on BOTH sides, so a
  // commit proof for one node cannot be replayed to another.
  if (krBodyOverflow || krBodyLen != 8 + shepherd_psk::WIRE_LEN) { krSendCode(400, KR_ERR_FORMAT); return; }
  KrResult r = nodeStageRotation(krCtx, pskKey, krCtr, krSelfId, krBody /*gwId*/,
                                 krBody + 8, millis());
  if (r != KR_OK) { krNoteFail("rotate refused", r); krSendCode(krHttpFor(r), r); return; }
  uint8_t resp[6];
  uint8_t id[2];
  shepherd_kr::keyId(krCtx.stagedKey, id);
  resp[0] = id[0]; resp[1] = id[1];
  shepherd_kr::putU32(resp + 2, krCtx.targetCounter);
  krSendBin(200, resp, sizeof(resp));
  Serial.printf("KR rotate: candidate STAGED ctr=%lu (TX still on committed key)\n",
                (unsigned long)krCtx.targetCounter);
}
void handleKrCommit() {
  using namespace shepherd_kr;
  if (!pskSet) { krSendCode(403, KR_ERR_STATE); return; }  // F8 uniform guard
  if (krBodyOverflow || krBodyLen != 32) { krSendCode(400, KR_ERR_FORMAT); return; }
  uint8_t newKey[16]; uint32_t co = 0;
  KrResult r = nodeCommit(krCtx, krBody, newKey, &co);
  if (r != KR_OK) { krNoteFail("commit refused", r); krSendCode(krHttpFor(r), r); return; }
  memset(krLastFail, 0, sizeof(krLastFail));
  bool persisted = krPersistCommit(newKey, co);
  if (!persisted) {
    // F3: NON-200 — the gateway must NOT promote onto a key this
    // node did not durably take; it stays in its dual-key window
    // (F4) and the operator re-runs the session once the flash
    // fault is fixed. This node keeps running the OLD key.
    krNoteFail("commit persist failed", KR_ERR_CRYPTO);
    krSendCode(500, KR_ERR_CRYPTO);
    return;
  }
  Serial.printf("KR COMMIT: new key ID %s ctr=%lu persisted=1 boot_ctr=%lu\n",
                pskKeyId, (unsigned long)co, (unsigned long)bootCtr);
  krSendCode(200, KR_OK);
}
void handleKrAbort() {
  using namespace shepherd_kr;
  if (!pskSet) { krSendCode(403, KR_ERR_STATE); return; }  // F8 uniform guard
  if (krBodyOverflow) { krSendCode(400, KR_ERR_FORMAT); return; }
  // F5: with a staged context, the abort must carry the staged-key
  // proof (same style as commit); with none, it is a no-op success.
  KrResult r = nodeVerifyAbort(krCtx, pskKey,
                               krBodyLen ? krBody : nullptr, krBodyLen);
  if (r != KR_OK) { krNoteFail("abort refused", r); krSendCode(krHttpFor(r), r); return; }
  Serial.println("KR abort: staged context discarded (committed key unchanged)");
  krSendCode(200, shepherd_kr::KR_OK);
}

void handleRoot() {
  char html[4600];
  snprintf(html, sizeof(html),
    "<html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<style>body{background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px}"
    "h1{color:#a855f7}.card{background:#1c1c22;padding:16px;border-radius:12px;margin:12px 0}"
    ".warn{color:#f87171;font-weight:bold}"
    "input{background:#222;color:#eee;border:1px solid #444;padding:6px;width:280px}"
    "button{background:#7c3aed;color:#fff;border:0;padding:6px 14px;border-radius:6px}</style>"
    "</head><body><h1>Shepherd LoRa Node %s</h1>"
    "<div class=card>LoRa %.1f MHz SF7/125kHz — backhaul only, star to gateway<br>"
    "Uptime %lu s &nbsp; Packets seen %lu<br>LoRa TX ok %lu err %lu &nbsp; Events %lu</div>"
    "<div class=card>WiFi tripwire metric %.1f dB &nbsp; GPS: %s &nbsp; PPS: %s<br>"
    "Lat %.6f Lon %.6f</div>"
    "<div class=card>Join this AP for the local JSON feed.<br>"
    "LoRa detections go to the Shepherd gateway on UDP %d.</div>",
    nodeId, LORA_FREQ_MHZ, (unsigned long)((millis() - bootMs) / 1000),
    (unsigned long)pktSeen, (unsigned long)txOk, (unsigned long)txErr,
    (unsigned long)eventCount, lastMetric,
    gpsFix ? "fix" : "no fix", ppsSeen > 0 ? "locked" : "free-run",
    gpsLat, gpsLon, BEACON_PORT);
  size_t o = strlen(html);
  if (pskSet) {
    snprintf(html + o, sizeof(html) - o,
      "<div class=card>LoRa security: PSK <b>SET</b> (key ID %s) — packets "
      "encrypted, codec v2 (34 B on air).<br>"
      "<form method=post action=/psk><input name=k maxlength=32 "
      "placeholder='new 32-hex PSK'> <button>Replace PSK</button></form>"
      "<form method=post action=/pskclear><input name=confirm maxlength=4 "
      "placeholder='type key ID to confirm'> <button>Clear PSK (back to "
      "plaintext v1)</button></form></div>", pskKeyId);
  } else {
    snprintf(html + o, sizeof(html) - o,
      "<div class=card><span class=warn>LoRa PSK NOT SET — this node is "
      "transmitting PLAINTEXT codec v1 (node ID visible to anyone in RF range).</span><br>"
      "Set the deployment key (32 hex chars, same key on the gateway):<br>"
      "<form method=post action=/psk><input name=k maxlength=32 "
      "placeholder='32 hex characters'> <button>Save PSK</button></form>"
      "Takes effect on reboot.</div>");
  }
  if (pskSet) {
    char stagedId[5] = "----";
    if (krCtx.state != shepherd_kr::KR_IDLE)
      shepherd_kr::keyIdHex(krCtx.stagedKey, stagedId);
    const char *stName = krCtx.state == shepherd_kr::KR_CONFIRMED ? "CONFIRMED"
                       : krCtx.state == shepherd_kr::KR_STAGED ? "STAGED" : "IDLE";
    size_t ok2 = strlen(html);
    snprintf(html + ok2, sizeof(html) - ok2,
      "<div class=card>Key refresh: state <b>%s</b> &nbsp; committed "
      "key_counter %lu &nbsp; staged key ID %s<br>"
      "Completed: ML-KEM refresh %lu &nbsp; rotation %lu<br>"
      "Refusals: auth %lu &nbsp; counter %lu &nbsp; state %lu &nbsp; "
      "failures %lu%s%s%s</div>",
      stName, (unsigned long)krCtr, stagedId,
      (unsigned long)krCtx.okKem, (unsigned long)krCtx.okRot,
      (unsigned long)krCtx.refuseAuth, (unsigned long)krCtx.refuseCounter,
      (unsigned long)krCtx.refuseState, (unsigned long)krCtx.failures,
      krPersistFault ? "<br><span class=warn>KR commit NVS FAULT — the "
      "node kept the OLD key and did not acknowledge the commit; fix "
      "the flash fault and re-run the refresh.</span>" : "",
      krLastFail[0] ? "<br>Last KR failure: " : "",
      krLastFail[0] ? krLastFail : "");
  }
  size_t oa = strlen(html);
  if (apPassDefault) {
    snprintf(html + oa, sizeof(html) - oa,
      "<div class=card>AP password: <span class=warn>public DEFAULT still "
      "in use</span> — change it below, especially before setting the "
      "LoRa PSK.<br>"
      "<form method=post action=/appass><input type=password name=ap "
      "maxlength=63 placeholder='new AP password (8-63 chars)'> "
      "<button>Save AP password</button></form>"
      "Takes effect on reboot — you will need to rejoin the AP with the "
      "new password.</div>");
  } else {
    snprintf(html + oa, sizeof(html) - oa,
      "<div class=card>AP password: <b>custom set</b> (never shown).<br>"
      "<form method=post action=/appass><input type=password name=ap "
      "maxlength=63 placeholder='new AP password (8-63 chars)'> "
      "<button>Replace AP password</button></form>"
      "Takes effect on reboot — you will need to rejoin the AP with the "
      "new password.</div>");
  }
  size_t o2 = strlen(html);
  if (!bootCtrOk) {
    o2 += snprintf(html + o2, sizeof(html) - o2,
      "<div class=card><span class=warn>boot_ctr NVS FAULT — encrypted "
      "(v2) transmissions are REFUSED until this clears (nonce-reuse "
      "risk). Reboot the node; if it persists, its flash/NVS is "
      "failing.</span></div>");
  }
  if (pskClearRefused > 0) {
    o2 += snprintf(html + o2, sizeof(html) - o2,
      "<div class=card>Clear-PSK refusals so far: %lu (bad key-ID "
      "confirmation).</div>", (unsigned long)pskClearRefused);
  }
  snprintf(html + o2, sizeof(html) - o2, "</body></html>");
  server.send(200, "text/html", html);
}

// ---------------- setup / loop ----------------
void setup() {
  Serial.begin(115200);
  bootMs = millis();
  prefs.begin("sln", false);

  String nid = prefs.getString("node_id", "");
  if (nid.length() == 0) {
    uint8_t mac[6]; esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    nodeSuffix = (mac[4] << 8) | mac[5];
    char tmp[16]; snprintf(tmp, sizeof(tmp), "SLN-%02X%02X", mac[4], mac[5]);
    nid = tmp; prefs.putString("node_id", nid);
  } else {
    nodeSuffix = (uint16_t)strtoul(nid.c_str() + 4, NULL, 16);
  }
  nid.toCharArray(nodeId, sizeof(nodeId));
  krIdFromNodeId();
  krCtr = prefs.getUInt("kr_ctr", 0);
  String pass = prefs.getString("ap_pass", "shepherd-field");
  apPassDefault = (pass == "shepherd-field");
  if (apPassDefault)
    Serial.println("!! AP password is the public DEFAULT — change it on the status page.");

  // Codec v2 PSK + nonce state. boot_ctr is bumped ONCE per boot (one
  // NVS write — negligible wear) so (boot_ctr, frame_ctr) nonces never
  // repeat across reboots; frame_ctr restarts at 0 each boot.
  String pskHex = prefs.getString("psk_hex", "");
  if (pskHex.length() > 0 && parseHexKey(pskHex, pskKey)) {
    pskSet = true; computeKeyId();
  } else if (pskHex.length() > 0) {
    Serial.println("!! stored psk_hex is malformed (need 32 hex chars) — ignoring it");
  }
  bootCtr = prefs.getUInt("boot_ctr", 0) + 1;
  prefs.putUInt("boot_ctr", bootCtr);
  // Verify the write landed: if NVS silently dropped it, this boot
  // would reuse a previous boot's boot_ctr and (boot_ctr, frame_ctr)
  // nonces would repeat under the same key — fatal to CCM. Read back
  // and compare; on mismatch, txCodec refuses v2 transmission and
  // the status page shows the fault. (Model note: the host model does
  // not simulate NVS faults; this is a firmware-only guard, spec'd in
  // docs/lora_psk_codec_spec.md.)
  bootCtrOk = (prefs.getUInt("boot_ctr", 0) == bootCtr);
  if (!bootCtrOk) {
    Serial.println("!! boot_ctr NVS write FAILED verification — v2 TX REFUSED");
    Serial.println("!! (nonce-reuse risk). Reboot; persistent failure = failing flash/NVS.");
  }
  frameCtr = 0;

  WiFi.mode(WIFI_AP);
  char ssid[24]; snprintf(ssid, sizeof(ssid), "Shepherd-%s", nodeId + 4);
  WiFi.softAP(ssid, pass.c_str(), WIFI_CH);
  Serial.printf("AP %s up\n", ssid);

  // Promiscuous RSSI sniffer (MGMT + DATA frames)
  esp_wifi_set_promiscuous(true);
  wifi_promiscuous_filter_t filt;
  filt.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT | WIFI_PROMIS_FILTER_MASK_DATA;
  esp_wifi_set_promiscuous_filter(&filt);
  esp_wifi_set_promiscuous_rx_cb(&wifiCb);

  // GPS: RX-only NMEA + PPS (silent when absent)
  Serial1.begin(9600, SERIAL_8N1, GPS_RX, GPS_TX);
  pinMode(GPS_PPS, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(GPS_PPS), ppsIsr, RISING);

  // LoRa
  SPI.begin(18, 19, 23);
  int st = radio.begin(LORA_FREQ_MHZ, 125.0, 7, 5, 0x12, LORA_TX_DBM, 8);
  // sync word 0x12 = private LoRa (NOT 0x34 LoRaWAN) — we stay off
  // public networks on purpose.
  radio.setCRC(true);
  if (st == RADIOLIB_ERR_NONE) {
    Serial.printf("LoRa up: %.1f MHz SF7/125kHz\n", LORA_FREQ_MHZ);
  } else {
    Serial.printf("LoRa FAILED: %d — check wiring\n", st);
  }

  udp.begin(BEACON_PORT);
  server.on("/", handleRoot);
  server.on("/psk", HTTP_POST, handlePskSave);
  server.on("/pskclear", HTTP_POST, handlePskClear);
  server.on("/appass", HTTP_POST, handleApPassSave);
  server.on("/kr/begin", HTTP_POST, handleKrBegin, krUpload);
  server.on("/kr/encap", HTTP_POST, handleKrEncap, krUpload);
  server.on("/kr/rotate", HTTP_POST, handleKrRotate, krUpload);
  server.on("/kr/commit", HTTP_POST, handleKrCommit, krUpload);
  server.on("/kr/abort", HTTP_POST, handleKrAbort, krUpload);
  server.begin();
  if (pskSet) {
    Serial.printf("LoRa PSK SET (key ID %s) — codec v2 encrypted TX, boot_ctr=%lu\n",
                  pskKeyId, (unsigned long)bootCtr);
    if (!bootCtrOk)
      Serial.println("!! ...but boot_ctr is UNVERIFIED — v2 TX is REFUSED (see above).");
  } else {
    Serial.println("!! LoRa PSK NOT SET — transmitting PLAINTEXT codec v1 !!");
    Serial.println("!! Set a deployment PSK on the status page (LoRa security card).");
  }
  Serial.printf("Shepherd LoRa node %s ready\n", nodeId);
}

void loop() {
  static uint32_t lastSample = 0, lastBeacon = 0;
  uint32_t now = millis();

  gpsPoll();
  server.handleClient();

  // Key-refresh staged contexts expire: timeout == abort (old key
  // was never touched, so this is always safe).
  if (shepherd_kr::nodeExpired(krCtx, now, KR_STAGE_TIMEOUT_MS)) {
    shepherd_kr::nodeAbort(krCtx);
    Serial.println("KR staged context EXPIRED — reverted to committed key");
  }

  if (now - lastSample >= SAMPLE_MS) {
    lastSample = now;
    noInterrupts(); int32_t s = rssiSum; uint32_t n = rssiN;
    rssiSum = 0; rssiN = 0; interrupts();
    if (n > 0) {
      pktSeen += n;
      float m = -((float)s / n);   // polarity: a link dip is a rise
      lastMetric = m;
      float durS, depthDb; uint8_t cls;
      if (tw.push(m, now, durS, depthDb, cls)) {
        // Heuristic confidence: deeper dips are more trustworthy.
        float conf = 0.5f + depthDb * 0.03f;
        if (conf > 0.95f) conf = 0.95f;
        uint32_t t0rel = (tw.t0 - bootMs) / 1000;
        eventCount++;
        sendLoraEvent(t0rel, tw.t0us, durS, depthDb, cls, conf);
        sendJsonEvent(t0rel, tw.t0us, durS, depthDb, cls, conf);
        Serial.printf("EVENT wifi dur=%.1fs depth=%.1fdB cls=%u conf=%.2f\n",
                      durS, depthDb, cls, conf);
      }
    }
  }

  if (now - lastBeacon >= BEACON_MS) {
    lastBeacon = now;
    sendLoraBeacon();
    sendJsonBeacon();
  }
}
