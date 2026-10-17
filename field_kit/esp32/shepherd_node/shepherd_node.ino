/*
 * Shepherd Node — ESP32 field sensor firmware
 *
 * Flash once. Afterwards every USB plug-in is just power: the node boots,
 * hosts its own WiFi AP, and runs every sensor it can find:
 *
 *   BUILT-IN (always on)
 *     wifi  - WiFi CSI/RSSI promiscuous sniffer + edge tripwire detector
 *     ble   - BLE advertisement scanner (time-sliced; new-device events)
 *   SPI (auto-detected at boot — enabled only if the module answers)
 *     nrf24 - nRF24L01 2.4 GHz band-energy sweep (RPD across ch 0..125)
 *     cc110 - CC1101 sub-GHz RSSI (default 433.92 MHz, changeable)
 *   UART (generic — any external module can stream readings in)
 *     uart  - Serial2 text protocol:  SENSOR <name> <rssi_dbm> [detail]
 *
 * Detection is local and deterministic (rolling baseline + MAD threshold,
 * baseline hold during events). The node broadcasts compact beacons and
 * events; Shepherd fuses them. Nothing here identifies anything — dips,
 * energy, and MAC hints, shown as estimates.
 *
 * Protocol (UDP broadcast, port 49160 — the Shepherd ESP32Driver listens):
 *   beacon: {"type":"beacon","node":"SHN-XXXX","ip":"192.168.4.1","ch":6,
 *            "fps":42,"events":3,"uptime_s":1234,
 *            "sensors":["wifi","ble","nrf24"],"ble_seen":5}
 *   event:  {"type":"event","node":"SHN-XXXX","sensor":"wifi","t0":1234,
 *            "dur_s":5.2,"depth_db":6.1,"class":"PASSING","conf":0.7,
 *            "detail":""}
 *
 * Wiring (changeable below): VSPI SCK=18 MISO=19 MOSI=23,
 *   nRF24 CS=4, CC1101 CS=21, UART2 RX=16 TX=17.
 *
 * Honest scope: these are coarse tripwire layers, not lab instruments.
 * ESP32 CSI is a poor-man's link disturbance sensor; nRF24 RPD is a
 * 1-bit energy detector per channel; BLE MACs are often randomized, so
 * new-device events are hints, not identifications.
 *
 * Tested target: ESP32 classic (WROOM-32) on Arduino-ESP32 2.0.x.
 */

#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFiUdp.h>
#include <SPI.h>
#include <BLEDevice.h>
#include <BLEScan.h>
#include "esp_wifi.h"

// ---------------- configuration ----------------
#define BEACON_PORT   49160
#define STATUS_PORT   80
#define DEFAULT_CH    6
#define BEACON_MS     5000
#define BLE_EVERY_MS  60000
#define BLE_SCAN_S    6
#define CC1101_FREQ_HZ 433920000UL   // sub-GHz watch frequency

// pins
#define NRF_CS   4
#define CC110_CS 21
#define UART_RX  16
#define UART_TX  17

Preferences prefs;
WebServer server(STATUS_PORT);
WiFiUDP udp;

char nodeId[16] = "SHN-????";
uint32_t bootMs = 0;
uint32_t eventCount = 0;
float lastWifiMetric = 0;

// sensors actually alive on this node (advertised in beacons)
char sensorList[96] = "wifi,ble";

// ---------------- generic MAD channel ----------------
// One per sensor metric. push() returns true when an event just closed.
struct SensorCh {
  const char *name;
  float k;                       // MAD multiplier
  float hist[30]; int n = 0, i = 0;
  bool open = false;
  float peak = 0, base = 0;
  uint32_t t0 = 0, quiet = 0;

  SensorCh(const char *name_, float k_) : name(name_), k(k_) {}
  SensorCh() : name("uart"), k(3.5f) {}   // for UartCh array slots

