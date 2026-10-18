/*
 * Shepherd Node — ESP32 field sensor firmware
 *
 * Flash once. Afterwards every USB plug-in is just power: the node boots,
 * hosts its own WiFi AP, and runs every sensor it can find:
 *
 *   BUILT-IN (always on)
 *     wifi  - WiFi CSI/RSSI promiscuous sniffer + edge tripwire detector
 *             (+ Suzuki CSI motion channel: symmetric-pair phase averaging
 *             per frame, 1 s Hz-deviation, wind-gated; with no WIND source
 *             the motion features stay DISABLED — RSSI tripwire unaffected)
 *     ble   - BLE advertisement scanner (time-sliced; new-device events)
 *   SPI (auto-detected at boot — enabled only if the module answers)
 *     nrf24 - nRF24L01 2.4 GHz band-energy sweep (RPD across ch 0..125)
 *     cc110 - CC1101 sub-GHz RSSI (default 433.92 MHz, changeable)
 *   UART (generic — any external module can stream readings in)
 *     uart  - Serial2 text protocol:  SENSOR <name> <rssi_dbm> [detail]
 *                                     WIND <name> <wind_ms> [gust_ms]
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
// #define CSI_BENCH      // CSI frame-rate bench (docs/validation_benches_spec.md
//                        // Part B). COMPILE FLAG ONLY, OFF BY DEFAULT, NEVER
//                        // in a shipping build: pushes CSI amplitude reports
//                        // at 100/250/500/1000 Hz over UDP 49160 with seq
//                        // numbers, 60 s per step. Build with:
//                        //   --build-property build.extra_flags="-DCSI_BENCH"

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
 *            "lat":12.345678,"lon":-45.123456,"pps":1,
 *            "rdrop":0,"rch_warn":0,"calib":0}
 *            (calib 1 = node is participating in the app's vacant-window
 *            calibration (docs/adaptive_baseline_spec.md). RAM-only,
 *            cleared on boot and auto-expired after 3 min — a node that
 *            reboots mid-window never contaminates the fit.)
 *            (lat/lon 0,0 and pps 0 when no GPS fix/lock; rdrop counts
 *            relay packets dropped (oversize/queue-full/send-fail);
 *            rch_warn 1 = AP channel != relay_ch pref)
 *   event:  {"type":"event","node":"SHN-XXXX","sensor":"wifi","t0":1234,
 *            "t_us":1234567890123,"dur_s":5.2,"depth_db":6.1,
 *            "class":"PASSING","conf":0.7,"detail":""}
 *            (t_us = microsecond clock: UTC-epoch-aligned when GPS locked
 *            (pps:1), node-local boot-relative otherwise — never compare
 *            t_us across unlocked nodes. MOTION events carry
 *            "context":true; consumers must filter on sensor+class or
 *            the context flag, never on conf alone.)
 *   sensor_obs (UDP 49160, 1 Hz, additive):
 *            {"type":"sensor_obs","obs":"CSI","node":"SHN-XXXX",
 *            "sensor":"csi_wifi","dev_hz":12.4,"pairs_active":19,
 *            "path_loss_db":54.0,"link":"wifi_ch6","wind_ms":1.8,
 *            "wind_gated":false,"lat":..,"lon":..,"t":..}
 *            dev_hz = max per-pair Hz-deviation of the Suzuki-averaged
 *            phase (docs/esp32_csi_pipeline_spec.md). dev_hz bands are
 *            SIZE-CLASS HEURISTICS for the app's merger — never identity
 *            claims; the 55/60 dB link-budget knees are app-side gates,
 *            never firmware. path_loss_db is a crude firmware placeholder
 *            (assumes 20 dBm TX on sniffed frames; -1 = unknown) — the app
 *            re-derives the real per-link budget. wind_gated:true with
 *            wind_ms:-1 means NO WIND SOURCE: CSI motion features are
 *            DISABLED by default (fail-safe); while wind_gated is true
 *            dev_hz is 0.0 and pairs_active 0 ON THE WIRE (defense in
 *            depth — a consumer ignoring the flag sees no claim; the
 *            flag itself is still present). The RSSI tripwire is
 *            unaffected. t follows the t_us clock caveat above.
 *            {"type":"sensor_obs","obs":"WIND","node":"SHN-XXXX",
 *            "sensor":"anem1","wind_ms":4.2,"gust_ms":6.1,"t":..}
 *            — forwarded when a WIND line arrives on UART (see below).
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
 *     same AP channel (prefs "channel", default 6). Set the "relay_ch"
 *     pref to flag a mismatch: "rch_warn":1 appears in beacons and the
 *     host app should surface it (a mismatch is a silent mesh island).
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
#include "driver/gpio.h"   // gpio_pullup_en for the floating GPS RX pin
#ifdef CSI_BENCH
#include "esp_timer.h"
#include "esp_freertos_hooks.h"
#endif
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
// Operator callsign ("RAPTOR-1"), broadcast in beacons. Set from the
// status page (/callsign?c=...), stored in Preferences.
char nodeCallsign[17] = "";
uint32_t bootMs = 0;
uint32_t eventCount = 0;
float lastWifiMetric = 0;
float lastCsiDevHz = 0;    // last 1 s CSI aggregation (status page)
int lastCsiPairs = 0;

// Vacant-window calibration participation (docs/adaptive_baseline_spec.md):
// RAM-only, cleared on every boot — a node that reboots mid-window must
// NOT contaminate the app's fit, so this is never persisted and the app
// must re-confirm via /calib?v=1 after any reboot. Auto-expires after
// 3 min without a refresh.
bool calibActive = false;
uint32_t calibSetMs = 0;

// sensors actually alive on this node (advertised in beacons)
char sensorList[128] = "wifi,ble";

// ---------------- microsecond event clock (PPS-disciplined) ----------------
// A GPS PPS rising edge marks an exact second boundary. Between edges we
// interpolate with micros(). With no GPS (no edges ever seen) this is a
// 64-bit wrap-extended micros() — same rate, undisciplined.
//
// Lock discipline (M8): ppsLocked is true only after 3 consecutive
// ~1 s-spaced edges, and drops if no edge arrives for >2.5 s. A single
// spurious edge (e.g. from the GPIO27 pull-up at boot on a floating pin)
// can therefore never read as "locked".
//
// Epoch (M9): each folded edge advances the clock by exactly 1 s. While
// locked, every valid $GxRMC snaps the clock to the UTC epoch — the RMC
// timestamp labels the second whose PPS edge fired most recently
// (u-blox sends PPS at top-of-second, then the sentence within the same
// second). Two GPS-locked nodes thus share the UTC epoch and their t_us
// values ARE comparable. Without lock, t_us is node-local monotonic
// (boot-relative) and MUST NOT be compared across nodes.
volatile uint32_t ppsEdgeMicros = 0;
volatile uint32_t ppsEdges = 0;
static uint32_t ppsSeen = 0;
static uint64_t ppsBaseUs = 0;      // disciplined time at the last edge
static uint32_t ppsBaseMicros = 0;  // micros() value at the last edge
static uint32_t ppsLockN = 0;       // consecutive sane-spaced edges
static uint32_t ppsPrevEdgeMicros = 0;
static uint32_t ppsLastEdgeMs = 0;  // millis() at the last folded edge
static bool ppsLocked = false;
portMUX_TYPE g_ppsMux = portMUX_INITIALIZER_UNLOCKED;

void IRAM_ATTR ppsIsr() {
  ppsEdgeMicros = micros();
  ppsEdges++;
}

// micros() extended to 64 bits across the ~71 min wrap (M7). Must run at
// least once per wrap period; gpsPoll() calls it every loop iteration.
uint64_t micros64() {
  static uint32_t last = 0;
  static uint64_t high = 0;
  uint32_t r = micros();
  if (r < last) high += 0x100000000ULL;
  last = r;
  return high | r;
}

// Fold newly seen PPS edges into the disciplined clock. Loop context.
static void ppsFold() {
  // seqlock: the ISR may fire between the two volatile reads
  uint32_t e1, em, e2;
  do { e1 = ppsEdges; em = ppsEdgeMicros; e2 = ppsEdges; } while (e1 != e2);
  if (e1 == ppsSeen) return;
  uint32_t gap = em - ppsPrevEdgeMicros;      // wrap-safe, microseconds
  bool sane = (ppsSeen > 0) && gap >= 700000UL && gap <= 1500000UL;
  ppsLockN = sane ? ppsLockN + 1 : 1;
  ppsPrevEdgeMicros = em;
  if (ppsLockN >= 3) ppsLocked = true;
  portENTER_CRITICAL(&g_ppsMux);
  if (ppsSeen == 0) ppsBaseUs = (uint64_t)em;  // M6: seed from the first
                                              // edge, never accumulate from 0
  else ppsBaseUs += (uint64_t)(e1 - ppsSeen) * 1000000ULL;
  ppsBaseMicros = em;
  portEXIT_CRITICAL(&g_ppsMux);
  ppsSeen = e1;
  ppsLastEdgeMs = millis();
}

// Microsecond node clock. Call from loop/task context, not from the ISR.
uint64_t nodeNowUs() {
  if (ppsSeen == 0) return micros64();   // M7: wrap-extended, no GPS
  uint64_t base; uint32_t baseM;
  portENTER_CRITICAL(&g_ppsMux);          // 64-bit torn-read guard
  base = ppsBaseUs; baseM = ppsBaseMicros;
  portEXIT_CRITICAL(&g_ppsMux);
  return base + (uint64_t)(micros() - baseM);  // wrap-safe delta
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
               const char *cls, float conf, const char *detail,
               bool context = false);  // fwd
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
               const char *cls, float conf, const char *detail,
               bool context) {
  char buf[352], sSafe[32], dSafe[48];
  jsonSafe(sSafe, sizeof(sSafe), sensor);
  jsonSafe(dSafe, sizeof(dSafe), detail ? detail : "");
  // eventT0glob/eventT0usGlob are the event's START, set by the caller
  // from the channel; t0 is seconds since boot.
  uint32_t t0 = (eventT0glob - bootMs) / 1000;
  snprintf(buf, sizeof(buf),
    "{\"type\":\"event\",\"node\":\"%s\",\"sensor\":\"%s\",\"t0\":%lu,"
    "\"t_us\":%llu,\"dur_s\":%.1f,\"depth_db\":%.1f,\"class\":\"%s\","
    "\"conf\":%.2f,\"detail\":\"%s\"%s}",
    nodeId, sSafe, (unsigned long)t0, (unsigned long long)eventT0usGlob,
    durS, depthDb, cls, conf, dSafe, context ? ",\"context\":true" : "");
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

#ifdef CSI_BENCH
// ---------------- CSI frame-rate bench (Part B, validation_benches_spec.md) ----
// COMPILE FLAG ONLY (-DCSI_BENCH), OFF BY DEFAULT, NEVER IN A SHIPPING
// BUILD. Measures the raw CSI-report pipeline: pushes CSI amplitude
// reports at stepped offered rates 100 -> 250 -> 500 -> 1000 frames/s
// over UDP 49160 with sequence numbers, 60 s per step. Each datagram
// carries the latest real CSI amplitude vector when one arrived in the
// last 500 ms ("syn":0), else a synthetic ramp ("syn":1) so the OFFERED
// rate is exact and reproducible. The RECEIVING host computes the
// sustained rate and drop % from the sequence numbers; the node logs
// offered/sent/send-fail/pending-drops + per-core CPU (idle-hook method)
// + heap low-water + ambient CSI fps per step over Serial:
//   {"type":"csi_bench","step":2,"hz":500,"seq":12345,"t_us":...,
//    "syn":0,"a":"<128 hex chars: 64 subcarrier amplitudes>"}
// What this measures: serialization + UDP + callback cost with the FULL
// production stack (tripwire, CSI pipeline, beacons) still running. It is
// a frame-rate feasibility number ONLY — never a localization result.
// CPU method: per-core FreeRTOS idle-hook counters; a 3 s calm phase at
// bench start calibrates idle counts/sec, then
// cpu% = 100*(1 - idle_this_sec/idle_base). Task-watchdog events: the
// task WDT is deliberately NOT enabled here (a UDP-burst stall would
// reset the node mid-bench); liveness is the ambient csi_fps column —
// frames flowing means the Wi-Fi task lives. Auto-starts 15 s after
// boot; when the flag is off, none of this exists (zero impact on the
// production 1 s tripwire cadence).

#define BENCH_NSTEPS 4
const int BENCH_HZ[BENCH_NSTEPS] = {100, 250, 500, 1000};
#define BENCH_STEP_MS 60000UL
#define BENCH_CALM_MS 3000UL
#define BENCH_AUTOSTART_MS 15000UL

uint8_t benchAmp[64];          // latest real per-subcarrier amplitudes
bool benchAmpFresh = false;
uint32_t benchAmpMs = 0;

struct BenchState {
  bool running = false, done = false, calm = false;
  int step = 0;
  uint32_t stepStartMs = 0, autoStartMs = 0, calmStartMs = 0;
  uint32_t seq = 0, offered = 0, sent = 0, sendFail = 0, pendDrop = 0;
  uint32_t idleBase[2] = {0, 0};
  uint32_t idlePrev[2] = {0, 0};
  uint32_t calmIdle[2] = {0, 0};
  uint32_t cpuSum[2] = {0, 0};
  int cpuN = 0;
  uint32_t heapMin = 0, csiFpsSum = 0;
  int fpsN = 0;
  volatile uint32_t idleCnt[2] = {0, 0};
};
BenchState bench;
volatile uint32_t benchPending = 0;   // timer ticks awaiting datagrams
esp_timer_handle_t benchTimer = NULL;

static bool IRAM_ATTR benchIdle0() { bench.idleCnt[0]++; return false; }
static bool IRAM_ATTR benchIdle1() { bench.idleCnt[1]++; return false; }
static void IRAM_ATTR benchTickIsr(void *arg) {
  (void)arg;
  benchPending++;   // offered is counted when the tick is drained/sent
}

// fwd: g_csiMux is declared just below (CSI section)
extern portMUX_TYPE g_csiMux;

static void benchSendOne() {
  bench.offered++;
  bench.seq++;
  // Payload: latest real amplitudes if fresh, else a synthetic ramp.
  uint8_t a[64];
  bool syn = true;
  uint32_t nowMs = millis();
  if (benchAmpFresh && nowMs - benchAmpMs < 500) {
    portENTER_CRITICAL(&g_csiMux);   // csi_cb may be writing benchAmp
    memcpy(a, benchAmp, 64);
    portEXIT_CRITICAL(&g_csiMux);
    syn = false;
  } else {
    for (int i = 0; i < 64; i++) a[i] = (uint8_t)((i * 4) & 0xFF);
  }
  static const char *hd = "0123456789abcdef";
  char hex[129];
  for (int i = 0; i < 64; i++) {
    hex[2 * i] = hd[a[i] >> 4]; hex[2 * i + 1] = hd[a[i] & 15];
  }
  hex[128] = 0;
  char buf[320];
  int n = snprintf(buf, sizeof(buf),
    "{\"type\":\"csi_bench\",\"step\":%d,\"hz\":%d,\"seq\":%lu,"
    "\"t_us\":%llu,\"syn\":%d,\"a\":\"%s\"}",
    bench.step, BENCH_HZ[bench.step], (unsigned long)bench.seq,
    (unsigned long long)nodeNowUs(), syn ? 1 : 0, hex);
  bool ok = false;
  if (n > 0 && n < (int)sizeof(buf)) {
    udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
    udp.write((uint8_t *)buf, n);
    ok = (udp.endPacket() == 1);
  }
  if (ok) bench.sent++; else bench.sendFail++;
}

static void benchStartStep(int s) {
  bench.step = s;
  bench.offered = bench.sent = bench.sendFail = bench.pendDrop = 0;
  bench.cpuSum[0] = bench.cpuSum[1] = 0; bench.cpuN = 0;
  bench.heapMin = ESP.getFreeHeap();
  bench.csiFpsSum = 0; bench.fpsN = 0;
  bench.idlePrev[0] = bench.idleCnt[0];
  bench.idlePrev[1] = bench.idleCnt[1];
  bench.stepStartMs = millis();
  benchPending = 0;
  if (benchTimer) {
    esp_timer_stop(benchTimer);
    esp_timer_start_periodic(benchTimer, 1000000 / BENCH_HZ[s]);
  }
  Serial.printf("[BENCH] step %d: offering %d Hz for 60 s\n", s, BENCH_HZ[s]);
}

static void benchEndStep() {
  if (benchTimer) esp_timer_stop(benchTimer);
  uint32_t dt = millis() - bench.stepStartMs;
  float cpu0 = bench.cpuN ? (float)bench.cpuSum[0] / bench.cpuN : -1;
  float cpu1 = bench.cpuN ? (float)bench.cpuSum[1] / bench.cpuN : -1;
  float fps = bench.fpsN ? (float)bench.csiFpsSum / bench.fpsN : 0;
  // offered vs sent here; the RECEIVING host derives sustained rate and
  // drop % from the seq numbers (that is the B1 measurement).
  Serial.printf("[BENCH] step %d hz=%d t=%.1fs offered=%lu sent=%lu "
                "send_fail=%lu pend_drop=%lu cpu0=%.0f%% cpu1=%.0f%% "
                "heap_min=%lu csi_fps=%.1f\n",
                bench.step, BENCH_HZ[bench.step], dt / 1000.0f,
                (unsigned long)bench.offered, (unsigned long)bench.sent,
                (unsigned long)bench.sendFail, (unsigned long)bench.pendDrop,
                cpu0, cpu1, (unsigned long)bench.heapMin, fps);
}

static void benchStart() {
  esp_timer_create_args_t args;
  memset(&args, 0, sizeof(args));
  args.callback = &benchTickIsr;
  args.dispatch_method = ESP_TIMER_TASK;   // timer-task context is plenty:
                                          // the callback only bumps a counter
  args.name = "csi_bench";
  if (esp_timer_create(&args, &benchTimer) != ESP_OK) {
    Serial.println("[BENCH] timer create failed; bench off");
    bench.done = true;
    return;
  }
  esp_register_freertos_idle_hook_for_cpu(benchIdle0, 0);
  esp_register_freertos_idle_hook_for_cpu(benchIdle1, 1);
  bench.calm = true;
  bench.calmStartMs = millis();
  bench.calmIdle[0] = bench.idleCnt[0];
  bench.calmIdle[1] = bench.idleCnt[1];
  Serial.println("[BENCH] calibrating idle baseline (3 s calm)...");
}

// Called from the 1 s tick. csiFps = ambient CSI frames seen that second.
static void benchSecondTick(uint32_t nowMs, uint32_t csiFps) {
  if (bench.done) return;
  if (!bench.running) {
    if (bench.autoStartMs == 0) bench.autoStartMs = bootMs + BENCH_AUTOSTART_MS;
    if ((int32_t)(nowMs - bench.autoStartMs) < 0) return;
    bench.running = true;
    benchStart();
    return;
  }
  if (bench.calm) {
    if (nowMs - bench.calmStartMs >= BENCH_CALM_MS) {
      uint32_t dt = nowMs - bench.calmStartMs;
      for (int c = 0; c < 2; c++) {
        uint32_t d = bench.idleCnt[c] - bench.calmIdle[c];
        bench.idleBase[c] = dt ? (uint32_t)((uint64_t)d * 1000 / dt) : 0;
      }
      bench.calm = false;
      Serial.printf("[BENCH] idle base/s: cpu0=%lu cpu1=%lu\n",
                    (unsigned long)bench.idleBase[0],
                    (unsigned long)bench.idleBase[1]);
      benchStartStep(0);
    }
    return;
  }
  for (int c = 0; c < 2; c++) {
    uint32_t d = bench.idleCnt[c] - bench.idlePrev[c];
    bench.idlePrev[c] = bench.idleCnt[c];
    if (bench.idleBase[c] > 0) {
      float cpu = 100.0f * (1.0f - (float)d / (float)bench.idleBase[c]);
      if (cpu < 0) cpu = 0; if (cpu > 100) cpu = 100;
      bench.cpuSum[c] += (uint32_t)cpu;
    }
  }
  bench.cpuN++;
  uint32_t fh = ESP.getFreeHeap();
  if (fh < bench.heapMin) bench.heapMin = fh;
  bench.csiFpsSum += csiFps; bench.fpsN++;
  if (nowMs - bench.stepStartMs >= BENCH_STEP_MS) {
    benchEndStep();
    if (bench.step + 1 < BENCH_NSTEPS) benchStartStep(bench.step + 1);
    else {
      bench.running = false; bench.done = true;
      Serial.println("[BENCH] DONE — all 4 steps complete. "
                     "This build is bench-only; NEVER ship it.");
    }
  }
}
#endif  // CSI_BENCH

// ---------------- WiFi CSI sniffer ----------------
volatile uint32_t g_frames = 0;
volatile int32_t  g_rssiSum = 0;
// The CSI callback runs on the Wi-Fi task (other core); loop() reads and
// zeroes these once a second. Without the lock a frame landing between
// the read and the reset was silently lost.
portMUX_TYPE g_csiMux = portMUX_INITIALIZER_UNLOCKED;

// ---- Suzuki symmetric-subcarrier phase pipeline (Stage 1 firmware) ----
// docs/esp32_csi_pipeline_spec.md: per CSI frame, for each symmetric pair
// (+k,-k) in the 20 MHz HT CSI, m(k) = (c(+k) + conj(c(-k)))/2. CFO/SFO/
// packet-delay phase errors are ~linear across subcarriers (+k*alpha on
// +k, -k*alpha on -k) so they cancel in the sum; the true channel phase
// (even-symmetric under conjugation) adds. NO phase unwrapping, NO
// regression fit. arg(m(k)) lands in a per-pair 1 s ring (nodeNowUs()
// timestamps); once a second the loop computes the per-pair Hz-deviation
// (zero-crossing rate of the detrended phase) and reports the max pair
// as the link dev_hz. RX-only: this sniffs ambient frames, nothing here
// transmits.
//
// Buffer layout (ESP32, this node's CSI config: lltf+htltf merged,
// channel filter on): data->len == 192 -> 64 subcarriers x 3 bytes
// (I int8, Q int8, reserved). Subcarrier index i maps to (i-32); the
// valid 20 MHz data/pilot tones are k = +/-1..28, i.e. 28 symmetric
// pairs (slots 28..31 stay empty — "up to 32 pairs" per the spec). A
// len==128 (64 x I/Q) layout is also accepted defensively; anything else
// is skipped. first_word_invalid only touches subcarrier -32, outside
// our pairs. Single antenna: this is a SCALAR disturbance metric — no
// bearing, no identity; dev_hz bands are size-class heuristics only.
#define CSI_NPAIR 32
#define CSI_KMAX  28
#define CSI_RINGN 64
#define CSI_AMP_FLOOR 2.0f   // mean |m(k)| below this: pair not "active"
                             // (heuristic noise floor, int8 I/Q units)

struct CsiPairRing {
  uint32_t t32[CSI_RINGN];  // nodeNowUs() low 32 bits; wrap-safe 1 s window
  float ph[CSI_RINGN];      // arg(m(k)), radians, wrapped [-pi,pi]
  float amp[CSI_RINGN];     // |m(k)|, linear int8 units
  uint8_t head = 0;
  uint8_t n = 0;
};
CsiPairRing csiRing[CSI_NPAIR];

// Parse one CSI frame into the pair rings. Called from csi_cb with
// g_csiMux already held.
static void csiPushFrame(wifi_csi_info_t *data, uint32_t t32) {
  if (!data || !data->buf) return;
  int8_t *b = data->buf;
  int stride = 0;
  if (data->len == 192)      stride = 3;   // 64 subcarriers x (I,Q,res)
  else if (data->len == 128) stride = 2;   // 64 subcarriers x (I,Q)
  else return;                             // unknown layout: skip
#ifdef CSI_BENCH
  // Bench payload: per-subcarrier amplitude of this frame.
  for (int i = 0; i < 64; i++) {
    float iv = b[i * stride], qv = b[i * stride + 1];
    float a = sqrtf(iv * iv + qv * qv);
    benchAmp[i] = a > 255.0f ? 255 : (uint8_t)a;
  }
  benchAmpFresh = true;
  benchAmpMs = millis();
#endif
  for (int k = 1; k <= CSI_KMAX; k++) {
    int ip = 32 + k, im = 32 - k;              // subcarrier +k / -k
    float Ip = b[ip * stride], Qp = b[ip * stride + 1];
    float Im = b[im * stride], Qm = b[im * stride + 1];
    // m(k) = (c(+k) + conj(c(-k))) / 2
    float mr = (Ip + Im) * 0.5f;
    float mi = (Qp - Qm) * 0.5f;
    float a = sqrtf(mr * mr + mi * mi);
    if (a < 0.5f) continue;                    // dead tone: skip rather
                                               // than store a fake phase
    CsiPairRing &r = csiRing[k - 1];
    r.t32[r.head] = t32;
    r.ph[r.head] = atan2f(mi, mr);
    r.amp[r.head] = a;
    r.head = (r.head + 1) % CSI_RINGN;
    if (r.n < CSI_RINGN) r.n++;
  }
}

void csi_cb(void *ctx, wifi_csi_info_t *data) {
  (void)ctx;
  if (!data) return;
  uint32_t t32 = (uint32_t)nodeNowUs();  // captured before the lock
  portENTER_CRITICAL(&g_csiMux);
  g_frames++;
  g_rssiSum += data->rx_ctrl.rssi;
  csiPushFrame(data, t32);   // Suzuki averaging + ring store
  portEXIT_CRITICAL(&g_csiMux);
}

// Once-per-second CSI aggregation (loop context, g_csiMux held by the
// caller). Per pair: zero-crossing rate of the detrended phase over the
// 1 s window — dev_pair = crossings / (2*T). Link dev_hz = max pair.
// No unwrapping anywhere: the ZCR of wrapped phase still measures the
// fluctuation rate the paper's metric wants (a monotonic drift wrapped
// to a sawtooth crosses zero at the same rate as the underlying tone).
static void csiAggregate1s(uint32_t now32, float &devHz, int &pairsActive,
                           float &meanAmpAll) {
  devHz = 0; pairsActive = 0; meanAmpAll = 0;
  int ampN = 0;
  for (int p = 0; p < CSI_KMAX; p++) {
    CsiPairRing &r = csiRing[p];
    if (r.n < 8) continue;
    // Chronological walk (single writer: insertion order == time order).
    int idx = (int)r.head - (int)r.n;
    if (idx < 0) idx += CSI_RINGN;
    // First pass: mean phase + mean amplitude over the 1 s window.
    float mean = 0, ampSum = 0;
    int m = 0;
    uint32_t tFirst = 0, tLast = 0;
    for (int j = 0; j < r.n; j++) {
      int ii = idx + j;
      if (ii >= CSI_RINGN) ii -= CSI_RINGN;
      if (now32 - r.t32[ii] > 1000000UL) continue;   // wrap-safe age
      mean += r.ph[ii]; m++;
      ampSum += r.amp[ii];
      if (tFirst == 0) tFirst = r.t32[ii];
      tLast = r.t32[ii];
    }
    if (m < 8) continue;
    uint32_t spanUs = tLast - tFirst;                // wrap-safe
    // Frame-rate ceiling: the ring holds 64 entries/pair. Above ~320
    // frames/s those 64 entries span < 200 ms, the check below skips
    // every pair, and dev_hz silently reports 0 for the whole second.
    // Fail-silent is the correct behavior here (a deviation drawn from
    // an under-spanned window would be a meaningless number), so this
    // is documented, not fixed.
    if (spanUs < 200000UL) continue;                 // need real time span
    mean /= m;
    float mAmp = ampSum / m;
    meanAmpAll += mAmp; ampN++;
    // Second pass: zero crossings of the detrended series.
    int cross = 0;
    bool havePrev = false, prevPos = false;
    for (int j = 0; j < r.n; j++) {
      int ii = idx + j;
      if (ii >= CSI_RINGN) ii -= CSI_RINGN;
      if (now32 - r.t32[ii] > 1000000UL) continue;
      bool pos = (r.ph[ii] - mean) >= 0.0f;
      if (havePrev && pos != prevPos) cross++;
      prevPos = pos; havePrev = true;
    }
    float dev = cross / (2.0f * (spanUs / 1000000.0f));
    if (dev > devHz) devHz = dev;
    if (mAmp > CSI_AMP_FLOOR) pairsActive++;
  }
  if (ampN > 0) meanAmpAll /= ampN;
}

// ---- Wind gate (docs/esp32_csi_pipeline_spec.md Stage 2) ----
// WIND observations arrive on UART as "WIND <name> <wind_ms> [gust_ms]"
// (parsed like SENSOR lines in uartPoll). There is no UDP RX path on the
// node, so app-forwarded wind arrives UART-only — documented, not a gap.
// While wind_ms >= 3.5 (Suzuki's gate) motion claims are suppressed and
// wind_gated:true is reported. With NO wind source the CSI motion
// features are DISABLED by default (fail-safe, wind_gated:true
// permanently); the RSSI tripwire is unaffected.
char windName[16] = "";
float windMs = 0, windGustMs = -1;
bool windHasGust = false, windSeen = false;
uint32_t windRxMs = 0;
#define WIND_STALE_MS 300000UL   // 5 min: weather changes slowly
#define WIND_GATE_MPS 3.5f       // Suzuki's gate

// declared in the GPS section below; needed here for the sensor_obs emit
extern double gpsLat, gpsLon;

static void sendSensorObsWind(uint64_t nowUs) {
  char buf[256], sSafe[16];
  jsonSafe(sSafe, sizeof(sSafe), windName[0] ? windName : "wind");
  int n;
  if (windHasGust)
    n = snprintf(buf, sizeof(buf),
      "{\"type\":\"sensor_obs\",\"obs\":\"WIND\",\"node\":\"%s\",\"sensor\":\"%s\","
      "\"wind_ms\":%.1f,\"gust_ms\":%.1f,\"t\":%.1f}",
      nodeId, sSafe, windMs, windGustMs, nowUs / 1000000.0);
  else
    n = snprintf(buf, sizeof(buf),
      "{\"type\":\"sensor_obs\",\"obs\":\"WIND\",\"node\":\"%s\",\"sensor\":\"%s\","
      "\"wind_ms\":%.1f,\"t\":%.1f}",
      nodeId, sSafe, windMs, nowUs / 1000000.0);
  if (n > 0 && n < (int)sizeof(buf)) {
    udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
    udp.write((uint8_t *)buf, n);
    udp.endPacket();
  }
}

// Once-per-second CSI sensor_obs emission (called from the 1 s tick).
// dev_hz bands are SIZE-CLASS HEURISTICS for the app's merger, never
// identity claims; the 55/60 dB link-budget knees are app-side gates.
static void csiSecondTick(uint32_t nowMs, float devHz, int pairsActive,
                          float pathLossDb) {
  uint64_t nowUs = nodeNowUs();
  bool windKnown = windSeen && (nowMs - windRxMs) < WIND_STALE_MS;
  bool gated = !windKnown || windMs >= WIND_GATE_MPS;
  // SF3: the "link" label is per-CHANNEL, not per-AP-link. This firmware
  // aggregates EVERY CSI frame seen on the channel into one scalar
  // metric (wifi_ch%d) with no per-MAC separation — frames from different
  // APs carry independent CFO/channel phases, so mixing them muddies the
  // ZCR metric. Known degradation vs the paper's single-link result
  // (docs/esp32_csi_pipeline_spec.md Stage 1). Per-AP (per-source) rings
  // would multiply RAM unsafely and are deliberately NOT implemented —
  // per-AP separation is future work.
  char linkId[16];
  snprintf(linkId, sizeof(linkId), "wifi_ch%d", WiFi.channel());
  // SF4 (defense-in-depth): while the wind gate is active (no wind
  // source, or wind >= 3.5 m/s) the wire value is forced to dev_hz 0.0
  // / pairs_active 0 while wind_gated:true is kept — a consumer that
  // ignores the flag can never mistake a computed value for a live
  // claim. The RSSI tripwire is unaffected by CSI gating.
  if (gated) { devHz = 0.0f; pairsActive = 0; }
  char buf[400];
  int n = snprintf(buf, sizeof(buf),
    "{\"type\":\"sensor_obs\",\"obs\":\"CSI\",\"node\":\"%s\",\"sensor\":\"csi_wifi\","
    "\"dev_hz\":%.1f,\"pairs_active\":%d,\"path_loss_db\":%.1f,\"link\":\"%s\","
    "\"wind_ms\":%.1f,\"wind_gated\":%s,\"lat\":%.6f,\"lon\":%.6f,\"t\":%.1f}",
    nodeId, devHz, pairsActive, pathLossDb, linkId,
    windKnown ? windMs : -1.0f, gated ? "true" : "false",
    gpsLat, gpsLon, nowUs / 1000000.0);
  // t is nodeNowUs()/1e6: UTC-epoch when GPS-locked, node-local
  // boot-relative otherwise (same caveat as t_us in events).
  if (n > 0 && n < (int)sizeof(buf)) {
    udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
    udp.write((uint8_t *)buf, n);
    udp.endPacket();
  }
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
      // WIND <name> <wind_ms> [gust_ms] — anemometer input for the CSI
      // wind gate (docs/esp32_csi_pipeline_spec.md Stage 2). Forwarded to
      // the app as a WIND sensor_obs so the merger sees it.
      char wname[16] = "";
      float wms = 0, wgust = 0;
      int wn = sscanf(uartLine, "WIND %15s %f %f", wname, &wms, &wgust);
      if (wn >= 2) {
        jsonSafe(windName, sizeof(windName), wname);
        // A negative wind speed is unphysical; without this clamp it
        // would silently ENABLE CSI motion claims (wind_ms < 3.5 reads
        // as "calm, claim away"). Clamp to zero.
        windMs = wms < 0 ? 0 : wms;
        windHasGust = (wn >= 3);
        if (windHasGust) windGustMs = wgust;
        windSeen = true;
        windRxMs = now;
        sendSensorObsWind(nodeNowUs());
        Serial.printf("wind: %s %.1f m/s%s\n", windName, windMs,
                      windHasGust ? " (+gust)" : "");
      } else if (sscanf(uartLine, "SENSOR %15s %f %31s", name, &rssi, detail) >= 2) {
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
// protocol above). Binary frames: AA FF 03 00, then 3 x 8-byte targets
// (X_lo X_hi Y_lo Y_hi SPD_lo SPD_hi RES_lo RES_hi, signed 16-bit,
// millimetres; bytes 6-7 are distance-resolution, unused here),
// then 55 CC. X==0 && Y==0 means "no target in this slot" — this
// conflates an empty slot with a target exactly at the origin, but the
// origin is inside the radar housing, so it is negligible in practice.
// Wiring: LD_TX -> GPIO16, LD_RX -> GPIO17, 5V, GND (3.3V logic).
//
// H1 NOTE: the 24-byte (3x8) target block is PER CODE ANALYSIS of the
// LD2450 protocol — UNVERIFIED against hardware (no UART dump was
// available). Field check: capture raw UART2 @256000 hex; between the
// "03 00" header and the trailing "55 CC" there must be exactly 24 bytes
// (3 targets x 8). If the "frame sync failing" warning below fires, the
// layout assumption is wrong — send the hex dump back for re-analysis.
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
    uint8_t *t = d + s * 8;   // 8 bytes/target; bytes 6-7 (dist-res) skipped
    int16_t x = (int16_t)(t[0] | (t[1] << 8));
    int16_t y = (int16_t)(t[2] | (t[3] << 8));
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
  // byte-wise frame sync: AA FF 03 00 ...24 bytes... 55 CC
  static uint8_t state = 0;
  static uint8_t data[24];
  static int di = 0;
  static uint32_t syncFails = 0;   // consecutive frame-sync failures (H1)
  while (Serial2.available()) {
    uint8_t b = (uint8_t)Serial2.read();
    switch (state) {
      case 0: state = (b == 0xAA) ? 1 : 0; break;
      case 1:
        if (b == 0xFF) state = 2;
        else { state = (b == 0xAA) ? 1 : 0; syncFails++; }
        break;
      case 2:
        if (b == 0x03) state = 3;
        else { state = 0; syncFails++; }
        break;
      case 3:
        if (b == 0x00) { state = 4; di = 0; }
        else { state = 0; syncFails++; }
        break;
      case 4: data[di++] = b; if (di >= 24) state = 5; break;
      case 5:
        if (b == 0x55) state = 6;
        else { state = 0; syncFails++; }
        break;
      case 6:
        if (b == 0xCC) { ld2450Frame(data, now); syncFails = 0; }
        else syncFails++;
        state = 0;
        break;
    }
    if (syncFails == 51) {
      // H1 runtime sanity check: 50+ consecutive frames failed to sync —
      // with the 24-byte layout assumption this means wrong wiring/baud
      // OR a wrong layout (see the H1 NOTE above). Fires once per streak.
      Serial.println("LD2450: frame sync failing — check wiring/baud, "
                     "parser expects 24-byte target block");
    }
  }
}
#endif

// ---------------- GPS: NMEA position + PPS-disciplined clock ----------------
// NEO-M8N-class module on Serial1 (RX=25 <- GPS TX, TX=26 -> GPS RX,
// PPS=27 rising). Always compiled; with no module attached nothing
// arrives, no PPS edges are ever seen, and the node silently uses the
// local wrap-extended micros() clock with lat/lon 0,0 and pps 0 in
// beacons. Position comes from $GxGGA (any talker: GP/GN/GL/GB/GA,
// checksum-verified); the UTC epoch comes from $GxRMC (see M9 note in
// the clock section above). pps:1 in beacons means LOCKED (3 consecutive
// ~1 s-spaced edges), not merely "an edge was seen once".
char nmeaLine[96]; int nmeaPos = 0;
double gpsLat = 0, gpsLon = 0;
bool gpsFix = false;

static double nmeaToDeg(double v) {
  int deg = (int)(v / 100);
  double minutes = v - deg * 100;
  return deg + minutes / 60.0;
}

// $GPGGA/$GNGGA/$GLGGA/$GBGGA/$GAGGA (and the RMC equivalents): talker
// letter P/N/L/B/A followed by the sentence kind.
static bool nmeaIs(const char *line, const char *kind) {
  return line[0] == '$' && line[1] == 'G' && strchr("PNLBA", line[2]) &&
         strncmp(line + 3, kind, 3) == 0 && line[6] == ',';
}

// Verify the NMEA *HH checksum when the sentence carries one; sentences
// with no '*' are accepted as before.
static bool nmeaChecksumOk(const char *line) {
  const char *star = strchr(line, '*');
  if (!star) return true;
  uint8_t cs = 0;
  for (const char *p = line + 1; p < star; p++) cs ^= (uint8_t)*p;
  unsigned v = 0;
  if (sscanf(star + 1, "%2x", &v) != 1) return false;
  return (uint8_t)v == cs;
}

// Seconds since 1970-01-01T00:00:00Z (Howard Hinnant's days_from_civil).
static uint64_t utcEpoch(int hh, int mm, int ss, int dd, int mo, int yyyy) {
  int y = yyyy - (mo <= 2);
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + dd - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  int64_t days = era * 146097 + (int64_t)doe - 719468;
  return (uint64_t)days * 86400ULL + (uint64_t)(hh * 3600 + mm * 60 + ss);
}

void gpsPoll() {
  micros64();   // keep the wrap extension fresh (M7)
  ppsFold();    // PPS discipline (M6/M8)
  if (ppsLocked && (int32_t)(millis() - ppsLastEdgeMs) > 2500) {
    ppsLocked = false;   // GPS died mid-run: stop claiming lock (M8)
    ppsLockN = 0;
  }
  // NMEA: $GxGGA for position + fix quality, $GxRMC for the UTC epoch.
  while (Serial1.available()) {
    char c = (char)Serial1.read();
    if (c == '\n' || nmeaPos >= (int)sizeof(nmeaLine) - 1) {
      nmeaLine[nmeaPos] = 0; nmeaPos = 0;
      if (!nmeaChecksumOk(nmeaLine)) continue;
      bool gga = nmeaIs(nmeaLine, "GGA");
      bool rmc = nmeaIs(nmeaLine, "RMC");
      if (!gga && !rmc) continue;
      const char *f[12] = {0};
      int fi = 0;
      for (char *p = nmeaLine; *p && fi < 12; p++) {
        if (*p == ',') { *p = 0; f[fi++] = p + 1; }
      }
      // f[0] is the text after the first comma.
      if (gga) {
        // f[0]=time f[1]=lat f[2]=N/S f[3]=lon f[4]=E/W f[5]=quality
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
            // M10: fix lost — zero the coords so beacons stop
            // advertising a stale position (docs say 0,0 = no fix).
            gpsFix = false; gpsLat = 0; gpsLon = 0;
          }
        }
      } else if (rmc && fi >= 10 && f[0] && f[1] && f[9] &&
                 *f[0] && *f[9] && *f[1] == 'A') {
        // M9: f[0]=hhmmss.ss f[9]=ddmmyy. Snap the disciplined clock to
        // the UTC epoch. The RMC timestamp labels the second whose PPS
        // edge fired most recently (u-blox: PPS at top-of-second, then
        // the sentence). Gated on ppsLocked so a lone spurious edge can
        // never epoch-label a free-running clock. Worst case on modules
        // that emit RMC before the edge: a fixed 1 s offset.
        int hh, mm, ss, dd, mo, yy;
        if (sscanf(f[0], "%2d%2d%2d", &hh, &mm, &ss) == 3 &&
            sscanf(f[9], "%2d%2d%2d", &dd, &mo, &yy) == 3 &&
            hh < 24 && mm < 60 && ss < 60 &&
            dd >= 1 && dd <= 31 && mo >= 1 && mo <= 12) {
          int fullY = (yy >= 80) ? 1900 + yy : 2000 + yy;
          uint64_t epoch = utcEpoch(hh, mm, ss, dd, mo, fullY);
          portENTER_CRITICAL(&g_ppsMux);
          if (ppsLocked) ppsBaseUs = epoch * 1000000ULL;
          portEXIT_CRITICAL(&g_ppsMux);
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
bool relayOk = false;        // set only after clean init: no half-alive relay
bool relayChWarn = false;    // AP channel != relay_ch pref (M12)
uint32_t relayDrops = 0;     // H5/LOW: dropped packets (oversize/queue/send)

// H4: the ESP-NOW receive callback runs on the WiFi task, where lwIP/UDP
// calls and the shared relay state are not safe to touch. The callback
// therefore only copies raw datagrams into this ring under a critical
// section; relayPump() (loop context, below) does ALL parsing, dedup,
// UDP re-emit and ESP-NOW forwarding.
struct RelayRxPkt { char data[256]; uint8_t len; };
RelayRxPkt relayRx[8];
volatile uint8_t relayRxHead = 0, relayRxTail = 0;
portMUX_TYPE g_relayMux = portMUX_INITIALIZER_UNLOCKED;

// M11: the per-node eventCount sequence is hashed into the dedup ID, so
// distinct events in the same 1 s t0 bucket (e.g. 3 LD2450 targets)
// no longer collide.
static uint32_t relayId(const char *node, const char *sensor, uint32_t t0,
                        uint32_t seq) {
  uint32_t h = 2166136261UL;   // FNV-1a
  const char *p;
  for (p = node; *p; p++) { h ^= (uint8_t)*p; h *= 16777619UL; }
  for (p = sensor; *p; p++) { h ^= (uint8_t)*p; h *= 16777619UL; }
  for (int i = 0; i < 4; i++) { h ^= (t0 >> (i * 8)) & 0xFF; h *= 16777619UL; }
  for (int i = 0; i < 4; i++) { h ^= (seq >> (i * 8)) & 0xFF; h *= 16777619UL; }
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
  if (!relayOk) return;
  if (relayOutN >= 4) { relayDrops++; return; }  // saturated: drop, count it
  char ev[336];
  strncpy(ev, evJson, sizeof(ev) - 1); ev[sizeof(ev) - 1] = 0;
  // H5: ESP-NOW payloads are capped at 250 bytes. Shrink the inner event
  // JSON first: drop the detail field preferentially, then hard-truncate
  // at a field boundary (the event JSON is flat, so cutting at the last
  // comma stays valid). Anything that still cannot fit is dropped and
  // counted in relayDrops (surfaced in beacons).
  for (;;) {
    char pkt[400];
    int n = snprintf(pkt, sizeof(pkt),
             "{\"type\":\"relay\",\"id\":%lu,\"ttl\":%d,\"ev\":%s}",
             (unsigned long)id, ttl, ev);
    if (n > 0 && n < 250) {
      strcpy(relayOut[relayOutN], pkt); relayOutN++;
      return;
    }
    char *d = strstr(ev, "\"detail\":\"");
    if (d) {
      char *e = strchr(d + 10, '"');
      if (e) { memmove(d + 10, e, strlen(e) + 1); continue; }  // detail -> ""
    }
    int keep = 250 - 64;   // wrapper budget
    char *c = NULL;
    if (keep > 16) { ev[keep] = 0; c = strrchr(ev, ','); }
    if (c && c > ev + 8) { *c = 0; strcat(ev, "}"); continue; }
    relayDrops++;
    return;
  }
}
// Called from sendEvent for every LOCAL event: remember the id (so the
// mesh echo of our own event is dropped) and queue it for relay.
// eventCount is the pre-increment sequence, unique per local event.
void relayNoteLocal(const char *eventJson, const char *sensor, uint32_t t0) {
  if (!relayOk) return;
  uint32_t id = relayId(nodeId, sensor, t0, eventCount);
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
// H4: WiFi-task context — copy bytes only, never parse or send here.
void onRelayRecv(const uint8_t *mac, const uint8_t *data, int len) {
  (void)mac;
  if (!relayOk) return;
  if (len <= 0) return;
  if (len > 250) { relayDrops++; return; }   // over the ESP-NOW cap: junk
  portENTER_CRITICAL(&g_relayMux);
  uint8_t nh = (relayRxHead + 1) % 8;
  if (nh == relayRxTail) {          // ring full: drop, count it
    portEXIT_CRITICAL(&g_relayMux);
    relayDrops++;
    return;
  }
  memcpy(relayRx[relayRxHead].data, data, len);
  relayRx[relayRxHead].len = (uint8_t)len;
  relayRxHead = nh;
  portEXIT_CRITICAL(&g_relayMux);
}
// H4: loop context — drain the RX ring: parse, dedup, UDP re-emit,
// ESP-NOW forward. TTL/echo-suppression logic unchanged, just relocated.
void relayPump() {
  if (!relayOk) return;
  for (;;) {
    char tmp[256]; uint8_t len;
    portENTER_CRITICAL(&g_relayMux);
    if (relayRxHead == relayRxTail) { portEXIT_CRITICAL(&g_relayMux); break; }
    uint8_t t = relayRxTail;
    len = relayRx[t].len;
    memcpy(tmp, relayRx[t].data, len); tmp[len] = 0;
    relayRxTail = (t + 1) % 8;
    portEXIT_CRITICAL(&g_relayMux);
    uint32_t id; int ttl; const char *ev; int evLen;
    if (!relayExtract(tmp, id, ttl, ev, evLen)) continue;
    if (relaySeenId(id)) continue;    // already forwarded: drop
    relayRemember(id);
    // Re-emit on this node's LAN so the Shepherd host joined here sees
    // it — but not when the TTL is exhausted.
    if (ttl > 0) {
      udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
      udp.write((uint8_t *)ev, evLen);
      udp.endPacket();
    }
    // Forward with decremented TTL.
    if (ttl > 1 && relayOutN < 4) {
      char evJson[336];
      int n = evLen < (int)sizeof(evJson) - 1 ? evLen : (int)sizeof(evJson) - 1;
      memcpy(evJson, ev, n); evJson[n] = 0;
      relayQueuePkt(id, ttl - 1, evJson);
    }
  }
}
void relayFlush() {
  if (!relayOk || relayOutN == 0) return;
  wifiSniff(false);   // radio time-slice, like the BLE scan
  for (int i = 0; i < relayOutN; i++) {
    // H5: check the send result; ESP_ERR_ESPNOW_ARG fires on oversize
    // payloads, which relayQueuePkt already prevents.
    if (esp_now_send(relayBcast, (uint8_t *)relayOut[i],
                     strlen(relayOut[i])) != ESP_OK) {
      relayDrops++;
      Serial.println("ESP-NOW send failed; packet dropped");
    }
  }
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
  // M12: esp_now_add_peer succeeds regardless of channel, so a channel
  // mismatch is a silent mesh island. Compare against the optional
  // "relay_ch" pref and flag it: "rch_warn":1 in beacons + a serial
  // warning. The Shepherd host app should surface rch_warn prominently.
  int rch = prefs.getInt("relay_ch", 0);
  if (rch > 0 && WiFi.channel() != rch) {
    relayChWarn = true;
    Serial.printf("ESP-NOW relay: AP ch %d != relay_ch pref %d; mesh island!\n",
                  WiFi.channel(), rch);
  }
  relayOk = true;
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
  // LOW: the MPU6050 samples internally at 1 kHz; without the digital
  // low-pass filter that aliases straight into our 10 Hz poll. DLPF
  // 44 Hz (CONFIG=0x03) keeps the motion-energy channel honest.
  imuRegWrite(0x1A, 0x03);                // CONFIG: DLPF 44 Hz
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
    // M13: MOTION is context, not intrusion — mark it explicitly.
    // Consumer contract: the app must filter on sensor+class (or this
    // context flag), never on conf alone (0.50 here sits near BLE's
    // 0.55 NEW_DEVICE hint).
    sendEvent("imu", durS, depth, "MOTION", 0.50f, "", true);
  }
}
#endif

// ---------------- beacons / status ----------------
void sendBeacon(float fps) {
  char buf[560];
#ifdef ESPNOW_RELAY
  uint32_t rd = relayDrops;      // H5/LOW: relay drop counter
  int rcw = relayChWarn ? 1 : 0; // M12: AP channel != relay_ch pref
#else
  uint32_t rd = 0;
  int rcw = 0;
#endif
  snprintf(buf, sizeof(buf),
    "{\"type\":\"beacon\",\"node\":\"%s\",\"callsign\":\"%s\",\"ip\":\"%s\",\"ch\":%d,"
    "\"fps\":%.0f,\"events\":%lu,\"uptime_s\":%lu,"
    "\"sensors\":[%s],\"ble_seen\":%d,"
    "\"lat\":%.6f,\"lon\":%.6f,\"pps\":%d,\"rdrop\":%lu,\"rch_warn\":%d,"
    "\"calib\":%d}",
    nodeId, nodeCallsign, WiFi.softAPIP().toString().c_str(), WiFi.channel(), fps,
    (unsigned long)eventCount, (unsigned long)((millis() - bootMs) / 1000),
    sensorList, bleN, gpsLat, gpsLon, ppsLocked ? 1 : 0,
    (unsigned long)rd, rcw, calibActive ? 1 : 0);
  udp.beginPacket(IPAddress(192, 168, 4, 255), BEACON_PORT);
  udp.write((uint8_t *)buf, strlen(buf));
  udp.endPacket();
}

void handleRoot() {
  char html[2400], csiSt[80], windSt[56];
  if (!windSeen)
    snprintf(csiSt, sizeof(csiSt), "DISABLED (no wind source)");
  else if (windMs >= WIND_GATE_MPS)
    snprintf(csiSt, sizeof(csiSt), "wind-gated (%.1f m/s)", windMs);
  else
    snprintf(csiSt, sizeof(csiSt), "active (dev %.1f Hz, %d pairs)",
             lastCsiDevHz, lastCsiPairs);
  if (windSeen)
    snprintf(windSt, sizeof(windSt), "%s %.1f m/s%s", windName, windMs,
             windHasGust ? " (+gust)" : "");
  else
    snprintf(windSt, sizeof(windSt), "(none)");
  snprintf(html, sizeof(html),
    "<html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<style>body{background:#111;color:#c9a7eb;font-family:sans-serif;padding:24px}"
    "h1{color:#a855f7}.card{background:#1c1c22;padding:16px;border-radius:12px;margin:12px 0}"
    "input{background:#111;color:#c9a7eb;border:1px solid #a855f7;border-radius:8px;padding:8px}"
    "button{background:#a855f7;color:#111;border:0;border-radius:8px;padding:8px 16px}</style>"
    "</head><body><h1>Shepherd Node %s</h1>"
#ifdef CSI_BENCH
    "<div class=card><b>BENCH BUILD</b> — CSI frame-rate bench active. "
    "Never ship this firmware.</div>"
#endif
    "<div class=card>Callsign: <b>%s</b><br><form action=/callsign method=get>"
    "<input name=c maxlength=16 placeholder='RAPTOR-1' value='%s'> "
    "<button>Set</button></form></div>"
    "<div class=card>Sensors: %s<br>Uptime %lu s &nbsp; Channel %d<br>"
    "WiFi metric %.1f dB &nbsp; BLE seen %d &nbsp; Events %lu<br>"
    "CSI motion: %s &nbsp; Wind: %s<br>"
    "Calibration window: <b>%s</b> "
    "<a href=/calib?v=1 style=color:#a855f7>start</a> / "
    "<a href=/calib?v=0 style=color:#a855f7>stop</a></div>"
    "<div class=card>GPS: %s &nbsp; PPS: %s<br>Lat %.6f Lon %.6f</div>"
    "<div class=card>Join this AP from the Shepherd device.<br>"
    "Beacons + events on UDP %d.</div></body></html>",
    nodeId, nodeCallsign[0] ? nodeCallsign : "(none)", nodeCallsign,
    sensorList, (unsigned long)((millis() - bootMs) / 1000),
    WiFi.channel(), lastWifiMetric, bleN, (unsigned long)eventCount,
    csiSt, windSt, calibActive ? "ACTIVE" : "idle",
    gpsFix ? "fix" : "no fix", ppsLocked ? "locked" : "free-run",
    gpsLat, gpsLon, BEACON_PORT);
  server.send(200, "text/html", html);
}

// /callsign?c=RAPTOR-1 — sanitized to A-Z 0-9 _ - space, max 16.
void handleCallsign() {
  String c = server.arg("c");
  c.trim(); c.toUpperCase();
  String clean;
  for (size_t i = 0; i < c.length() && clean.length() < 16; i++) {
    char ch = c[i];
    if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
        ch == '-' || ch == '_' || ch == ' ') clean += ch;
  }
  clean.toCharArray(nodeCallsign, sizeof(nodeCallsign));
  prefs.putString("callsign", String(nodeCallsign));
  server.sendHeader("Location", "/");
  server.send(303);
}

// /calib?v=1 — the app opens the vacant calibration window: this node
// participates ("calib":1 in beacons). /calib?v=0 (or any other value)
// closes it. RAM-only by design: a reboot clears it, and it auto-expires
// after 3 min, so a node that reboots mid-window can never contaminate
// the app's fit (docs/adaptive_baseline_spec.md).
void handleCalib() {
  if (server.arg("v") == "1") {
    calibActive = true;
    calibSetMs = millis();
    Serial.println("calibration window: ACTIVE (this node participates)");
  } else {
    calibActive = false;
    Serial.println("calibration window: idle");
  }
  server.sendHeader("Location", "/");
  server.send(303);
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
  String cs = prefs.getString("callsign", "");
  cs.toCharArray(nodeCallsign, sizeof(nodeCallsign));
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
  // LOW: Serial1 RX floats with no GPS attached. gpio_pullup_en only
  // enables the pull-up — unlike pinMode(INPUT_PULLUP) it does not steal
  // the pin back from the UART peripheral.
  gpio_pullup_en((gpio_num_t)GPS_RX);
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
  server.on("/callsign", handleCallsign);
  server.on("/calib", handleCalib);
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
  relayPump();   // H4: RX-ring processing happens here, in loop context
  if (now - lastRelayFlush > RELAY_FLUSH_MS) {
    lastRelayFlush = now;
    relayFlush();
  }
#endif

#ifdef CSI_BENCH
  // Bench datagram pump: drain timer ticks into UDP datagrams. Runs
  // every loop pass so the 1 s tick above is never starved.
  if (bench.running && !bench.calm && benchPending > 0) {
    if (benchPending > 4000) {   // loop fell behind (e.g. BLE time-slice):
      bench.pendDrop += benchPending - 4000;   // count it, don't spiral
      benchPending = 4000;
    }
    while (benchPending > 0) { benchPending--; benchSendOne(); }
  }
#endif

  if (now - lastBle > BLE_EVERY_MS) { lastBle = now; bleScanOnce(); }

  if (now - lastSec >= 1000) {
    // 1 s aggregation cadence: frame/RSSI counters AND the CSI pair
    // rings are read under one lock hold, so a frame landing mid-read is
    // never lost and the aggregation sees a consistent snapshot.
    uint32_t now32 = (uint32_t)nodeNowUs();
    float csiDevHz = 0, csiMeanAmp = 0;
    int csiPairs = 0;
    uint32_t f = 0; int32_t rs = 0;
    portENTER_CRITICAL(&g_csiMux);
    f = g_frames; rs = g_rssiSum;
    g_frames = 0; g_rssiSum = 0;
    csiAggregate1s(now32, csiDevHz, csiPairs, csiMeanAmp);
    portEXIT_CRITICAL(&g_csiMux);
    (void)csiMeanAmp;   // reserved for a future amplitude-health field
    lastSec = now;
    lastCsiDevHz = csiDevHz; lastCsiPairs = csiPairs;
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
    // CSI motion channel (docs/esp32_csi_pipeline_spec.md). path_loss_db
    // is a CRUDE firmware placeholder (assumes 20 dBm TX on the sniffed
    // frames; -1 = unknown) — the app re-derives the real per-link budget
    // and owns the 55/60 dB gates. Never firmware.
    csiSecondTick(now, csiDevHz, csiPairs,
                  f > 0 ? 20.0f - (float)rs / (float)f : -1.0f);
    // Vacant-window calibration flag: auto-expire after 3 min without a
    // refresh; a reboot always clears it (RAM-only) so a mid-window
    // reboot can never contaminate the app's fit.
    if (calibActive && now - calibSetMs > 180000UL) calibActive = false;
#ifdef CSI_BENCH
    benchSecondTick(now, f);
#endif
  }

  if (now - lastBeacon > BEACON_MS) {
    lastBeacon = now;
    sendBeacon(0);   // fps tracked separately if needed
  }
  delay(10);
}
