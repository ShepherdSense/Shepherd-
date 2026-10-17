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

static uint16_t getU16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static uint32_t getU32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | p[3];
}
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

Preferences prefs;
WebServer server(80);
WiFiUDP udp;
SX1276 radio = new Module(LORA_NSS, LORA_DIO0, LORA_RST, LORA_DIO1);

char gwId[16] = "SLG-0000";
uint32_t bootMs = 0;
uint32_t rxOk = 0, rxBad = 0;

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

void handlePacket(const uint8_t *p, size_t len, uint32_t now) {
  if (len < 2 || p[0] != CODEC_SCHEMA) { rxBad++; return; }
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
    reemitEvent(suffix, t0, tUs, durS, depthDb, cls, conf, sensor);
  } else {
    rxBad++;  // unknown type or wrong length — dropped, not guessed at
  }
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
  char html[2400];
  snprintf(html, sizeof(html),
    "<html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<meta http-equiv=refresh content=10>"
    "<style>body{background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px}"
    "h1{color:#a855f7}.card{background:#1c1c22;padding:16px;border-radius:12px;margin:12px 0}"
    "table{border-collapse:collapse}td,th{padding:6px 10px;border:1px solid #333;text-align:left}</style>"
    "</head><body><h1>Shepherd LoRa Gateway %s</h1>"
    "<div class=card>LoRa %.1f MHz RX-only, star topology<br>"
    "Uptime %lu s &nbsp; Packets ok %lu &nbsp; dropped %lu</div>"
    "<div class=card><table><tr><th>Node</th><th>Last heard</th><th>fps</th>"
    "<th>Events</th><th>Lat,Lon</th></tr>%s</table></div>"
    "<div class=card>Join this AP from the Shepherd device.<br>"
    "Decoded packets re-emitted on UDP %d as standard Shepherd JSON.</div></body></html>",
    gwId, LORA_FREQ_MHZ, (unsigned long)((millis() - bootMs) / 1000),
    (unsigned long)rxOk, (unsigned long)rxBad, rows[0] ? rows : "",
    BEACON_PORT);
  if (!rows[0]) {
    // no nodes yet — the %s above printed empty; table shows headers only
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
  server.begin();
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
