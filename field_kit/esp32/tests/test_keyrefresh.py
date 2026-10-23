#!/usr/bin/env python3
"""Host tests for the Shepherd LoRa key-refresh protocol (Mechanism
A: ML-KEM-512 refresh; Mechanism B: gateway-pushed rotation).

Run:  python3 test_keyrefresh.py      (or: python3 -m unittest -v)

Division of labor (same as the codec suites): this file runs the
Python MODEL (keyrefresh_model.py) for protocol/state-machine
semantics; the REAL vendored ML-KEM C code and the REAL keyrefresh.h
are proven by test_keyrefresh_cpp.cpp against NIST ACVP vectors.
The derivation primitives here (SHA-256/HMAC/HKDF/CCM) are stdlib /
the RFC-anchored aes_ccm.py reference, and HKDF is anchored to
RFC 5869 case 1 below.
"""

import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from keyrefresh_model import (  # noqa: E402
    CONFIRMED, IDLE, STAGED, KR_ERR_AUTH, KR_ERR_COUNTER, KR_ERR_STATE, KR_OK,
    FreshnessGateway, GwCtx, NodeCtx, hkdf_sha256, key_id, sha256,
    unwrap_psk, wrap_rotation,
)

CUR = bytes.fromhex("00112233445566778899aabbccddeeff")
WRONG = bytes.fromhex("ffeeddccbbaa99887766554433221100")
NEWK = bytes.fromhex("102132435465768798a9bacbdcedfe0f")
GWID = b"SLG-00A1"
NDID = b"SLN-00B2"
NONCE = bytes.fromhex("aabbccdd11223344")


def kem_handshake(node, gw, cur=CUR, committed=5, counter=6, gw_key=None):
    """Drive one Mechanism A exchange on the model; returns result
    codes. The stand-in KEM's shared secret crosses via node.model_ss
    exactly where the real decap would produce it."""
    rc, ek = node.begin_kem(committed, NDID, GWID, counter, 1000, b"seed-1")
    if rc != KR_OK:
        return rc, None
    rc, ct, auth, ss = gw.encap(gw_key if gw_key is not None else cur,
                                committed, GWID, NDID, counter, ek, 1000, b"m" * 32)
    if rc != KR_OK:
        return rc, None
    node.model_ss = ss
    rc, confirm = node.accept_encap(cur, ct, auth)
    if rc != KR_OK:
        return rc, None
    rc = gw.verify_confirm(confirm)
    return rc, confirm


class TestPrimitives(unittest.TestCase):
    def test_hkdf_rfc5869_case1(self):
        ikm = bytes([0x0B] * 22)
        salt = bytes.fromhex("000102030405060708090a0b0c")
        info = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
        okm = hkdf_sha256(ikm, salt, info, 42)
        self.assertEqual(
            okm.hex(),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
            "34007208d5b887185865")

    def test_key_id_convention(self):
        # key-ID = first 2 bytes of SHA-256(key) — same as the codec
        self.assertEqual(key_id(CUR), hashlib.sha256(CUR).digest()[:2])
        self.assertEqual(len(key_id(CUR)), 2)


