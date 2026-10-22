"""Host-side model of the Shepherd LoRa gateway's packet pipeline,
mirroring lora_gateway.ino (handlePacket -> decodeV1 -> reemit*) step
for step, and the node encoder in lora_node.ino (encodeBeacon /
encodeEvent / wrapPsk).

Purpose: the shared test vectors and the unit tests verify the *wire
protocol and gateway behavior* on a host. The JSON format strings here
are literal copies of the snprintf formats in lora_gateway.ino, and
float fields are rounded through IEEE-754 single precision (struct
'f') to mirror the ESP32's float arithmetic before formatting.

This model is a test double, not a second implementation to ship: if
the .ino changes, change this file in the same commit.
"""

import struct

from aes_ccm import ccm_decrypt, ccm_encrypt

SCHEMA_V1 = 1
SCHEMA_V2 = 2
PKT_BEACON = 0x01
PKT_EVENT = 0x02
PKT_LEN = 22
WIRE_PSK_LEN = 34
NONCE_OFF, CT_OFF, TAG_OFF, TAG_LEN = 1, 9, 30, 4
PAYLOAD_LEN = 21  # v1 bytes [1..21]

GW_IP = "192.168.4.1"   # WiFi.softAPIP() of a stock gateway AP
GW_CH = 6               # WIFI_CH


def f32(x):
    """Round a Python float through IEEE-754 single precision (ESP32 float)."""
    return struct.unpack("f", struct.pack("f", x))[0]


def u16(p, o):
    return (p[o] << 8) | p[o + 1]


def u32(p, o):
    return (p[o] << 24) | (p[o + 1] << 16) | (p[o + 2] << 8) | p[o + 3]


def i32(p, o):
    v = u32(p, o)
    return v - 0x100000000 if v & 0x80000000 else v


def u64(p, o):
    v = 0
    for i in range(8):
        v = (v << 8) | p[o + i]
    return v


# --- node side (mirrors lora_node.ino) ---------------------------------------

def encode_beacon(suffix, uptime_s, ev_count, lat_e6, lon_e6, flags, fps, vbat_mv):
    p = bytearray(PKT_LEN)
    p[0] = SCHEMA_V1
    p[1] = PKT_BEACON
    p[2:4] = suffix.to_bytes(2, "big")
    p[4:8] = uptime_s.to_bytes(4, "big")
    p[8:10] = ev_count.to_bytes(2, "big")
    p[10:14] = (lat_e6 & 0xFFFFFFFF).to_bytes(4, "big")
    p[14:18] = (lon_e6 & 0xFFFFFFFF).to_bytes(4, "big")
    p[18] = flags
    p[19] = fps
    p[20:22] = vbat_mv.to_bytes(2, "big")
    return bytes(p)


def encode_event(suffix, t0, t_us, dur_s100, depth_db10, cls, conf100, sensor):
    p = bytearray(PKT_LEN)
    p[0] = SCHEMA_V1
    p[1] = PKT_EVENT
    p[2:4] = suffix.to_bytes(2, "big")
    p[4:8] = t0.to_bytes(4, "big")
    p[8:16] = t_us.to_bytes(8, "big")
    p[16:18] = min(dur_s100, 0xFFFF).to_bytes(2, "big")
    p[18] = min(depth_db10, 0xFF)
    p[19] = cls
    p[20] = min(conf100, 100)
    p[21] = sensor
    return bytes(p)


def wrap_psk(psk, plain22, boot_ctr, frame_ctr):
    """Mirror of wrapPsk() in lora_node.ino -> 34-byte v2 wire packet."""
    nonce = boot_ctr.to_bytes(4, "big") + frame_ctr.to_bytes(4, "big")
    ct_tag = ccm_encrypt(psk, nonce, plain22[1:], aad=bytes([SCHEMA_V2]), tag_len=TAG_LEN)
    return bytes([SCHEMA_V2]) + nonce + ct_tag


# --- gateway side (mirrors lora_gateway.ino) ---------------------------------

def _class_name(c):
    return "PASSING" if c == 1 else "LINGERING" if c == 2 else "UNKNOWN"


def _sensor_name(s):
    return "wifi" if s == 0 else "unknown"


def decode_v1_json(p, ip=GW_IP, ch=GW_CH):
    """Mirror of decodeV1 + reemitBeacon/reemitEvent.
    Returns the JSON string for a valid 22-byte v1 packet, else None."""
    if len(p) != PKT_LEN:
        return None
    if p[1] == PKT_BEACON:
        suffix = u16(p, 2)
        uptime_s = u32(p, 4)
        ev_count = u16(p, 8)
        lat = f32(i32(p, 10) / 1e6)
        lon = f32(i32(p, 14) / 1e6)
        flags, fps = p[18], p[19]
        return (
            '{"type":"beacon","node":"SLN-%04X","ip":"%s","ch":%d,'
            '"fps":%d,"events":%d,"uptime_s":%d,'
            '"sensors":["lora"],"ble_seen":0,'
            '"lat":%.6f,"lon":%.6f,"pps":%d}'
            % (suffix, ip, ch, fps, ev_count, uptime_s, lat, lon, 1 if flags & 0x02 else 0)
        )
    if p[1] == PKT_EVENT:
        suffix = u16(p, 2)
        t0 = u32(p, 4)
        t_us = u64(p, 8)
        dur_s = f32(u16(p, 16) / 100.0)
        depth_db = f32(p[18] / 10.0)
        cls, sensor = p[19], p[21]
        conf = f32(p[20] / 100.0)
        return (
            '{"type":"event","node":"SLN-%04X","sensor":"%s","t0":%d,'
            '"t_us":%d,"dur_s":%.1f,"depth_db":%.1f,'
            '"class":"%s","conf":%.2f,"detail":""}'
            % (suffix, _sensor_name(sensor), t0, t_us, dur_s, depth_db,
               _class_name(cls), conf)
        )
    return None