  // returns 1 if an event closed on this call (dur/depth valid), else 0
  int push(float m, uint32_t now, float &durS, float &depthDb,
           const char *&cls) {
    int closed = 0;
    if (n >= 8) {
      // median + MAD over history
      float s[30];
      for (int j = 0; j < n; j++) s[j] = hist[j];
      for (int a = 1; a < n; a++) {
        float kv = s[a]; int b = a - 1;
        while (b >= 0 && s[b] > kv) { s[b + 1] = s[b]; b--; }
        s[b + 1] = kv;
      }
      float med = (n % 2) ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) * 0.5f;
      float dev[30];
      for (int j = 0; j < n; j++) dev[j] = fabsf(hist[j] - med);
      for (int a = 1; a < n; a++) {
        float kv = dev[a]; int b = a - 1;
        while (b >= 0 && dev[b] > kv) { dev[b + 1] = dev[b]; b--; }
        dev[b + 1] = kv;
      }
      float mad = (n % 2) ? dev[n / 2] : (dev[n / 2 - 1] + dev[n / 2]) * 0.5f;
      if (mad < 0.15f) mad = 0.15f;
      float thr = med + k * mad;
      if (!open && m > thr) {
        open = true; t0 = now; peak = m; base = med; quiet = 0;
      } else if (open) {
        if (m > peak) peak = m;
        if (m < med + (thr - med) * 0.5f) {
          if (!quiet) quiet = now;
          if (now - quiet > 3000) {
            durS = (now - t0) / 1000.0f;
            depthDb = peak - base;
            cls = durS < 8 ? "PASSING" : "LINGERING";
            open = false; closed = 1;
          }
        } else quiet = 0;
      }
    }
    if (!open) { hist[i] = m; i = (i + 1) % 30; if (n < 30) n++; }
    return closed;
  }
};

SensorCh chWifi("wifi", 4.0f);
SensorCh chNrf("nrf24", 3.5f);
SensorCh chCc("cc110", 3.5f);
struct UartCh { char name[16]; SensorCh ch; bool used = false; };
UartCh uartCh[4];

void sendEvent(const char *sensor, float durS, float depthDb,
               const char *cls, float conf, const char *detail);  // fwd
uint32_t eventT0glob = 0;

void sendEvent(const char *sensor, float durS, float depthDb,
               const char *cls, float conf, const char *detail) {
  char buf[320];
  uint32_t t0 = (eventT0glob - bootMs) / 1000;
  snprintf(buf, sizeof(buf),
    "{\"type\":\"event\",\"node\":\"%s\",\"sensor\":\"%s\",\"t0\":%lu,"
    "\"dur_s\":%.1f,\"depth_db\":%.1f,\"class\":\"%s\",\"conf\":%.2f,"
    "\"detail\":\"%s\"}",
    nodeId, sensor, (unsigned long)t0, durS, depthDb, cls, conf,
    detail ? detail : "");
  udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
  udp.write((uint8_t *)buf, strlen(buf));
  udp.endPacket();
  eventCount++;
  Serial.printf("[%s] %s %.1fs %.1fdB %s\n", sensor, cls, durS, depthDb,
                detail ? detail : "");
}

// ---------------- WiFi CSI sniffer ----------------
volatile uint32_t g_frames = 0;
volatile int32_t  g_rssiSum = 0;

void csi_cb(void *ctx, wifi_csi_info_t *data) {
  if (!data) return;
  g_frames++;
  g_rssiSum += data->rx_ctrl.rssi;
}

void wifiSniff(bool on) {
  esp_wifi_set_promiscuous(on);
  esp_wifi_set_csi(on);
}

// ---------------- BLE scanner ----------------
struct BleDev { char mac[18]; int8_t rssi; uint32_t last; };
BleDev bleSeen[24];
int bleN = 0;
uint32_t lastBleEvent = 0;