class TestHandshake(unittest.TestCase):
    def test_happy_path_identical_key_and_commit(self):
        node, gw = NodeCtx(), GwCtx()
        rc, _ = kem_handshake(node, gw)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(node.staged_key, gw.staged_key)
        self.assertNotEqual(node.staged_key, CUR)
        self.assertEqual(gw.state, CONFIRMED)
        rc, cauth = gw.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        rc, key, ctr = node.commit(cauth)
        self.assertEqual((rc, ctr), (KR_OK, 6))
        self.assertEqual(key, gw.staged_key)
        rc, gkey, gctr = gw.promote()
        self.assertEqual((rc, gctr), (KR_OK, 6))
        self.assertEqual(gkey, key)
        self.assertEqual(node.ok_kem, 1)
        self.assertEqual(gw.ok_kem, 1)

    def test_wrong_psk_authenticator_fails_closed(self):
        node, gw = NodeCtx(), GwCtx()
        rc, _ = kem_handshake(node, gw, gw_key=WRONG)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(node.refuse_auth, 1)
        self.assertEqual(node.state, IDLE)  # aborted, nothing staged
        self.assertIsNone(node.staged_key)

    def test_tampered_ct_fails_closed(self):
        node, gw = NodeCtx(), GwCtx()
        rc, ek = node.begin_kem(5, NDID, GWID, 6, 0, b"s")
        self.assertEqual(rc, KR_OK)
        rc, ct, auth, ss = gw.encap(CUR, 5, GWID, NDID, 6, ek, 0, b"m" * 32)
        self.assertEqual(rc, KR_OK)
        bad = bytearray(ct); bad[200] ^= 0x40
        node.model_ss = ss
        rc, _ = node.accept_encap(CUR, bytes(bad), auth)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(node.state, IDLE)

    def test_tampered_counter_fails_closed(self):
        node, gw = NodeCtx(), GwCtx()
        rc, ek = node.begin_kem(5, NDID, GWID, 6, 0, b"s")
        self.assertEqual(rc, KR_OK)
        # gateway authenticates a DIFFERENT counter than the node staged
        rc, ct, auth, ss = gw.encap(CUR, 6, GWID, NDID, 7, ek, 0, b"m" * 32)
        self.assertEqual(rc, KR_OK)
        node.model_ss = ss
        rc, _ = node.accept_encap(CUR, ct, auth)
        self.assertEqual(rc, KR_ERR_AUTH)

    def test_rollback_counter_refused_distinctly(self):
        node, gw = NodeCtx(), GwCtx()
        rc, _ = node.begin_kem(5, NDID, GWID, 5, 0, b"s")  # == committed
        self.assertEqual(rc, KR_ERR_COUNTER)
        rc, _ = node.begin_kem(5, NDID, GWID, 3, 0, b"s")  # < committed
        self.assertEqual(rc, KR_ERR_COUNTER)
        self.assertEqual(node.refuse_counter, 2)
        rc, *_ = gw.encap(CUR, 5, GWID, NDID, 5, b"x" * 800, 0, b"m" * 32)
        self.assertEqual(rc, KR_ERR_COUNTER)


class TestRotation(unittest.TestCase):
    def test_happy_path(self):
        node, gw = NodeCtx(), GwCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 500)
        self.assertEqual(rc, KR_OK)
        # payload is CCM ciphertext under the current key, 34 B wire
        self.assertEqual(len(wire), 34)
        self.assertNotIn(NEWK, wire)
        rc = node.stage_rotation(CUR, 5, NDID, GWID, wire, 500)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(node.staged_key, NEWK)
        # F7: the gateway verifies the rotate reply BEFORE its window opens
        rc = gw.confirm_rotation(key_id(node.staged_key), node.target_counter)
        self.assertEqual(rc, KR_OK)
        rc, cauth = gw.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        rc, key, ctr = node.commit(cauth)
        self.assertEqual((rc, key, ctr), (KR_OK, NEWK, 6))
        rc, gkey, gctr = gw.promote()
        self.assertEqual((rc, gkey, gctr), (KR_OK, NEWK, 6))
        self.assertEqual(node.ok_rot, 1)

    def test_ccm_tamper_refused(self):
        gw = GwCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        bad = bytearray(wire); bad[15] ^= 0x01
        node = NodeCtx()
        rc = node.stage_rotation(CUR, 5, NDID, GWID, bytes(bad), 0)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(node.state, IDLE)

    def test_replay_and_rollback_refused(self):
        gw = GwCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        # after committing counter 6 under NEWK, the old payload is
        # both under the wrong key AND at a stale counter:
        node = NodeCtx()
        rc = node.stage_rotation(NEWK, 6, NDID, GWID, wire, 0)
        self.assertEqual(rc, KR_ERR_AUTH)
        # a payload honestly wrapped under the CURRENT key but with a
        # rolled-back counter is refused with the counter code:
        stale = wrap_rotation(NEWK, CUR, 6, NONCE)
        rc = node.stage_rotation(NEWK, 6, NDID, GWID, stale, 0)
        self.assertEqual(rc, KR_ERR_COUNTER)
        self.assertEqual(node.refuse_counter, 1)

    def test_timeout_reverts_to_old_key(self):
        gw = GwCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 1000)
        self.assertEqual(rc, KR_OK)
        node = NodeCtx()
        rc = node.stage_rotation(CUR, 5, NDID, GWID, wire, 1000)
        self.assertEqual(rc, KR_OK)
        self.assertFalse(node.expired(1000 + 119999, 120000))
        self.assertTrue(node.expired(1000 + 120001, 120000))
        node.abort()
        rc, *_ = node.commit(b"\x00" * 32)
        self.assertEqual(rc, KR_ERR_STATE)  # nothing left to commit