MAX_DISPLAY = 16   # HeardNode table size in lora_gateway.ino (display only)
MAX_FRESH = 48     # FreshEntry table size (freshness/replay state)


class Gateway:
    """Mirror of handlePacket() in lora_gateway.ino, with its counters.

    legacy_only=True models the OLD (pre-v2) gateway firmware: its gate
    accepts schema 1 only and drops schema 2 unseen.
    decrypt_calls counts actual CCM attempts, so tests can prove the
    schema gate fires before any decryption.

    Two kinds of per-node state, deliberately separate (mirrors the
    firmware):
      * self.display — the 16-entry status-page table. Filled by ANY
        successfully decoded frame (v1 included, unauthenticated). It
        is display ONLY: nothing security-relevant may consult it.
      * self.fresh — the freshness table: suffix -> (boot_ctr,
        frame_ctr), written only after a v2 frame passes the tag
        check, capped at MAX_FRESH. A v2 frame whose freshness cannot
        be established (unknown suffix, table full) is dropped and
        counted (rx_no_state) — fail closed. Pass the SAME dict as
        fresh= to a new Gateway to model the firmware's NVS
        persistence across a gateway reboot; pass nothing to model a
        reboot with persistence lost.
    """

    def __init__(self, psk=None, legacy_only=False, ip=GW_IP, ch=GW_CH, fresh=None):
        self.psk = psk
        self.legacy_only = legacy_only
        self.ip, self.ch = ip, ch
        self.rx_ok = 0
        self.rx_bad = 0
        self.rx_legacy = 0
        self.rx_auth_fail = 0
        self.rx_replay = 0
        self.rx_no_key = 0
        self.rx_no_state = 0
        self.decrypt_calls = 0
        self.display = set()                      # suffixes, cap MAX_DISPLAY
        self.fresh = {} if fresh is None else fresh  # suffix -> (boot, frame)

    def _register_display(self, suffix):
        """Mirror of findNodeIdx() as used by decodeV1: first-come
        slots, no eviction; purely cosmetic."""
        if suffix not in self.display and len(self.display) < MAX_DISPLAY:
            self.display.add(suffix)

    def handle(self, p):
        """Returns the list of JSON strings this frame causes the
        gateway to emit on UDP 49160 (0 or 1 entries)."""
        if len(p) < 1:
            self.rx_bad += 1
            return []
        if p[0] == SCHEMA_V1:
            if len(p) < 2:
                self.rx_bad += 1
                return []
            out = decode_v1_json(p, self.ip, self.ch)
            if out is None:
                # malformed schema-1: bad ONLY — legacy counts on
                # decode success (firmware counts it in decodeV1's
                # success branches, gated on wireV1)
                self.rx_bad += 1
                return []
            self.rx_legacy += 1
            self.rx_ok += 1
            self._register_display(u16(p, 2))
            return [out]
        if p[0] == SCHEMA_V2 and not self.legacy_only:
            if len(p) != WIRE_PSK_LEN:
                self.rx_bad += 1
                return []
            if self.psk is None:
                self.rx_no_key += 1
                return []
            self.decrypt_calls += 1
            plain = ccm_decrypt(self.psk, p[NONCE_OFF:NONCE_OFF + 8],
                                p[CT_OFF:CT_OFF + PAYLOAD_LEN] + p[TAG_OFF:TAG_OFF + TAG_LEN],
                                aad=bytes([SCHEMA_V2]), tag_len=TAG_LEN)
            if plain is None:
                self.rx_auth_fail += 1
                return []
            v1 = bytes([SCHEMA_V1]) + plain
            bc = u32(p, NONCE_OFF)
            fc = u32(p, NONCE_OFF + 4)
            suffix = u16(v1, 2)
            last = self.fresh.get(suffix)
            if last is not None:
                lbc, lfc = last
                if bc == lbc and fc <= lfc:
                    self.rx_replay += 1
                    return []
                # bc < lbc: accepted unconditionally, state rewinds
                # (node NVS wiped / reflash resync — spec'd trade)
            elif len(self.fresh) >= MAX_FRESH:
                # Freshness cannot be established -> fail closed.
                self.rx_no_state += 1
                return []
            self.fresh[suffix] = (bc, fc)
            out = decode_v1_json(v1, self.ip, self.ch)
            if out is None:
                self.rx_bad += 1
                return []
            self.rx_ok += 1
            self._register_display(suffix)
            return [out]
        self.rx_bad += 1  # unknown schema (or v2 at a legacy gateway)
        return []