class AdvCb : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice d) override {
    int8_t r = d.getRSSI();
    if (r < -80) return;                       // too far / noisy
    String ms = String(d.getAddress().toString().c_str());
    uint32_t now = millis();
    for (int i = 0; i < bleN; i++) {
      if (ms.equals(bleSeen[i].mac)) {
        bleSeen[i].rssi = r; bleSeen[i].last = now; return;
      }
    }
    // new device: hint-level event if close and not spamming
    if (r > -70 && now - lastBleEvent > 10000) {
      lastBleEvent = now;
      eventT0glob = now;
      char mac[18]; ms.toCharArray(mac, sizeof(mac));
      float durS = 0, depth = -r;
      sendEvent("ble", durS, depth, "NEW_DEVICE", 0.55f, mac);
    }
    if (bleN < 24) {
      ms.toCharArray(bleSeen[bleN].mac, 18);
      bleSeen[bleN].rssi = r; bleSeen[bleN].last = now; bleN++;
    }
  }
};

void bleScanOnce() {
  wifiSniff(false);                            // radio time-slice
  delay(200);
  BLEScan *sc = BLEDevice::getScan();
  sc->setAdvertisedDeviceCallbacks(new AdvCb());
  sc->setActiveScan(true);
  sc->setInterval(100); sc->setWindow(99);
  sc->start(BLE_SCAN_S, false);
  sc->clearResults();
  // prune stale
  uint32_t now = millis(), w = 0;
  for (int i = 0; i < bleN; i++)
    if (now - bleSeen[i].last < 300000) bleSeen[w++] = bleSeen[i];
  bleN = w;
  wifiSniff(true);
}

// ---------------- SPI helpers ----------------
uint8_t spiRegRead(int cs, uint8_t reg, bool cc1101) {
  digitalWrite(cs, LOW);
  uint8_t v;
  if (cc1101) { SPI.transfer(0x80 | reg); v = SPI.transfer(0x00); }
  else        { SPI.transfer(reg & 0x1F); v = SPI.transfer(0xFF); }
  digitalWrite(cs, HIGH);
  return v;
}
void spiRegWrite(int cs, uint8_t reg, uint8_t val, bool cc1101) {
  digitalWrite(cs, LOW);
  if (cc1101) { SPI.transfer(reg); }
  else        { SPI.transfer(0x20 | (reg & 0x1F)); }
  SPI.transfer(val);
  digitalWrite(cs, HIGH);
}
void ccStrobe(int cs, uint8_t cmd) {
  digitalWrite(cs, LOW); SPI.transfer(cmd); digitalWrite(cs, HIGH);
}

// ---------------- nRF24L01: 2.4 GHz energy sweep ----------------
bool nrfPresent = false;
bool nrfDetect() {
  uint8_t st = spiRegRead(NRF_CS, 0x07, false);  // STATUS, POR = 0x0E
  return st == 0x0E;
}
void nrfInit() {
  spiRegWrite(NRF_CS, 0x00, 0x03, false);        // CONFIG: PWR_UP, PRIM_RX
  delay(5);
}
int nrfSweep() {
  int energy = 0;
  for (int ch = 2; ch <= 125; ch++) {
    spiRegWrite(NRF_CS, 0x05, ch, false);        // RF_CH
    delayMicroseconds(150);
    if (spiRegRead(NRF_CS, 0x09, false) & 0x01) energy++;  // RPD
  }
  return energy;
}