class TestDualKeyAndPersistence(unittest.TestCase):
    def test_dual_key_window(self):
        # LoRa frames are codec wraps of a fixed sample payload
        import gateway_model  # the codec model: wrap_psk builds them
        plain = gateway_model.encode_beacon(0x00B2, 10, 0, 0, 0, 0, 4, 0)
        wire_old = gateway_model.wrap_psk(CUR, plain, 7, 0)
        wire_new = gateway_model.wrap_psk(NEWK, plain, 7, 0)

        gw = GwCtx()
        ok, staged = gw.unwrap_dual(CUR, wire_old)
        self.assertEqual((ok, staged), (True, False))
        ok, _ = gw.unwrap_dual(CUR, wire_new)
        self.assertFalse(ok)  # window closed: new key not accepted

        rc, _wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(gw.state, STAGED)  # F7: window NOT open yet
        ok, _ = gw.unwrap_dual(CUR, wire_new)
        self.assertFalse(ok)
        rc = gw.confirm_rotation(key_id(NEWK), 6)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(gw.state, CONFIRMED)  # window open now
        ok, staged = gw.unwrap_dual(CUR, wire_old)
        self.assertEqual((ok, staged), (True, False))
        ok, staged = gw.unwrap_dual(CUR, wire_new)
        self.assertEqual((ok, staged), (True, True))
        self.assertEqual(gw.dual_key_frames, 1)

        gw.abort()  # window closes on abort: only old
        ok, _ = gw.unwrap_dual(CUR, wire_new)
        self.assertFalse(ok)
        ok, _ = gw.unwrap_dual(CUR, wire_old)
        self.assertTrue(ok)

    def test_persistence_semantics(self):
        # Model NVS: only the committed pair is ever written (on
        # commit/promote). A reboot restores it + an empty context.
        nvs = {"key": CUR, "ctr": 5}
        gw = GwCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        node = NodeCtx()
        rc = node.stage_rotation(nvs["key"], nvs["ctr"], NDID, GWID, wire, 0)
        self.assertEqual(rc, KR_OK)
        node = NodeCtx()  # reboot before commit: staged lost
        self.assertEqual(node.state, IDLE)
        self.assertEqual(nvs, {"key": CUR, "ctr": 5})  # untouched
        # stage + commit for real: only NOW does NVS change
        rc = node.stage_rotation(nvs["key"], nvs["ctr"], NDID, GWID, wire, 10)
        self.assertEqual(rc, KR_OK)
        rc = gw.confirm_rotation(key_id(node.staged_key), node.target_counter)
        self.assertEqual(rc, KR_OK)
        rc, cauth = gw.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        rc, key, ctr = node.commit(cauth)
        self.assertEqual(rc, KR_OK)
        nvs["key"], nvs["ctr"] = key, ctr  # the sketch's NVS write
        node = NodeCtx()  # reboot after commit: committed survives
        self.assertEqual(nvs, {"key": NEWK, "ctr": 6})
        self.assertEqual(sha256(nvs["key"])[:2], key_id(NEWK))


