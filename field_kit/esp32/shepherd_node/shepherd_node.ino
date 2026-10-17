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
 *             (compiled out when LD2450_ON — UART2 is either/or)
 *
 * OPTIONAL (compile flags below, all default OFF except GPS time sync)
 *   ld2450 - Hi-Link LD2450 24 GHz FMCW radar on UART2 @256000 baud.
 *            Tracks up to 3 targets with X/Y (metres). NEW_TARGET events
 *            on appearance, TRACK on big moves. UART2 becomes binary
 *            radar ONLY — the text SENSOR protocol is off in this build.
 *   imu    - MPU6050 motion-energy through the MAD detector. MOTION events
 *            mean THE CARRIER MOVED — context for the app (discount
 *            coincident detections), not an intrusion by itself.
 *   relay  - ESP-NOW hop-by-hop event relay toward the Shepherd host
 *            (dedup cache, TTL, TX time-sliced with the WiFi sniffer).
 *            The node your Shepherd device is joined to re-emits relayed
 *            events on UDP 49160, so a mesh of nodes funnels into one host.
 *   GPS time sync is ALWAYS compiled: a NEO-M8N-class module on Serial1
 *     with PPS on GPIO27 disciplines a microsecond event clock (t_us in
 *     events; lat/lon/pps in beacons). With no GPS attached everything
 *     silently falls back to the millis/micros clock.
 *
 * Compile flags (uncomment to enable):
 */
// #define LD2450_ON      // LD2450 radar on UART2 @256000 (either/or with text protocol)
// #define ESPNOW_RELAY   // ESP-NOW event relay mesh
// #define IMU_ON         // MPU6050 motion-energy channel

