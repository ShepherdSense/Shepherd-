#!/usr/bin/env python3
"""Host tests for the Shepherd LoRa codec v2 (PSK) change.

Run:  python3 test_lora_psk.py        (or: python3 -m unittest -v)

Covers what the task requires:
  * the reference crypto is anchored to published known answers
    (FIPS-197 AES KAT, RFC 3610 CCM vector #1);
  * encrypt/decrypt round-trip against the shared vectors file;
  * the gateway's schema gate fires BEFORE any decryption attempt;
  * wrong-PSK and tampered frames are rejected, never emitted;
  * replayed / stale-counter frames are rejected;
  * legacy v1 frames are still accepted by a PSK gateway, and v2
    frames are dropped by a legacy (pre-v2) gateway;
  * the gateway JSON for a v2 packet is byte-for-byte identical to
    the JSON for the equivalent v1 packet.
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from aes_ccm import aes128_encrypt_block, ccm_decrypt, ccm_encrypt  # noqa: E402
from gateway_model import (  # noqa: E402
    Gateway, MAX_DISPLAY, MAX_FRESH, SCHEMA_V2, WIRE_PSK_LEN,
    encode_beacon, wrap_psk,
)

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "lora_psk_vectors.json")) as f:
    VECTORS = json.load(f)
PSK = bytes.fromhex(VECTORS["psk_hex"])
WRONG_PSK = bytes.fromhex("101112131415161718191a1b1c1d1e1f")


def vec(name):
    return next(v for v in VECTORS["vectors"] if v["name"] == name)


class TestReferenceCrypto(unittest.TestCase):
    def test_aes128_fips197_kat(self):
        key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
        pt = bytes.fromhex("00112233445566778899aabbccddeeff")
        ct = aes128_encrypt_block(key, pt)
        self.assertEqual(ct.hex(), "69c4e0d86a7b0430d8cdb78070b4c55a")

    def test_ccm_rfc3610_vector_1(self):
        # RFC 3610, Test Vector #1 (7-byte nonce, 4-byte tag, AAD present)
        key = bytes.fromhex("404142434445464748494a4b4c4d4e4f")
        nonce = bytes.fromhex("10111213141516")
        aad = bytes.fromhex("0001020304050607")
        pt = bytes.fromhex("20212223")
        out = ccm_encrypt(key, nonce, pt, aad=aad, tag_len=4)
        self.assertEqual(out.hex(), "7162015b4dac255d")
        self.assertEqual(ccm_decrypt(key, nonce, out, aad=aad, tag_len=4), pt)

    def test_ccm_roundtrip_and_tamper(self):
        key = bytes(range(16))
        nonce = bytes(range(8))
        pt = bytes(range(21))
        out = ccm_encrypt(key, nonce, pt, aad=b"\x02", tag_len=4)
        self.assertEqual(ccm_decrypt(key, nonce, out, aad=b"\x02", tag_len=4), pt)
        for i in range(len(out)):  # every single-bit tamper must fail
            bad = bytearray(out)
            bad[i] ^= 0x01
            self.assertIsNone(ccm_decrypt(key, nonce, bytes(bad), aad=b"\x02", tag_len=4),
                              f"tamper at byte {i} was accepted")


class TestVectors(unittest.TestCase):
    def test_wire_matches_rewrap(self):
        for v in VECTORS["vectors"]:
            plain22 = bytes.fromhex(v["plain22_hex"])
            wire = wrap_psk(PSK, plain22, VECTORS["boot_ctr"], v["frame_ctr"])
            self.assertEqual(wire.hex(), v["wire34_hex"], v["name"])
            self.assertEqual(len(wire), WIRE_PSK_LEN)
            self.assertEqual(wire[0], SCHEMA_V2)

    def test_payload_does_not_leak_node_id(self):
        # The whole point: the v1 suffix bytes (plain22[2:4]) must not
        # appear at the same offset in the v2 wire packet.
        for v in VECTORS["vectors"]:
            plain22 = bytes.fromhex(v["plain22_hex"])
            wire = bytes.fromhex(v["wire34_hex"])
            self.assertNotEqual(wire[2:4], plain22[2:4], v["name"])

    def test_gateway_emits_expected_json(self):
        gw = Gateway(psk=PSK)
        for v in VECTORS["vectors"]:
            out = gw.handle(bytes.fromhex(v["wire34_hex"]))
            self.assertEqual(out, [v["expected_gateway_json"]], v["name"])


class TestGatewayBehavior(unittest.TestCase):
    def setUp(self):
        self.beacon_wire = bytes.fromhex(vec("beacon_psk")["wire34_hex"])
        self.beacon_plain = bytes.fromhex(vec("beacon_psk")["plain22_hex"])
        self.beacon_json = vec("beacon_psk")["expected_gateway_json"]

    def test_gate_before_decrypt_unknown_schema(self):
        gw = Gateway(psk=PSK)
        junk = bytes([0x63]) + bytes(33)  # unknown schema, v2-sized
        self.assertEqual(gw.handle(junk), [])
        self.assertEqual(gw.decrypt_calls, 0)  # gate fired first
        self.assertEqual(gw.rx_bad, 1)

    def test_gate_before_decrypt_wrong_length(self):
        gw = Gateway(psk=PSK)
        short = bytes([SCHEMA_V2]) + bytes(21)  # schema 2 but 22 bytes
        self.assertEqual(gw.handle(short), [])
        self.assertEqual(gw.decrypt_calls, 0)
        self.assertEqual(gw.rx_bad, 1)

    def test_wrong_psk_rejected(self):
        gw = Gateway(psk=WRONG_PSK)
        self.assertEqual(gw.handle(self.beacon_wire), [])
        self.assertEqual(gw.rx_auth_fail, 1)
        self.assertEqual(gw.rx_ok, 0)

    def test_tampered_wire_rejected(self):
        for off in (5, 12, 29, 33):  # nonce, ciphertext x2, tag
            gw = Gateway(psk=PSK)
            bad = bytearray(self.beacon_wire)
            bad[off] ^= 0x40
            self.assertEqual(gw.handle(bytes(bad)), [], f"offset {off}")
            self.assertEqual(gw.rx_auth_fail, 1, f"offset {off}")

    def test_psk_gateway_without_key_drops_v2(self):
        gw = Gateway(psk=None)
        self.assertEqual(gw.handle(self.beacon_wire), [])
        self.assertEqual(gw.rx_no_key, 1)
        self.assertEqual(gw.decrypt_calls, 0)

    def test_legacy_packet_accepted_and_json_identical(self):
        gw = Gateway(psk=PSK)
        out_legacy = gw.handle(self.beacon_plain)     # v1 frame
        self.assertEqual(out_legacy, [self.beacon_json])
        self.assertEqual(gw.rx_legacy, 1)
        out_v2 = gw.handle(self.beacon_wire)          # same content, v2
        self.assertEqual(out_v2, out_legacy)          # byte-for-byte

    def test_legacy_gateway_drops_v2(self):
        gw = Gateway(psk=PSK, legacy_only=True)       # pre-v2 firmware
        self.assertEqual(gw.handle(self.beacon_wire), [])
        self.assertEqual(gw.rx_bad, 1)
        self.assertEqual(gw.decrypt_calls, 0)
        # ...but still serves v1 nodes fine
        self.assertEqual(gw.handle(self.beacon_plain), [self.beacon_json])

    def test_replay_rejected(self):
        gw = Gateway(psk=PSK)
        self.assertEqual(gw.handle(self.beacon_wire), [self.beacon_json])
        self.assertEqual(gw.handle(self.beacon_wire), [])  # exact replay
        self.assertEqual(gw.rx_replay, 1)
        # the next frame (frame_ctr+1) is accepted
        nxt = wrap_psk(PSK, self.beacon_plain, VECTORS["boot_ctr"],
                       vec("beacon_psk")["frame_ctr"] + 1)
        self.assertEqual(gw.handle(nxt), [self.beacon_json])

    def test_stale_boot_rejected_then_resync_after_reflash(self):
        gw = Gateway(psk=PSK)
        newer = wrap_psk(PSK, self.beacon_plain, 9, 0)
        self.assertEqual(gw.handle(newer), [self.beacon_json])
        same_boot_older = wrap_psk(PSK, self.beacon_plain, 9, 0)
        self.assertEqual(gw.handle(same_boot_older), [])   # replay of ctr 0
        # node reflashed: boot_ctr restarts below the stored one -> the
        # gateway resyncs (spec'd acceptance) instead of locking it out
        reflashed = wrap_psk(PSK, self.beacon_plain, 1, 0)
        self.assertEqual(gw.handle(reflashed), [self.beacon_json])


def v2_beacon(suffix, boot=7, fc=0):
    plain = encode_beacon(suffix, 10, 0, 0, 0, 0, 4, 0)
    return wrap_psk(PSK, plain, boot, fc)


def v1_beacon(suffix):
    return encode_beacon(suffix, 10, 0, 0, 0, 0, 4, 0)


class TestFreshnessDecoupling(unittest.TestCase):
    """The fix-pass regression class: freshness/replay state lives in
    its own storage, decoupled from the 16-entry display table, is
    persisted across gateway reboots, and fails closed."""

    def setUp(self):
        self.beacon_wire = bytes.fromhex(vec("beacon_psk")["wire34_hex"])
        self.beacon_json = vec("beacon_psk")["expected_gateway_json"]
        self.suffix = 0xA3F1

    def test_legacy_counter_only_on_successful_decode(self):
        # Fix: rxLegacy used to increment before decode, so a malformed
        # schema-1 frame counted as legacy AND bad. Now: bad only.
        gw = Gateway(psk=PSK)
        bad = bytearray(v1_beacon(0x1111))
        bad[1] = 0x09  # unknown packet type, schema still 1
        self.assertEqual(gw.handle(bytes(bad)), [])
        self.assertEqual(gw.rx_bad, 1)
        self.assertEqual(gw.rx_legacy, 0)
        self.assertEqual(len(gw.handle(v1_beacon(0x1111))), 1)
        self.assertEqual(gw.rx_legacy, 1)

    def test_display_table_full_replay_still_rejected(self):
        gw = Gateway(psk=PSK)
        # Stuff the 16-entry DISPLAY table with unauthenticated v1
        # beacons from other suffixes until it is full.
        for i in range(MAX_DISPLAY):
            self.assertEqual(len(gw.handle(v1_beacon(0x3000 + i))), 1)
        self.assertEqual(len(gw.display), MAX_DISPLAY)
        # The v2 node's frame decodes (and emits) even though the
        # display table has no slot for it — that was the old hole's
        # exact precondition: the node never got a display entry, so
        # the replay check (which lived there) was skipped.
        self.assertEqual(gw.handle(self.beacon_wire), [self.beacon_json])
        self.assertNotIn(self.suffix, gw.display)
        # ...but freshness lives elsewhere: the replay is rejected.
        self.assertEqual(gw.handle(self.beacon_wire), [])
        self.assertEqual(gw.rx_replay, 1)

    def test_v1_stuffing_does_not_open_replay_hole(self):
        gw = Gateway(psk=PSK)
        # v1 frames — including one spoofing the v2 node's own suffix —
        # must not create or influence freshness state.
        self.assertEqual(len(gw.handle(v1_beacon(self.suffix))), 1)
        for i in range(MAX_DISPLAY):
            gw.handle(v1_beacon(0x4000 + i))
        self.assertNotIn(self.suffix, gw.fresh)
        self.assertEqual(len(gw.fresh), 0)
        # The genuine v2 frame is a first-seen accept, and its replay
        # is rejected on the freshness state the v1 traffic never saw.
        self.assertEqual(gw.handle(self.beacon_wire), [self.beacon_json])
        self.assertEqual(gw.handle(self.beacon_wire), [])
        self.assertEqual(gw.rx_replay, 1)

    def test_freshness_table_full_fails_closed(self):
        gw = Gateway(psk=PSK)
        for i in range(MAX_FRESH):
            out = gw.handle(v2_beacon(0x1000 + i, boot=7, fc=0))
            self.assertEqual(len(out), 1, f"node {i}")
        self.assertEqual(len(gw.fresh), MAX_FRESH)
        # One more distinct keyed node: its frame is authentic but its
        # freshness cannot be established -> dropped, counted, and
        # NEVER decoded/emitted.
        self.assertEqual(gw.handle(v2_beacon(0x2000, boot=7, fc=0)), [])
        self.assertEqual(gw.rx_no_state, 1)
        self.assertEqual(gw.rx_ok, MAX_FRESH)

    def test_reboot_with_persisted_freshness_rejects_replay(self):
        store = {}  # models the gateway's NVS blob, shared across boots
        gw1 = Gateway(psk=PSK, fresh=store)
        self.assertEqual(gw1.handle(self.beacon_wire), [self.beacon_json])
        # Gateway reboots; freshness restored from "NVS":
        gw2 = Gateway(psk=PSK, fresh=store)
        self.assertEqual(gw2.handle(self.beacon_wire), [])  # exact replay
        self.assertEqual(gw2.rx_replay, 1)
        # ...and the genuine node's next frame is still accepted.
        nxt = wrap_psk(PSK, bytes.fromhex(vec("beacon_psk")["plain22_hex"]),
                       VECTORS["boot_ctr"], vec("beacon_psk")["frame_ctr"] + 1)
        self.assertEqual(gw2.handle(nxt), [self.beacon_json])

    def test_reboot_without_persistence_accepts_replay(self):
        # Documents the hole persistence closes: a gateway that lost
        # its freshness state treats a replayed frame as first-seen.
        gw = Gateway(psk=PSK)  # fresh state NOT shared -> "NVS lost"
        self.assertEqual(gw.handle(self.beacon_wire), [self.beacon_json])
        self.assertEqual(gw.rx_replay, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