NDID_C = b"SLN-00C3"
NDID_D = b"SLN-00D4"


def _rot_pair(node_id=NDID, new_key=NEWK, counter=6, committed=5):
    """Gateway + node with a CONFIRMED rotation staged (post-F7)."""
    gw, node = GwCtx(), NodeCtx()
    rc, wire = gw.make_rotation(CUR, committed, new_key, counter, NONCE, 0,
                                 GWID, node_id)
    assert rc == KR_OK, rc
    rc = node.stage_rotation(CUR, committed, node_id, GWID, wire, 0)
    assert rc == KR_OK, rc
    rc = gw.confirm_rotation(key_id(node.staged_key), node.target_counter)
    assert rc == KR_OK, rc
    return gw, node


class TestCounterRuleGap(unittest.TestCase):
    """F2/F15: target > committed accepted (gaps are unused numbers);
    target <= committed refused with KR_ERR_COUNTER, all entry points."""

    def test_gap_counter_accepted(self):
        node = NodeCtx()
        rc, _ek = node.begin_kem(5, NDID, GWID, 7, 0, b"s")  # committed+2
        self.assertEqual(rc, KR_OK)
        gw = GwCtx()
        rc, *_ = gw.encap(CUR, 5, GWID, NDID, 7, b"x" * 800, 0, b"m" * 32)
        self.assertEqual(rc, KR_OK)
        gw2, node2 = GwCtx(), NodeCtx()
        rc, wire = gw2.make_rotation(CUR, 5, NEWK, 7, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        rc = node2.stage_rotation(CUR, 5, NDID, GWID, wire, 0)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(node2.target_counter, 7)

    def test_at_or_below_committed_refused(self):
        node = NodeCtx()
        rc, _ = node.begin_kem(5, NDID, GWID, 5, 0, b"s")
        self.assertEqual(rc, KR_ERR_COUNTER)
        gw = GwCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 5, NONCE, 0)
        self.assertEqual(rc, KR_ERR_COUNTER)


class TestBadCommitRetry(unittest.TestCase):
    """F15: a bad commit proof leaves the staged context alive."""

    def test_bad_commit_proof_keeps_context(self):
        gw, node = _rot_pair()
        rc, key, ctr = node.commit(b"\x00" * 32)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(node.state, CONFIRMED)  # alive for retry
        self.assertEqual(node.refuse_auth, 1)
        rc, cauth = gw.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        rc, key, ctr = node.commit(cauth)
        self.assertEqual((rc, key, ctr), (KR_OK, NEWK, 6))


class TestAbortAuth(unittest.TestCase):
    """F5: /kr/abort is authenticated like commit (staged-key proof)."""

    def test_no_context_is_noop_success(self):
        node = NodeCtx()
        self.assertEqual(node.verify_abort(CUR, None), KR_OK)
        self.assertEqual(node.verify_abort(CUR, b"\x00" * 32), KR_OK)

    def test_good_proof_aborts_bad_proof_keeps_context(self):
        gw, node = _rot_pair()
        self.assertEqual(node.verify_abort(CUR, b"\x00" * 32), KR_ERR_AUTH)
        self.assertEqual(node.state, CONFIRMED)  # kept
        rc, proof = gw.make_abort_auth(CUR)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(node.verify_abort(CUR, proof), KR_OK)
        self.assertEqual(node.state, IDLE)
        self.assertIsNone(node.staged_key)

    def test_staged_kem_abort_proof_uses_current_psk(self):
        node, gw = NodeCtx(), GwCtx()
        rc, ek = node.begin_kem(5, NDID, GWID, 6, 0, b"s")
        self.assertEqual(rc, KR_OK)
        rc, ct, auth, ss = gw.encap(CUR, 5, GWID, NDID, 6, ek, 0, b"m" * 32)
        self.assertEqual(rc, KR_OK)  # gateway STAGED, node STAGED
        rc, proof = gw.make_abort_auth(CUR)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(node.verify_abort(CUR, proof), KR_OK)
        self.assertEqual(node.state, IDLE)