/*
 * Detection is local and deterministic (rolling baseline + MAD threshold,
 * baseline hold during events). The node broadcasts compact beacons and
 * events; Shepherd fuses them. Nothing here identifies anything — dips,
 * energy, and MAC hints, shown as estimates.
 *
 * Protocol (UDP broadcast, port 49160 — the Shepherd ESP32Driver listens):
 *   beacon: {"type":"beacon","node":"SHN-XXXX","ip":"192.168.4.1","ch":6,
 *            "fps":42,"events":3,"uptime_s":1234,
 *            "sensors":["wifi","ble","nrf24"],"ble_seen":5,
 *            "lat":12.345678,"lon":-45.123456,"pps":1}
 *            (lat/lon 0,0 and pps 0 when no GPS fix)
 *   event:  {"type":"event","node":"SHN-XXXX","sensor":"wifi","t0":1234,
 *            "t_us":1234567890123,"dur_s":5.2,"depth_db":6.1,
 *            "class":"PASSING","conf":0.7,"detail":""}
 *            (t_us = microsecond clock, PPS-disciplined when GPS present)
 *   relay (ESP-NOW only, never on UDP):
 *            {"type":"relay","id":12345,"ttl":4,"ev":{...event...}}
 *
 * Wiring (changeable below):
 *   VSPI: SCK=18 MISO=19 MOSI=23
 *   nRF24: CS=4, CE=22 (node holds CE high; CE hard-wired to 3V3 also OK,
 *     just leave GPIO22 unconnected)
 *   CC1101: CS=21
 *   UART2 (Serial2): RX=16 TX=17 — EITHER text SENSOR protocol @115200
 *     (default) OR LD2450 radar @256000 (LD2450_ON). Not both.
 *     LD2450 wiring: LD_TX -> GPIO16, LD_RX -> GPIO17, 5V, GND
 *     (LD2450 UART pins are 3.3V logic)
 *   GPS (Serial1): ESP_RX=25 <- GPS_TX, ESP_TX=26 -> GPS_RX, PPS=27
 *     (rising edge). NEO-M8N @9600 baud. Optional — silent when absent.
 *   IMU (IMU_ON): MPU6050 SDA=32 SCL=33, AD0 -> GND (addr 0x68), 3.3V.
 *   ESP-NOW relay: no extra wiring. All relaying nodes MUST share the
 *     same AP channel (prefs "channel", default 6).
 *
 * Polarity: nrf24 and cc110 report ENERGY, so an emitter appearing is a
 * rise and fires an event. The wifi channel reports -RSSI (a link dip is
 * a rise). UART lines are treated like wifi: SENSOR <name> <rssi_dbm>
 * fires when the reported RSSI FALLS; send the negative of an energy
 * reading if you want "emitter appeared" semantics.
 *
 * Honest scope: these are coarse tripwire layers, not lab instruments.
 * ESP32 CSI is a poor-man's link disturbance sensor; nRF24 RPD is a
 * 1-bit energy detector per channel; BLE MACs are often randomized, so
 * new-device events are hints, not identifications. The LD2450 is a $7
 * presence sensor (6 m, human-tuned firmware) — positions are coarse.
 * GPS gives node position and a disciplined clock, not target tracks.
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
#ifdef ESPNOW_RELAY
#include <esp_now.h>
#endif
#ifdef IMU_ON
#include <Wire.h>
#endif

// ---------------- configuration ----------------
#define BEACON_PORT   49160
#define STATUS_PORT   80
#define DEFAULT_CH    6
#define BEACON_MS     5000
#define BLE_EVERY_MS  60000
#define BLE_SCAN_S    6
#define CC1101_FREQ_HZ 433920000UL   // sub-GHz watch frequency
#define MAX_EVENT_MS  120000UL       // longest an event may stay open

// pins
#define NRF_CS   4
#define NRF_CE   22
#define CC110_CS 21
#define UART_RX  16
#define UART_TX  17
// GPS (Serial1) — always compiled, silent when no module attached
#define GPS_RX   25   // ESP32 RX <- GPS TX
#define GPS_TX   26   // ESP32 TX -> GPS RX
#define GPS_PPS  27   // PPS rising edge
#define GPS_BAUD 9600
#ifdef IMU_ON
#define IMU_SDA  32
#define IMU_SCL  33
#define MPU6050_ADDR 0x68
#endif
#ifdef LD2450_ON
#define LD2450_BAUD 256000
#endif
#ifdef ESPNOW_RELAY
#define RELAY_TTL      4
#define RELAY_FLUSH_MS 2000
#define RELAY_SEEN_N   32
#endif

Preferences prefs;
WebServer server(STATUS_PORT);
WiFiUDP udp;

char nodeId[16] = "SHN-????";
uint32_t bootMs = 0;
uint32_t eventCount = 0;
float lastWifiMetric = 0;

// sensors actually alive on this node (advertised in beacons)
char sensorList[128] = "wifi,ble";

// ---------------- microsecond event clock (PPS-disciplined) ----------------
// A GPS PPS rising edge marks an exact second boundary. Between edges we
// interpolate with micros(). With no GPS (no edges ever seen) this is
// just micros() — same clock, undisciplined.
volatile uint32_t ppsEdgeMicros = 0;
volatile uint32_t ppsEdges = 0;
static uint32_t ppsSeen = 0;
static uint64_t ppsBaseUs = 0;      // disciplined time at the last edge
static uint32_t ppsBaseMicros = 0;  // micros() value at the last edge

void IRAM_ATTR ppsIsr() {
  ppsEdgeMicros = micros();
  ppsEdges++;
}

// Microsecond node clock. Call from loop/task context, not from the ISR.
uint64_t nodeNowUs() {
  if (ppsSeen == 0) return (uint64_t)micros();
  uint32_t now = micros();
  return ppsBaseUs + (uint64_t)(now - ppsBaseMicros);  // wrap-safe
}

// ---------------- generic MAD channel ----------------
// One per sensor metric. push() returns true when an event just closed.
struct SensorCh {
  const char *name;
  float k;                       // MAD multiplier
  float hist[30]; int n = 0, i = 0;
  bool open = false;
  float peak = 0, base = 0;
  uint32_t t0 = 0, quiet = 0;
  uint64_t t0us = 0;             // microsecond event-start clock

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
        open = true; t0 = now; t0us = nodeNowUs(); peak = m; base = med;
        quiet = 0;
      } else if (open) {
        if (m > peak) peak = m;
        if (now - t0 > MAX_EVENT_MS) {
          // The level never came back (node moved, lasting interference).
          // Close the event and relearn the baseline at the new level;
          // otherwise the channel stays "open" forever and goes deaf.
          durS = (now - t0) / 1000.0f;
          depthDb = peak - base;
          cls = "LINGERING";
          open = false; closed = 1;
          n = 0; i = 0;
        } else if (m < med + (thr - med) * 0.5f) {
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
#ifdef IMU_ON
SensorCh chImu("imu", 4.0f);
#endif
struct UartCh { char name[16]; SensorCh ch; bool used = false; };
UartCh uartCh[4];

void sendEvent(const char *sensor, float durS, float depthDb,
               const char *cls, float conf, const char *detail);  // fwd
uint32_t eventT0glob = 0;
uint64_t eventT0usGlob = 0;

// Copy [src] into [dst] keeping only characters that are safe inside a
// JSON string. UART sensor names/details come from outside the node; a
// quote or backslash in one would corrupt the whole datagram.
static void jsonSafe(char *dst, size_t n, const char *src) {
  size_t o = 0;
  for (; src && *src && o + 1 < n; src++) {
    char c = *src;
    bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
              (c >= 'a' && c <= 'z') || c == ' ' || c == '_' || c == '.' ||
              c == ':' || c == '-' || c == '!' || c == '=' || c == ',';
    dst[o++] = ok ? c : '_';
  }
  dst[o] = 0;
}

#ifdef ESPNOW_RELAY
// ---- ESP-NOW relay: forward declarations (defined below) ----
void relayInit(char *sl);
void relayNoteLocal(const char *eventJson, const char *sensor, uint32_t t0);
void relayFlush();
#endif

void sendEvent(const char *sensor, float durS, float depthDb,
               const char *cls, float conf, const char *detail) {
  char buf[320], sSafe[32], dSafe[48];
  jsonSafe(sSafe, sizeof(sSafe), sensor);
  jsonSafe(dSafe, sizeof(dSafe), detail ? detail : "");
  // eventT0glob/eventT0usGlob are the event's START, set by the caller
  // from the channel; t0 is seconds since boot.
  uint32_t t0 = (eventT0glob - bootMs) / 1000;
  snprintf(buf, sizeof(buf),
    "{\"type\":\"event\",\"node\":\"%s\",\"sensor\":\"%s\",\"t0\":%lu,"
    "\"t_us\":%llu,\"dur_s\":%.1f,\"depth_db\":%.1f,\"class\":\"%s\","
    "\"conf\":%.2f,\"detail\":\"%s\"}",
    nodeId, sSafe, (unsigned long)t0, (unsigned long long)eventT0usGlob,
    durS, depthDb, cls, conf, dSafe);
  udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
  udp.write((uint8_t *)buf, strlen(buf));
  udp.endPacket();
#ifdef ESPNOW_RELAY
  relayNoteLocal(buf, sSafe, t0);
#endif
  eventCount++;
  Serial.printf("[%s] %s %.1fs %.1fdB %s\n", sSafe, cls, durS, depthDb,
                dSafe);
}

// ---------------- WiFi CSI sniffer ----------------
volatile uint32_t g_frames = 0;
volatile int32_t  g_rssiSum = 0;
// The CSI callback runs on the Wi-Fi task (other core); loop() reads and
// zeroes these once a second. Without the lock a frame landing between
// the read and the reset was silently lost.
portMUX_TYPE g_csiMux = portMUX_INITIALIZER_UNLOCKED;

void csi_cb(void *ctx, wifi_csi_info_t *data) {
  if (!data) return;
  portENTER_CRITICAL(&g_csiMux);
  g_frames++;
  g_rssiSum += data->rx_ctrl.rssi;
  portEXIT_CRITICAL(&g_csiMux);
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
      eventT0usGlob = nodeNowUs();
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
  // CC1101: config regs (0x00-0x2F) read with 0x80|addr; STATUS regs
  // (0x30-0x3D: PARTNUM, VERSION, RSSI...) need the burst bit as well
  // (0xC0|addr). Without it 0x30-0x3D are command strobes -- reading
  // "VERSION" that way never returned the version (and 0x30 is SRES).
  if (cc1101) {
    SPI.transfer((reg >= 0x30 ? 0xC0 : 0x80) | reg);
    v = SPI.transfer(0x00);
  }
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
  uint8_t v = spiRegRead(CC110_CS, 0x31, true);      // VERSION
  return v == 0x14 || v == 0x04;                      // 0x04 = older/clone
}
void ccInit() {
  ccStrobe(CC110_CS, 0x30);                        // SRES (reset)
  delay(5);
  ccStrobe(CC110_CS, 0x36);                        // SIDLE
  uint32_t f = (uint32_t)((CC1101_FREQ_HZ * 65536.0) / 26000000.0);
  spiRegWrite(CC110_CS, 0x0D, (f >> 16) & 0xFF, true);  // FREQ2
  spiRegWrite(CC110_CS, 0x0E, (f >> 8) & 0xFF, true);   // FREQ1
  spiRegWrite(CC110_CS, 0x0F, f & 0xFF, true);          // FREQ0
  ccStrobe(CC110_CS, 0x34);                        // SRX
}
float ccRssiDbm() {
  uint8_t raw = spiRegRead(CC110_CS, 0x34, true);   // RSSI status reg
  int v = (int)raw;
  float dbm = (v >= 128 ? (v - 256) : v) / 2.0f - 74.0f;
  return dbm;
}

#ifndef LD2450_ON
// ---------------- UART generic sensor input ----------------
// Any attached module can stream:  SENSOR <name> <rssi_dbm> [detail]
// (Compiled out when LD2450_ON: UART2 is the radar's in that build.)
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
          if (u->ch.push(-rssi, now, durS, depth, cls)) {
            eventT0glob = u->ch.t0;
            eventT0usGlob = u->ch.t0us;
            sendEvent(u->name, durS, depth, cls, 0.6f,
                      *detail ? detail : name);
          }
        }
      }
    } else if (c != '\r') uartLine[uartPos++] = c;
  }
}
#endif

#ifdef LD2450_ON
// ---------------- LD2450 24 GHz FMCW radar ----------------
// Hi-Link LD2450 on UART2 @256000 baud (EITHER/OR with the text SENSOR
// protocol above). Binary frames: AA FF 03 00, then 3 x 6-byte targets
// (X_lo X_hi Y_lo Y_hi SPD_lo SPD_hi, signed 16-bit, millimetres),
// then 55 CC. X==0 && Y==0 means "no target in this slot".
// Wiring: LD_TX -> GPIO16, LD_RX -> GPIO17, 5V, GND (3.3V logic).
struct LdSlot { bool present = false; float x = 0, y = 0;
                uint32_t lastReport = 0; };
LdSlot ldSlots[3];

void ld2450Report(int slot, float xm, float ym, uint32_t now,
                  const char *cls, float conf) {
  eventT0glob = now;
  eventT0usGlob = nodeNowUs();
  char det[24];
  snprintf(det, sizeof(det), "x=%.1f,y=%.1f", xm, ym);
  sendEvent("ld2450", 0, 0, cls, conf, det);
}

void ld2450Frame(uint8_t *d, uint32_t now) {
  for (int s = 0; s < 3; s++) {
    int16_t x = (int16_t)(d[s * 6] | (d[s * 6 + 1] << 8));
    int16_t y = (int16_t)(d[s * 6 + 2] | (d[s * 6 + 3] << 8));
    bool present = !(x == 0 && y == 0);
    float xm = x / 1000.0f, ym = y / 1000.0f;
    LdSlot &sl = ldSlots[s];
    if (present && !sl.present) {
      sl.present = true; sl.x = xm; sl.y = ym; sl.lastReport = now;
      ld2450Report(s, xm, ym, now, "NEW_TARGET", 0.60f);
    } else if (present && sl.present) {
      float dx = xm - sl.x, dy = ym - sl.y;
      if (dx * dx + dy * dy > 1.0f && now - sl.lastReport > 5000) {
        sl.x = xm; sl.y = ym; sl.lastReport = now;
        ld2450Report(s, xm, ym, now, "TRACK", 0.55f);
      }
    } else if (!present && sl.present) {
      sl.present = false;   // lost target: stay quiet
    }
  }
}

void ld2450Poll(uint32_t now) {
  // byte-wise frame sync: AA FF 03 00 ...18 bytes... 55 CC
  static uint8_t state = 0;
  static uint8_t data[18];
  static int di = 0;
  while (Serial2.available()) {
    uint8_t b = (uint8_t)Serial2.read();
    switch (state) {
      case 0: state = (b == 0xAA) ? 1 : 0; break;
      case 1: state = (b == 0xFF) ? 2 : (b == 0xAA ? 1 : 0); break;
      case 2: state = (b == 0x03) ? 3 : 0; break;
      case 3: state = (b == 0x00) ? 4 : 0; di = 0; break;
      case 4: data[di++] = b; if (di >= 18) state = 5; break;
      case 5: state = (b == 0x55) ? 6 : 0; break;
      case 6:
        if (b == 0xCC) ld2450Frame(data, now);
        state = 0;
        break;
    }
  }
}
#endif

// ---------------- GPS: NMEA position + PPS-disciplined clock ----------------
// NEO-M8N-class module on Serial1 (RX=25 <- GPS TX, TX=26 -> GPS RX,
// PPS=27 rising). Always compiled; with no module attached nothing
// arrives, no PPS edges are ever seen, and the node silently uses the
// local micros() clock with lat/lon 0,0 and pps 0 in beacons.
char nmeaLine[96]; int nmeaPos = 0;
double gpsLat = 0, gpsLon = 0;
bool gpsFix = false;

static double nmeaToDeg(double v) {
  int deg = (int)(v / 100);
  double minutes = v - deg * 100;
  return deg + minutes / 60.0;
}

void gpsPoll() {
  // Fold newly arrived PPS edges into the disciplined clock.
  uint32_t e = ppsEdges;
  if (e != ppsSeen) {
    ppsBaseUs += (uint64_t)(e - ppsSeen) * 1000000ULL;
    ppsBaseMicros = ppsEdgeMicros;
    ppsSeen = e;
  }
  // NMEA: we only need $GxGGA for position + fix quality.
  while (Serial1.available()) {
    char c = (char)Serial1.read();
    if (c == '\n' || nmeaPos >= (int)sizeof(nmeaLine) - 1) {
      nmeaLine[nmeaPos] = 0; nmeaPos = 0;
      if (strncmp(nmeaLine, "$GPGGA,", 7) == 0 ||
          strncmp(nmeaLine, "$GNGGA,", 7) == 0) {
        // fields: 0=id 1=time 2=lat 3=N/S 4=lon 5=E/W 6=quality
        const char *f[8] = {0};
        int fi = 0;
        for (char *p = nmeaLine; *p && fi < 8; p++) {
          if (*p == ',') { *p = 0; f[fi++] = p + 1; }
        }
        // f[1]=lat f[2]=N/S f[3]=lon f[4]=E/W f[5]=quality
        // (f[0] is the text after the first comma)
        if (fi >= 6 && f[1] && f[2] && f[3] && f[4] && f[5] &&
            *f[1] && *f[3]) {
          int q = atoi(f[5]);
          if (q > 0) {
            double la = nmeaToDeg(atof(f[1]));
            double lo = nmeaToDeg(atof(f[3]));
            if (*f[2] == 'S') la = -la;
            if (*f[4] == 'W') lo = -lo;
            gpsLat = la; gpsLon = lo; gpsFix = true;
          } else {
            gpsFix = false;
          }
        }
      }
    } else if (c != '\r') nmeaLine[nmeaPos++] = c;
  }
}

#ifdef ESPNOW_RELAY
// ---------------- ESP-NOW event relay ----------------
// Events hop node-to-node toward the Shepherd host. Every relaying node
// must share the same AP channel. Dedup (32-entry seen-ID cache) plus a
// TTL stops broadcast storms. TX is time-sliced: packets queue up and
// flush every RELAY_FLUSH_MS with the WiFi sniffer briefly paused, like
// the BLE time-slice. The node your Shepherd device is joined to also
// re-emits each relayed event on UDP 49160, so the mesh funnels into
// one host. RX-only Shepherd stays RX-only: this radio path never
// transmits anything but other nodes' event packets.
uint8_t relayBcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
uint32_t relaySeen[RELAY_SEEN_N];
int relaySeenN = 0, relaySeenI = 0;
char relayOut[4][352]; int relayOutN = 0;

static uint32_t relayId(const char *node, const char *sensor, uint32_t t0) {
  uint32_t h = 2166136261UL;   // FNV-1a
  const char *p;
  for (p = node; *p; p++) { h ^= (uint8_t)*p; h *= 16777619UL; }
  for (p = sensor; *p; p++) { h ^= (uint8_t)*p; h *= 16777619UL; }
  for (int i = 0; i < 4; i++) { h ^= (t0 >> (i * 8)) & 0xFF; h *= 16777619UL; }
  return h;
}
static bool relaySeenId(uint32_t id) {
  for (int i = 0; i < relaySeenN; i++) if (relaySeen[i] == id) return true;
  return false;
}
static void relayRemember(uint32_t id) {
  relaySeen[relaySeenI] = id;
  relaySeenI = (relaySeenI + 1) % RELAY_SEEN_N;
  if (relaySeenN < RELAY_SEEN_N) relaySeenN++;
}
static void relayQueuePkt(uint32_t id, int ttl, const char *evJson) {
  if (relayOutN >= 4) return;   // saturated: drop, don't block
  snprintf(relayOut[relayOutN], sizeof(relayOut[0]),
           "{\"type\":\"relay\",\"id\":%lu,\"ttl\":%d,\"ev\":%s}",
           (unsigned long)id, ttl, evJson);
  relayOutN++;
}
// Called from sendEvent for every LOCAL event: remember the id (so the
// mesh echo of our own event is dropped) and queue it for relay.
void relayNoteLocal(const char *eventJson, const char *sensor, uint32_t t0) {
  uint32_t id = relayId(nodeId, sensor, t0);
  if (relaySeenId(id)) return;
  relayRemember(id);
  relayQueuePkt(id, RELAY_TTL, eventJson);
}
// Minimal field extraction from a relay packet: id, ttl, and the inner
// event object (brace-matched, so nested content is safe).
static bool relayExtract(const char *p, uint32_t &id, int &ttl,
                         const char *&ev, int &evLen) {
  const char *pi = strstr(p, "\"id\":");
  const char *pt = strstr(p, "\"ttl\":");
  const char *pe = strstr(p, "\"ev\":");
  if (!pi || !pt || !pe) return false;
  id = strtoul(pi + 5, NULL, 10);
  ttl = atoi(pt + 6);
  const char *b = strchr(pe + 5, '{');
  if (!b) return false;
  int depth = 0;
  const char *q = b;
  while (*q) {
    if (*q == '{') depth++;
    else if (*q == '}') { depth--; if (depth == 0) break; }
    q++;
  }
  if (depth != 0 || *q != '}') return false;
  ev = b; evLen = (int)(q - b + 1);
  return true;
}
void onRelayRecv(const uint8_t *mac, const uint8_t *data, int len) {
  (void)mac;
  if (len <= 0 || len >= 512) return;
  static char tmp[512];
  memcpy(tmp, data, len); tmp[len] = 0;
  uint32_t id; int ttl; const char *ev; int evLen;
  if (!relayExtract(tmp, id, ttl, ev, evLen)) return;
  if (relaySeenId(id)) return;    // already forwarded: drop
  relayRemember(id);
  // Re-emit on this node's LAN so the Shepherd host joined here sees it.
  udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
  udp.write((uint8_t *)ev, evLen);
  udp.endPacket();
  // Forward with decremented TTL.
  if (ttl > 1 && relayOutN < 4) {
    char evJson[320];
    int n = evLen < (int)sizeof(evJson) - 1 ? evLen : (int)sizeof(evJson) - 1;
    memcpy(evJson, ev, n); evJson[n] = 0;
    relayQueuePkt(id, ttl - 1, evJson);
  }
}
void relayFlush() {
  if (relayOutN == 0) return;
  wifiSniff(false);   // radio time-slice, like the BLE scan
  for (int i = 0; i < relayOutN; i++)
    esp_now_send(relayBcast, (uint8_t *)relayOut[i], strlen(relayOut[i]));
  relayOutN = 0;
  wifiSniff(true);
}
void relayInit(char *sl) {
  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW init failed; relay off");
    return;
  }
  esp_now_register_recv_cb(onRelayRecv);
  esp_now_peer_info_t peer;
  memset(&peer, 0, sizeof(peer));
  memcpy(peer.peer_addr, relayBcast, 6);
  peer.channel = WiFi.channel();
  peer.encrypt = false;
  if (esp_now_add_peer(&peer) != ESP_OK) {
    Serial.println("ESP-NOW peer add failed; relay off");
    return;
  }
  strcat(sl, ",\"relay\"");
  Serial.println("ESP-NOW relay on");
}
#endif

#ifdef IMU_ON
// ---------------- MPU6050 motion-energy ----------------
// Streams |a|-1g (g units) through the MAD detector. A walking carrier
// produces sustained motion energy; a passing intruder does not move
// the node. MOTION events are CONTEXT — the app should discount
// coincident RF detections, not treat motion as an intrusion.
bool imuPresent = false;

static void imuRegWrite(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(reg); Wire.write(val);
  Wire.endTransmission();
}
bool imuInit() {
  Wire.begin(IMU_SDA, IMU_SCL);
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x75);                       // WHO_AM_I
  if (Wire.endTransmission(false) != 0) return false;
  Wire.requestFrom(MPU6050_ADDR, (uint8_t)1);
  if (!Wire.available() || Wire.read() != 0x68) return false;
  imuRegWrite(0x6B, 0x00);                // PWR_MGMT_1: wake
  return true;
}
// Returns motion energy in g, or -1 on read failure.
float imuMotion() {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(0x3B);                       // ACCEL_XOUT_H
  if (Wire.endTransmission(false) != 0) return -1;
  Wire.requestFrom(MPU6050_ADDR, (uint8_t)6);
  if (Wire.available() < 6) return -1;
  int16_t ax = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t ay = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t az = (int16_t)((Wire.read() << 8) | Wire.read());
  float fx = ax / 16384.0f, fy = ay / 16384.0f, fz = az / 16384.0f;
  return fabsf(sqrtf(fx * fx + fy * fy + fz * fz) - 1.0f);
}
void imuSample(uint32_t now) {
  float m = imuMotion();
  if (m < 0) return;                      // read failed: skip quietly
  float durS, depth; const char *cls;
  if (chImu.push(m, now, durS, depth, cls)) {
    eventT0glob = chImu.t0;
    eventT0usGlob = chImu.t0us;
    sendEvent("imu", durS, depth, "MOTION", 0.50f, "");
  }
}
#endif

// ---------------- beacons / status ----------------
void sendBeacon(float fps) {
  char buf[448];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"beacon\",\"node\":\"%s\",\"ip\":\"%s\",\"ch\":%d,"
    "\"fps\":%.0f,\"events\":%lu,\"uptime_s\":%lu,"
    "\"sensors\":[%s],\"ble_seen\":%d,"
    "\"lat\":%.6f,\"lon\":%.6f,\"pps\":%d}",
    nodeId, WiFi.softAPIP().toString().c_str(), WiFi.channel(), fps,
    (unsigned long)eventCount, (unsigned long)((millis() - bootMs) / 1000),
    sensorList, bleN, gpsLat, gpsLon, ppsSeen > 0 ? 1 : 0);
  udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
  udp.write((uint8_t *)buf, strlen(buf));
  udp.endPacket();
}

void handleRoot() {
  char html[1600];
  snprintf(html, sizeof(html),
    "<html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<style>body{background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px}"
    "h1{color:#a855f7}.card{background:#1c1c22;padding:16px;border-radius:12px;margin:12px 0}</style>"
    "</head><body><h1>Shepherd Node %s</h1>"
    "<div class=card>Sensors: %s<br>Uptime %lu s &nbsp; Channel %d<br>"
    "WiFi metric %.1f dB &nbsp; BLE seen %d &nbsp; Events %lu</div>"
    "<div class=card>GPS: %s &nbsp; PPS: %s<br>Lat %.6f Lon %.6f</div>"
    "<div class=card>Join this AP from the Shepherd device.<br>"
    "Beacons + events on UDP %d.</div></body></html>",
    nodeId, sensorList, (unsigned long)((millis() - bootMs) / 1000),
    WiFi.channel(), lastWifiMetric, bleN, (unsigned long)eventCount,
    gpsFix ? "fix" : "no fix", ppsSeen > 0 ? "locked" : "free-run",
    gpsLat, gpsLon, BEACON_PORT);
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
  // nRF24 only measures RPD while CE is high in RX mode.
  pinMode(NRF_CE, OUTPUT); digitalWrite(NRF_CE, HIGH);
  pinMode(CC110_CS, OUTPUT); digitalWrite(CC110_CS, HIGH);
  SPI.begin(18, 19, 23);
  char sl[128] = "\"wifi\",\"ble\"";
  if (nrfDetect()) { nrfPresent = true; nrfInit(); strcat(sl, ",\"nrf24\"");
    Serial.println("nRF24L01 detected"); }
  if (ccDetect()) { ccPresent = true; ccInit(); strcat(sl, ",\"cc110\"");
    Serial.println("CC1101 detected"); }

#ifdef LD2450_ON
  // UART2 is the radar's in this build (either/or with text protocol).
  Serial2.begin(LD2450_BAUD, SERIAL_8N1, UART_RX, UART_TX);
  strcat(sl, ",\"ld2450\"");
  Serial.println("LD2450 radar on UART2 @256000");
#else
  Serial2.begin(115200, SERIAL_8N1, UART_RX, UART_TX);
#endif

  // GPS: always wired up, silent when no module answers.
  Serial1.begin(GPS_BAUD, SERIAL_8N1, GPS_RX, GPS_TX);
  pinMode(GPS_PPS, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(GPS_PPS), ppsIsr, RISING);

#ifdef IMU_ON
  if (imuInit()) {
    imuPresent = true;
    strcat(sl, ",\"imu\"");
    Serial.println("MPU6050 IMU detected");
  } else {
    Serial.println("MPU6050 not found");
  }
#endif

#ifdef ESPNOW_RELAY
  relayInit(sl);
#endif

  strncpy(sensorList, sl, sizeof(sensorList) - 1);

  if (MDNS.begin(nodeId)) MDNS.addService("shepherd-node", "udp", BEACON_PORT);
  udp.begin(BEACON_PORT);
  server.on("/", handleRoot);
  server.begin();
  Serial.printf("node %s ready: %s\n", nodeId, sensorList);
}

void loop() {
  static uint32_t lastSec = 0, lastBeacon = 0, lastBle = 0, lastNrf = 0,
                  lastCc = 0;
#ifdef IMU_ON
  static uint32_t lastImu = 0;
#endif
#ifdef ESPNOW_RELAY
  static uint32_t lastRelayFlush = 0;
#endif
  uint32_t now = millis();
  server.handleClient();
  gpsPoll();                       // PPS discipline + NMEA (cheap)
#ifdef LD2450_ON
  ld2450Poll(now);
#else
  uartPoll(now);
#endif
#ifdef IMU_ON
  if (imuPresent && now - lastImu >= 100) {
    lastImu = now;
    imuSample(now);
  }
#endif
#ifdef ESPNOW_RELAY
  if (now - lastRelayFlush > RELAY_FLUSH_MS) {
    lastRelayFlush = now;
    relayFlush();
  }
#endif

  if (now - lastBle > BLE_EVERY_MS) { lastBle = now; bleScanOnce(); }

  if (now - lastSec >= 1000) {
    portENTER_CRITICAL(&g_csiMux);
    uint32_t f = g_frames; int32_t rs = g_rssiSum;
    g_frames = 0; g_rssiSum = 0;
    portEXIT_CRITICAL(&g_csiMux);
    lastSec = now;
    if (f > 0) {
      float m = -((float)rs / (float)f);
      lastWifiMetric = m;
      float durS, depth; const char *cls;
      if (chWifi.push(m, now, durS, depth, cls)) {
        eventT0glob = chWifi.t0;
        eventT0usGlob = chWifi.t0us;
        sendEvent("wifi", durS, depth, cls, 0.70f, "");
      }
    }
    if (nrfPresent && now - lastNrf > 5000) {
      lastNrf = now;
      float durS, depth; const char *cls;
      if (chNrf.push((float)nrfSweep(), now, durS, depth, cls)) {
        eventT0glob = chNrf.t0;
        eventT0usGlob = chNrf.t0us;
        sendEvent("nrf24", durS, depth, cls, 0.60f, "band-energy");
      }
    }
    if (ccPresent && now - lastCc > 2000) {
      lastCc = now;
      float durS, depth; const char *cls;
      // +RSSI: an emitter appearing RAISES it (the old -RSSI only fired
      // when a signal disappeared, the opposite of the nrf24 channel).
      if (chCc.push(ccRssiDbm(), now, durS, depth, cls)) {
        eventT0glob = chCc.t0;
        eventT0usGlob = chCc.t0us;
        sendEvent("cc110", durS, depth, cls, 0.60f, "subghz-rssi");
      }
    }
  }

  if (now - lastBeacon > BEACON_MS) {
    lastBeacon = now;
    sendBeacon(0);   // fps tracked separately if needed
  }
  delay(10);
}