// ---------------- CC1101: sub-GHz RSSI ----------------
bool ccPresent = false;
bool ccDetect() {
  return spiRegRead(CC110_CS, 0x30, true) == 0x14;  // VERSION
}
void ccInit() {
  ccStrobe(CC110_CS, 0x36);                        // SIDLE
  uint32_t f = (uint32_t)((CC1101_FREQ_HZ * 65536.0) / 26000000.0);
  spiRegWrite(CC110_CS, 0x0D, (f >> 16) & 0xFF, true);  // FREQ2
  spiRegWrite(CC110_CS, 0x0E, (f >> 8) & 0xFF, true);   // FREQ1
  spiRegWrite(CC110_CS, 0x0F, f & 0xFF, true);          // FREQ0
  ccStrobe(CC110_CS, 0x34);                        // SRX
}
float ccRssiDbm() {
  uint8_t raw = spiRegRead(CC110_CS, 0xF4, true);   // RSSI (burst read)
  int v = (int)raw;
  float dbm = (v >= 128 ? (v - 256) : v) / 2.0f - 74.0f;
  return dbm;
}

// ---------------- UART generic sensor input ----------------
// Any attached module can stream:  SENSOR <name> <rssi_dbm> [detail]
char uartLine[96]; int uartPos = 0;
void uartPoll(uint32_t now) {
  while (Serial2.available()) {
    char c = (char)Serial2.read();
    if (c == '\n' || uartPos >= (int)sizeof(uartLine) - 1) {
      uartLine[uartPos] = 0; uartPos = 0;
      char name[16] = "", detail[32] = "";
      float rssi = 0;
      if (sscanf(uartLine, "SENSOR %15s %f %31s", name, &rssi, detail) >= 2) {
        UartCh *u = nullptr;
        for (auto &ch : uartCh) if (ch.used && !strcmp(ch.name, name)) u = &ch;
        if (!u) for (auto &ch : uartCh)
          if (!ch.used) {
            strncpy(ch.name, name, 15); ch.ch = SensorCh("uart", 3.5f);
            ch.used = true; u = &ch; break;
          }
        if (u) {
          float durS, depth; const char *cls;
          eventT0glob = now;
          if (u->ch.push(-rssi, now, durS, depth, cls))
            sendEvent(u->name, durS, depth, cls, 0.6f,
                      *detail ? detail : name);
        }
      }
    } else if (c != '\r') uartLine[uartPos++] = c;
  }
}

// ---------------- beacons / status ----------------
void sendBeacon(float fps) {
  char buf[384];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"beacon\",\"node\":\"%s\",\"ip\":\"%s\",\"ch\":%d,"
    "\"fps\":%.0f,\"events\":%lu,\"uptime_s\":%lu,"
    "\"sensors\":[%s],\"ble_seen\":%d}",
    nodeId, WiFi.softAPIP().toString().c_str(), WiFi.channel(), fps,
    (unsigned long)eventCount, (unsigned long)((millis() - bootMs) / 1000),
    sensorList, bleN);
  udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
  udp.write((uint8_t *)buf, strlen(buf));
  udp.endPacket();
}

void handleRoot() {
  char html[1400];
  snprintf(html, sizeof(html),
    "<html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<style>body{background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px}"
    "h1{color:#a855f7}.card{background:#1c1c22;padding:16px;border-radius:12px;margin:12px 0}</style>"
    "</head><body><h1>Shepherd Node %s</h1>"
    "<div class=card>Sensors: %s<br>Uptime %lu s &nbsp; Channel %d<br>"
    "WiFi metric %.1f dB &nbsp; BLE seen %d &nbsp; Events %lu</div>"
    "<div class=card>Join this AP from the Shepherd device.<br>"
    "Beacons + events on UDP %d.</div></body></html>",
    nodeId, sensorList, (unsigned long)((millis() - bootMs) / 1000),
    WiFi.channel(), lastWifiMetric, bleN, (unsigned long)eventCount,
    BEACON_PORT);
  server.send(200, "text/html", html);
}