class TestCrossNodeProof(unittest.TestCase):
    """F6/F15: node A's commit proof replayed to node B must fail —
    the Mechanism B commit context binds both identities."""

    def test_proof_for_a_fails_on_b(self):
        gw_a, node_a = _rot_pair(NDID)
        gw_b, node_b = _rot_pair(NDID_C)  # same key, counter, nonce
        rc, proof_a = gw_a.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        rc, key, ctr = node_b.commit(proof_a)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(node_b.state, CONFIRMED)  # B's context survives
        rc, proof_b = gw_b.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        self.assertNotEqual(proof_a, proof_b)
        rc, key, ctr = node_b.commit(proof_b)
        self.assertEqual((rc, key, ctr), (KR_OK, NEWK, 6))
        rc, key, ctr = node_a.commit(proof_a)
        self.assertEqual(rc, KR_OK)


class TestRotateReplyGate(unittest.TestCase):
    """F7/F15: window opens only after the rotate reply verifies;
    a mismatch fails AT the rotate step, visibly counted."""

    def test_mismatch_fails_session_at_rotate(self):
        gw, node = GwCtx(), NodeCtx()
        rc, wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(gw.state, STAGED)
        rc = node.stage_rotation(CUR, 5, NDID, GWID, wire, 0)
        self.assertEqual(rc, KR_OK)
        # gateway is told a counter that is NOT what it pushed:
        rc = gw.confirm_rotation(key_id(node.staged_key), 99)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(gw.rotate_mismatch, 1)
        self.assertGreaterEqual(gw.failures, 1)
        self.assertEqual(gw.state, IDLE)  # session failed at rotate

    def test_wrong_key_id_also_mismatch(self):
        gw = GwCtx()
        rc, _wire = gw.make_rotation(CUR, 5, NEWK, 6, NONCE, 0)
        self.assertEqual(rc, KR_OK)
        rc = gw.confirm_rotation(b"\xde\xad", 6)
        self.assertEqual(rc, KR_ERR_AUTH)
        self.assertEqual(gw.rotate_mismatch, 1)


class TestLostAckAndExpiry(unittest.TestCase):
    """F4/F15: a lost commit ACK keeps CONFIRMED + the window open,
    marked awaiting-frame; the frame trigger can still promote.
    Also covers gateway-side expiry (gwExpired in C++)."""

    def test_lost_ack_keeps_window_then_frame_promotes(self):
        gw, node = _rot_pair()
        import gateway_model
        plain = gateway_model.encode_beacon(0x00B2, 10, 0, 0, 0, 0, 4, 0)
        wire_new = gateway_model.wrap_psk(NEWK, plain, 7, 0)
        rc, cauth = gw.make_commit_auth()
        self.assertEqual(rc, KR_OK)
        rc, key, ctr = node.commit(cauth)  # node commits...
        self.assertEqual(rc, KR_OK)
        # ...but the gateway never sees the 200 (lost ACK):
        rc = gw.commit_ack_lost()
        self.assertEqual(rc, KR_OK)
        self.assertEqual(gw.state, CONFIRMED)       # NOT aborted
        self.assertTrue(gw.awaiting_frame)
        self.assertEqual(gw.ack_lost_count, 1)
        ok, staged = gw.unwrap_dual(CUR, wire_new)  # window still open
        self.assertEqual((ok, staged), (True, True))
        rc, gkey, gctr = gw.promote()               # frame trigger
        self.assertEqual((rc, gkey, gctr), (KR_OK, NEWK, 6))
        self.assertFalse(gw.awaiting_frame)

    def test_gw_expired(self):
        gw, _node = _rot_pair()
        self.assertFalse(gw.expired(119999, 120000))
        self.assertTrue(gw.expired(120001, 120000))


class TestFreshnessAfterCommit(unittest.TestCase):
    """F1/F15: freshness-aware gateway model. Node at (boot=7,
    frame=2800) refreshes; commit bumps its boot to 8 (F1a);
    post-commit frames (8, 0..) decode; replayed OLD frames
    (7, <=2800) are rejected under EITHER key; a replay-classified
    staged-key frame never promotes; the promoting frame itself
    is delivered, not dropped."""

    def _frames(self):
        import gateway_model
        plain = gateway_model.encode_beacon(0x00B2, 10, 0, 0, 0, 0, 4, 0)
        return plain, gateway_model

    def test_frame_trigger_promotion_and_replays(self):
        plain, gm = self._frames()
        fg = FreshnessGateway(CUR)
        old_hi = gm.wrap_psk(CUR, plain, 7, 2800)
        self.assertEqual(fg.handle(old_hi), (True, False))
        fg.open_window(NEWK)
        new0 = gm.wrap_psk(NEWK, plain, 8, 0)   # post-commit (boot bumped)
        self.assertEqual(fg.handle(new0), (True, True))   # delivered + promoted
        self.assertEqual(fg.committed_key, NEWK)
        new1 = gm.wrap_psk(NEWK, plain, 8, 1)
        self.assertEqual(fg.handle(new1), (True, False))
        # replays: exact duplicate of the promoting frame
        self.assertEqual(fg.handle(new0), (False, False))
        # replayed OLD frame under the old key (window closed: auth fails)
        self.assertEqual(fg.handle(old_hi), (False, False))
        # old counters re-wrapped under the NEW key: rebased suffix
        # rejects the lower boot outright
        old_ctr_new_key = gm.wrap_psk(NEWK, plain, 7, 2800)
        self.assertEqual(fg.handle(old_ctr_new_key), (False, False))

    def test_replay_classified_frame_never_promotes(self):
        plain, gm = self._frames()
        fg = FreshnessGateway(CUR)
        fg.handle(gm.wrap_psk(CUR, plain, 7, 2800))
        fg.open_window(NEWK)
        # a staged-key frame carrying counters at/below the high-water
        # is replay-classified: dropped, and NO promotion happens
        stale = gm.wrap_psk(NEWK, plain, 7, 100)
        self.assertEqual(fg.handle(stale), (False, False))
        self.assertEqual(fg.committed_key, CUR)  # still old key
        self.assertTrue(fg.window)               # window survives

    def test_ack_promotion_then_frames(self):
        plain, gm = self._frames()
        fg = FreshnessGateway(CUR)
        fg.handle(gm.wrap_psk(CUR, plain, 7, 2800))
        fg.open_window(NEWK)
        self.assertTrue(fg.promote_ack(0x00B2))
        self.assertEqual(fg.handle(gm.wrap_psk(NEWK, plain, 8, 0)), (True, False))
        self.assertEqual(fg.handle(gm.wrap_psk(NEWK, plain, 7, 2800)), (False, False))