void setup() {
  Serial.begin(115200);
  bootMs = millis();
  prefs.begin("shn", false);

  String nid = prefs.getString("node_id", "");
  if (nid.length() == 0) {
    uint8_t mac[6]; esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    char tmp[16]; snprintf(tmp, sizeof(tmp), "SHN-%02X%02X", mac[4], mac[5]);
    nid = tmp; prefs.putString("node_id", nid);
  }
  nid.toCharArray(nodeId, sizeof(nodeId));
  int ch = prefs.getInt("channel", DEFAULT_CH);
  String pass = prefs.getString("ap_pass", "shepherd-field");

  WiFi.mode(WIFI_AP);
  char ssid[24]; snprintf(ssid, sizeof(ssid), "Shepherd-%s", nodeId + 4);
  WiFi.softAP(ssid, pass.c_str(), ch);

  wifi_csi_config_t csi; memset(&csi, 0, sizeof(csi));
  csi.lltf_en = csi.htltf_en = csi.stbc_htltf2_en = true;
  csi.ltf_merge_en = csi.channel_filter_en = true;
  esp_wifi_set_csi_config(&csi);
  esp_wifi_set_csi_rx_cb(&csi_cb, NULL);
  wifiSniff(true);
  wifi_promiscuous_filter_t filt;
  filt.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT | WIFI_PROMIS_FILTER_MASK_DATA;
  esp_wifi_set_promiscuous_filter(&filt);

  BLEDevice::init("");

  // SPI module auto-detect
  pinMode(NRF_CS, OUTPUT); digitalWrite(NRF_CS, HIGH);
  pinMode(CC110_CS, OUTPUT); digitalWrite(CC110_CS, HIGH);
  SPI.begin(18, 19, 23);
  char sl[96] = "\"wifi\",\"ble\"";
  if (nrfDetect()) { nrfPresent = true; nrfInit(); strcat(sl, ",\"nrf24\"");
    Serial.println("nRF24L01 detected"); }
  if (ccDetect()) { ccPresent = true; ccInit(); strcat(sl, ",\"cc110\"");
    Serial.println("CC1101 detected"); }
  strncpy(sensorList, sl, sizeof(sensorList) - 1);

  Serial2.begin(115200, SERIAL_8N1, UART_RX, UART_TX);

  if (MDNS.begin(nodeId)) MDNS.addService("shepherd-node", "udp", BEACON_PORT);
  udp.begin(BEACON_PORT);
  server.on("/", handleRoot);
  server.begin();
  Serial.printf("node %s ready: %s\n", nodeId, sensorList);
}

void loop() {
  static uint32_t lastSec = 0, lastBeacon = 0, lastBle = 0, lastNrf = 0,
                  lastCc = 0;
  server.handleClient();
  uartPoll(millis());
  uint32_t now = millis();

  if (now - lastBle > BLE_EVERY_MS) { lastBle = now; bleScanOnce(); }

  if (now - lastSec >= 1000) {
    uint32_t f = g_frames; int32_t rs = g_rssiSum;
    g_frames = 0; g_rssiSum = 0;
    lastSec = now;
    if (f > 0) {
      float m = -((float)rs / (float)f);
      lastWifiMetric = m;
      float durS, depth; const char *cls;
      eventT0glob = now;
      if (chWifi.push(m, now, durS, depth, cls))
        sendEvent("wifi", durS, depth, cls, 0.70f, "");
    }
    if (nrfPresent && now - lastNrf > 5000) {
      lastNrf = now;
      float durS, depth; const char *cls;
      eventT0glob = now;
      if (chNrf.push((float)nrfSweep(), now, durS, depth, cls))
        sendEvent("nrf24", durS, depth, cls, 0.60f, "band-energy");
    }
    if (ccPresent && now - lastCc > 2000) {
      lastCc = now;
      float durS, depth; const char *cls;
      eventT0glob = now;
      if (chCc.push(-ccRssiDbm(), now, durS, depth, cls))
        sendEvent("cc110", durS, depth, cls, 0.60f, "subghz-rssi");
    }
  }

  if (now - lastBeacon > BEACON_MS) {
    lastBeacon = now;
    sendBeacon(0);   // fps tracked separately if needed
  }
  delay(10);
}