class TestRound(unittest.TestCase):
    """F2/F15: 3-node Mechanism B round. Mid-round, old-key nodes
    keep decoding; nodes commit into the round WITHOUT gateway
    promotion; abort is permitted only before the first node
    commit; after the explicit promote, everyone is on the new key."""

    def test_three_node_round(self):
        import gateway_model
        plain, gm = gateway_model.encode_beacon(0x00B2, 10, 0, 0, 0, 0, 4, 0), gateway_model
        gw = GwCtx()
        nodes = {nid: NodeCtx() for nid in (NDID, NDID_C, NDID_D)}
        rc = gw.round_begin(5, GWID, NEWK, 6, 0)
        self.assertEqual(rc, KR_OK)
        self.assertTrue(gw.round_abort_permitted())
        fg = FreshnessGateway(CUR)
        fg.open_window(NEWK, round_open=True)

        def stage_commit(nid):
            node = nodes[nid]
            rc, wire, _ctx = gw.round_make_rotation(CUR, nid, NONCE)
            self.assertEqual(rc, KR_OK)
            rc = node.stage_rotation(CUR, 5, nid, GWID, wire, 0)
            self.assertEqual(rc, KR_OK)
            # F7-style reply verification before counting it staged
            self.assertEqual(key_id(node.staged_key), key_id(NEWK))
            self.assertEqual(node.target_counter, 6)
            gw.round_note_staged()
            rc, proof = gw.round_commit_auth(nid)
            self.assertEqual(rc, KR_OK)
            rc, key, ctr = node.commit(proof)
            self.assertEqual((rc, key, ctr), (KR_OK, NEWK, 6))
            gw.round_note_committed()

        # F6 inside the round: A's proof must fail on B
        node_a, node_b = nodes[NDID], nodes[NDID_C]
        rc, wire_a, _ = gw.round_make_rotation(CUR, NDID, NONCE)
        self.assertEqual(node_a.stage_rotation(CUR, 5, NDID, GWID, wire_a, 0), KR_OK)
        gw.round_note_staged()
        rc, wire_b, _ = gw.round_make_rotation(CUR, NDID_C, NONCE)
        self.assertEqual(node_b.stage_rotation(CUR, 5, NDID_C, GWID, wire_b, 0), KR_OK)
        gw.round_note_staged()
        rc, proof_a = gw.round_commit_auth(NDID)
        self.assertEqual(node_b.commit(proof_a)[0], KR_ERR_AUTH)  # replayed cross-node
        rc, proof_b = gw.round_commit_auth(NDID_C)
        self.assertEqual(node_b.commit(proof_b), (KR_OK, NEWK, 6))
        gw.round_note_committed()
        self.assertEqual(node_a.commit(proof_a), (KR_OK, NEWK, 6))
        gw.round_note_committed()
        # after the first node commit, abort is no longer permitted
        self.assertFalse(gw.round_abort_permitted())
        self.assertEqual(gw.round_committed, 2)

        # mid-round traffic: C still on the old key decodes; A (now
        # on the round key, boot bumped 3->4) decodes; NO promotion
        self.assertEqual(fg.handle(gm.wrap_psk(CUR, plain, 3, 10)), (True, False))
        self.assertEqual(fg.handle(gm.wrap_psk(NEWK, plain, 4, 0)), (True, False))
        self.assertEqual(fg.committed_key, CUR)  # gateway NOT promoted

        stage_commit(NDID_D)
        # explicit promote: gateway joins the round key at counter 6
        rc, gkey, gctr = gw.promote()
        self.assertEqual((rc, gkey, gctr), (KR_OK, NEWK, 6))
        self.assertFalse(gw.round_open)
        fg.committed_key = NEWK
        fg.close_window()
        self.assertEqual(fg.handle(gm.wrap_psk(NEWK, plain, 4, 1)), (True, False))
        self.assertEqual(fg.handle(gm.wrap_psk(CUR, plain, 3, 11)), (False, False))

    def test_round_abort_before_any_commit(self):
        gw = GwCtx()
        node = NodeCtx()
        self.assertEqual(gw.round_begin(5, GWID, NEWK, 6, 0), KR_OK)
        rc, wire, _ = gw.round_make_rotation(CUR, NDID, NONCE)
        self.assertEqual(rc, KR_OK)
        self.assertEqual(node.stage_rotation(CUR, 5, NDID, GWID, wire, 0), KR_OK)
        gw.round_note_staged()
        rc, aproof = gw.round_abort_auth(NDID)
        self.assertEqual(rc, KR_OK)
        self.assertTrue(gw.round_abort_permitted())
        gw.abort()  # gateway-side scrub
        self.assertFalse(gw.round_open)
        self.assertEqual(gw.state, IDLE)
        # the staged node honors the authenticated abort
        self.assertEqual(node.verify_abort(CUR, aproof), KR_OK)
        self.assertEqual(node.state, IDLE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
