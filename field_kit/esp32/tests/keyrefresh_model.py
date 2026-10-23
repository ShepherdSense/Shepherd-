"""Host-side model of the Shepherd LoRa key-refresh protocol,
mirroring esp32/shepherd_lora_keyrefresh/src/keyrefresh.h step for
step (transcript, HMAC authentication, HKDF derivation, rotation
payload layout, stage/confirm/commit state machine, dual-key window,
monotonic counter, staged-state volatility).

The ML-KEM itself is modeled as an opaque deterministic stand-in
(keypair/encap/decap over hashes): Python's stdlib has no ML-KEM,
and the REAL vendored C code is known-answer-tested against the
NIST ACVP vectors by test_keyrefresh_cpp.cpp. This model proves the
protocol logic around the KEM — the same division of labor as
gateway_model.py vs the C++ codec test. Everything else here
(SHA-256, HMAC, HKDF, AES-CCM rotation wrap via aes_ccm.py) is the
real algorithm from the stdlib / the anchored reference.
"""

import hashlib
import hmac as hmac_mod
import struct

from aes_ccm import ccm_decrypt, ccm_encrypt

SCHEMA_V2 = 2
KEY_LEN = 16
EK_LEN, CT_LEN, SS_LEN = 800, 768, 32

KR_OK, KR_ERR_COUNTER, KR_ERR_AUTH, KR_ERR_STATE, KR_ERR_FORMAT, KR_ERR_CRYPTO = range(6)
IDLE, STAGED, CONFIRMED = 0, 1, 2
MECH_KEM, MECH_ROT = 1, 2


def sha256(b):
    return hashlib.sha256(b).digest()


def hmac256(key, data):
    return hmac_mod.new(key, data, hashlib.sha256).digest()


def hkdf_sha256(ikm, salt, info, length):
    prk = hmac256(salt, ikm)
    okm, t, ctr = b"", b"", 1
    while len(okm) < length:
        t = hmac256(prk, t + info + bytes([ctr]))
        okm += t
        ctr += 1
    return okm[:length]


def key_id(key):
    return sha256(key)[:2]


def _kem_keypair(seed_material):
    """Stand-in KEM: ek is a padded hash stream; sk wraps the seed.
    Deterministic so both model sides agree; NOT cryptography."""
    ek = b"".join(sha256(b"EK" + seed_material + bytes([i])) for i in range(25))[:EK_LEN]
    return ek, b"SK" + seed_material  # sk opaque to the model


def _kem_encap(ek, m):
    ss = sha256(b"SS" + ek + m)
    ct = b"".join(sha256(b"CT" + m + ek + bytes([i])) for i in range(24))[:CT_LEN]
    return ct, ss


def _kem_decap(sk, ct):
    # The model cannot invert the stand-in encap, so the node's
    # context carries the ss from a shared test channel: see
    # NodeCtx.model_ss, set by the test harness to the gateway's ss.
    return sk  # placeholder, replaced by harness


def build_transcript(gw_id, node_id, counter, ek, ct):
    return b"SHKR1" + gw_id + node_id + struct.pack(">I", counter) + ek + ct


def derive_key(ss, transcript_hash, cur_key, counter):
    info = b"shepherd-kr-v1" + sha256(cur_key) + struct.pack(">I", counter)
    return hkdf_sha256(ss, transcript_hash, info, KEY_LEN)


def make_proof(new_key, label, commit_ctx):
    return hmac256(new_key, label + commit_ctx)


def rot_commit_ctx(gw_id, node_id, counter):
    """F6: SHA-256("SHKR1-ROT" || gwId || nodeId || counter BE)."""
    return sha256(b"SHKR1-ROT" + gw_id + node_id + struct.pack(">I", counter))


def abort_stage_ctx(counter):
    return sha256(b"SHKR1-ABORT-CTX" + struct.pack(">I", counter))


def wrap_rotation(cur_key, new_key, counter, nonce8):
    """Mirror of gwMakeRotation + shepherd_psk::wrap (codec header)."""
    plain21 = bytes([0x4B]) + struct.pack(">I", counter) + new_key
    assert len(plain21) == 21
    ct_tag = ccm_encrypt(cur_key, nonce8, plain21, aad=bytes([SCHEMA_V2]), tag_len=4)
    return bytes([SCHEMA_V2]) + nonce8 + ct_tag


def unwrap_psk(key, wire):
    if len(wire) != 34 or wire[0] != SCHEMA_V2:
        return None
    return ccm_decrypt(key, wire[1:9], wire[9:30] + wire[30:34],
                       aad=bytes([SCHEMA_V2]), tag_len=4)


class NodeCtx:
    def __init__(self):
        self.state = IDLE
        self.mech = 0
        self.target_counter = 0
        self.peer_id = self.self_id = b"\x00" * 8
        self.ek = b""
        self.staged_key = None
        self.commit_ctx = b""
        self.staged_at = 0
        self.model_ss = None  # harness channel for the stand-in KEM
        self.refuse_auth = self.refuse_counter = self.refuse_state = 0
        self.failures = 0
        self.ok_kem = self.ok_rot = 0

    def abort(self):
        self.state, self.mech, self.target_counter = IDLE, 0, 0
        self.staged_key = None

    def expired(self, now, timeout):
        return self.state != IDLE and (now - self.staged_at) > timeout

    def begin_kem(self, committed_ctr, self_id, peer_id, counter, now, seed):
        if self.state != IDLE:
            self.refuse_state += 1
            return KR_ERR_STATE, None
        if counter <= committed_ctr:  # F2 counter rule: accept iff > committed
            self.refuse_counter += 1
            return KR_ERR_COUNTER, None
        self.ek, _sk = _kem_keypair(seed)
        self.self_id, self.peer_id = self_id, peer_id
        self.target_counter, self.staged_at = counter, now
        self.mech, self.state = MECH_KEM, STAGED
        return KR_OK, self.ek

    def accept_encap(self, cur_key, ct, auth):
        if self.state != STAGED or self.mech != MECH_KEM:
            self.refuse_state += 1
            return KR_ERR_STATE, None
        t = build_transcript(self.peer_id, self.self_id, self.target_counter, self.ek, ct)
        if not hmac_mod.compare_digest(hmac256(cur_key, t), auth):
            self.refuse_auth += 1
            self.abort()
            return KR_ERR_AUTH, None
        ss = self.model_ss  # stand-in decap result (harness-supplied)
        th = sha256(t)
        self.commit_ctx = th
        self.staged_key = derive_key(ss, th, cur_key, self.target_counter)
        self.state = CONFIRMED
        return KR_OK, make_proof(self.staged_key, b"SHKR1-CONFIRM", self.commit_ctx)

    def stage_rotation(self, cur_key, committed_ctr, self_id, peer_id, wire, now):
        if self.state != IDLE:
            self.refuse_state += 1
            return KR_ERR_STATE
        plain = unwrap_psk(cur_key, wire)
        if plain is None:
            self.refuse_auth += 1
            return KR_ERR_AUTH
        if plain[0] != 0x4B:
            self.failures += 1
            return KR_ERR_FORMAT
        counter = struct.unpack(">I", plain[1:5])[0]
        if counter <= committed_ctr:  # F2 counter rule
            self.refuse_counter += 1
            return KR_ERR_COUNTER
        self.staged_key = plain[5:21]
        self.self_id, self.peer_id = self_id, peer_id
        self.target_counter, self.staged_at = counter, now
        self.commit_ctx = rot_commit_ctx(peer_id, self_id, counter)  # F6
        self.mech, self.state = MECH_ROT, CONFIRMED
        return KR_OK

    def commit(self, commit_auth):
        if self.state != CONFIRMED:
            self.refuse_state += 1
            return KR_ERR_STATE, None, None
        expect = make_proof(self.staged_key, b"SHKR1-COMMIT", self.commit_ctx)
        if not hmac_mod.compare_digest(expect, commit_auth):
            self.refuse_auth += 1
            return KR_ERR_AUTH, None, None  # context kept: retry allowed
        key, ctr = self.staged_key, self.target_counter
        if self.mech == MECH_KEM:
            self.ok_kem += 1
        else:
            self.ok_rot += 1
        self.abort()
        return KR_OK, key, ctr

    def verify_abort(self, cur_key, auth):
        """F5 mirror of nodeVerifyAbort: no context -> no-op success;
        CONFIRMED -> staged-key proof; STAGED (KEM) -> current-PSK
        proof. Bad proof refused, context kept."""
        if self.state == IDLE:
            return KR_OK
        if auth is None or len(auth) != 32:
            self.refuse_auth += 1
            return KR_ERR_AUTH
        if self.state == CONFIRMED:
            expect = make_proof(self.staged_key, b"SHKR1-ABORT", self.commit_ctx)
        else:
            expect = make_proof(cur_key, b"SHKR1-ABORT",
                                abort_stage_ctx(self.target_counter))
        if not hmac_mod.compare_digest(expect, auth):
            self.refuse_auth += 1
            return KR_ERR_AUTH
        self.abort()
        return KR_OK


class GwCtx:
    def __init__(self):
        self.state = IDLE
        self.mech = 0
        self.target_counter = 0
        self.self_id = self.peer_id = b"\x00" * 8
        self.staged_key = None
        self.commit_ctx = b""
        self.staged_at = 0
        self.refuse_auth = self.refuse_counter = self.refuse_state = 0
        self.failures = 0
        self.ok_kem = self.ok_rot = self.dual_key_frames = 0
        self.rotate_mismatch = 0       # F7
        self.awaiting_frame = False    # F4
        self.ack_lost_count = 0        # F4
        self.round_open = False        # F2
        self.round_staged = 0
        self.round_committed = 0

    def abort(self):
        self.state, self.mech, self.target_counter = IDLE, 0, 0
        self.staged_key = None
        self.awaiting_frame = False
        self.round_open = False
        self.round_staged = self.round_committed = 0

    def expired(self, now, timeout):
        return self.state != IDLE and (now - self.staged_at) > timeout

    def encap(self, cur_key, committed_ctr, self_id, peer_id, counter, ek, now, m):
        if self.state != IDLE:
            self.refuse_state += 1
            return KR_ERR_STATE, None, None, None
        if counter <= committed_ctr:  # F2 counter rule
            self.refuse_counter += 1
            return KR_ERR_COUNTER, None, None, None
        ct, ss = _kem_encap(ek, m)
        t = build_transcript(self_id, peer_id, counter, ek, ct)
        auth = hmac256(cur_key, t)
        th = sha256(t)
        self.commit_ctx = th
        self.staged_key = derive_key(ss, th, cur_key, counter)
        self.target_counter, self.staged_at = counter, now
        self.mech, self.state = MECH_KEM, STAGED
        return KR_OK, ct, auth, ss

    def verify_confirm(self, confirm):
        if self.state != STAGED:
            self.refuse_state += 1
            return KR_ERR_STATE
        expect = make_proof(self.staged_key, b"SHKR1-CONFIRM", self.commit_ctx)
        if not hmac_mod.compare_digest(expect, confirm):
            self.refuse_auth += 1
            self.abort()
            return KR_ERR_AUTH
        self.state = CONFIRMED
        return KR_OK

    def make_rotation(self, cur_key, committed_ctr, new_key, counter, nonce8, now,
                      gw_id=b"SLG-00A1", node_id=b"SLN-00B2"):
        if self.state != IDLE:
            self.refuse_state += 1
            return KR_ERR_STATE, None
        if counter <= committed_ctr:  # F2 counter rule
            self.refuse_counter += 1
            return KR_ERR_COUNTER, None
        wire = wrap_rotation(cur_key, new_key, counter, nonce8)
        self.staged_key = new_key
        self.self_id, self.peer_id = gw_id, node_id
        self.target_counter, self.staged_at = counter, now
        self.commit_ctx = rot_commit_ctx(gw_id, node_id, counter)  # F6
        self.mech, self.state = MECH_ROT, STAGED  # F7: window NOT yet open
        return KR_OK, wire

    def confirm_rotation(self, node_key_id, node_counter):
        """F7 mirror of gwConfirmRotation: window opens only here."""
        if self.state != STAGED or self.mech != MECH_ROT:
            self.refuse_state += 1
            return KR_ERR_STATE
        if node_counter != self.target_counter or key_id(self.staged_key) != node_key_id:
            self.failures += 1
            self.rotate_mismatch += 1
            self.abort()
            return KR_ERR_AUTH
        self.state = CONFIRMED
        return KR_OK

    def make_commit_auth(self):
        if self.state != CONFIRMED:
            self.refuse_state += 1
            return KR_ERR_STATE, None
        return KR_OK, make_proof(self.staged_key, b"SHKR1-COMMIT", self.commit_ctx)

    def make_abort_auth(self, cur_key):
        """F5 mirror of gwMakeAbortAuth."""
        if self.state == CONFIRMED:
            return KR_OK, make_proof(self.staged_key, b"SHKR1-ABORT", self.commit_ctx)
        if self.state == STAGED and self.mech == MECH_KEM:
            return KR_OK, make_proof(cur_key, b"SHKR1-ABORT",
                                     abort_stage_ctx(self.target_counter))
        if self.state == STAGED and self.mech == MECH_ROT:
            return KR_OK, make_proof(self.staged_key, b"SHKR1-ABORT", self.commit_ctx)
        self.refuse_state += 1
        return KR_ERR_STATE, None

    def commit_ack_lost(self):
        """F4 mirror of gwNoteCommitAckLost."""
        if self.state != CONFIRMED:
            self.refuse_state += 1
            return KR_ERR_STATE
        self.awaiting_frame = True
        self.ack_lost_count += 1
        return KR_OK

    # ---- F2: gateway round (Mechanism B fleet rounds) ----
    def round_begin(self, committed_ctr, gw_id, round_key, counter, now):
        if self.state != IDLE or self.round_open:
            self.refuse_state += 1
            return KR_ERR_STATE
        if counter <= committed_ctr:
            self.refuse_counter += 1
            return KR_ERR_COUNTER
        self.staged_key = round_key
        self.self_id = gw_id
        self.target_counter, self.staged_at = counter, now
        self.commit_ctx = b""
        self.mech, self.state = MECH_ROT, CONFIRMED
        self.round_open = True
        self.round_staged = self.round_committed = 0
        return KR_OK

    def round_make_rotation(self, cur_key, node_id, nonce8):
        if not self.round_open or self.state != CONFIRMED:
            self.refuse_state += 1
            return KR_ERR_STATE, None, None
        wire = wrap_rotation(cur_key, self.staged_key, self.target_counter, nonce8)
        ctx = rot_commit_ctx(self.self_id, node_id, self.target_counter)
        self.peer_id = node_id
        return KR_OK, wire, ctx

    def round_commit_auth(self, node_id):
        if not self.round_open or self.state != CONFIRMED:
            self.refuse_state += 1
            return KR_ERR_STATE, None
        ctx = rot_commit_ctx(self.self_id, node_id, self.target_counter)
        return KR_OK, make_proof(self.staged_key, b"SHKR1-COMMIT", ctx)

    def round_abort_auth(self, node_id):
        if not self.round_open:
            self.refuse_state += 1
            return KR_ERR_STATE, None
        ctx = rot_commit_ctx(self.self_id, node_id, self.target_counter)
        return KR_OK, make_proof(self.staged_key, b"SHKR1-ABORT", ctx)

    def round_note_staged(self):
        if self.round_open:
            self.round_staged += 1

    def round_note_committed(self):
        if self.round_open:
            self.round_committed += 1

    def round_abort_permitted(self):
        return self.round_open and self.round_committed == 0

    def promote(self):
        if self.state != CONFIRMED:
            self.refuse_state += 1
            return KR_ERR_STATE, None, None
        key, ctr = self.staged_key, self.target_counter
        if self.mech == MECH_KEM:
            self.ok_kem += 1
        else:
            self.ok_rot += 1
        self.abort()
        return KR_OK, key, ctr

    def unwrap_dual(self, cur_key, wire):
        """(ok, used_staged): committed key first, staged second,
        staged only while the window is open (CONFIRMED)."""
        plain = unwrap_psk(cur_key, wire)
        if plain is not None:
            return True, False
        if self.state == CONFIRMED and self.staged_key is not None:
            plain = unwrap_psk(self.staged_key, wire)
            if plain is not None:
                self.dual_key_frames += 1
                return True, True
        return False, False


class FreshnessGateway:
    """F1 freshness-aware gateway model, mirroring the ordering in
    lora_gateway.ino handlePacket() after the fix:

      unwrap (committed, then staged while the window is open)
        -> if the frame used the staged key and this is NOT a round,
           it is a promotion CANDIDATE only: it must first pass the
           freshness check under the rebased state (the suffix's
           entry is cleared, then the frame's own counters seed it).
           A replay-classified frame never promotes and is dropped.
        -> freshness check -> deliver.

    Node commit bumps the node's boot_ctr persistently (F1a), so the
    first post-commit frame arrives as (boot+1, 0..). A suffix whose
    entry was rebased at a promotion is in self.rebased: for it, a
    boot counter LOWER than the stored one is rejected outright
    (the legacy 'lower boot = reflash resync' acceptance no longer
    applies to a refreshed suffix — otherwise a captured pre-commit
    frame could rewind the state the commit just advanced).
    """

    def __init__(self, committed_key):
        self.committed_key = committed_key
        self.staged_key = None
        self.window = False
        self.round_open = False
        self.fresh = {}      # suffix -> (boot_ctr, frame_ctr)
        self.rebased = set()  # suffixes rebased at a KR promotion

    def open_window(self, staged_key, round_open=False):
        self.staged_key = staged_key
        self.window = True
        self.round_open = round_open

    def close_window(self):
        self.staged_key = None
        self.window = False
        self.round_open = False

    def promote_ack(self, suffix):
        """Explicit commit ACK path: promote + rebase that suffix."""
        if not self.window or self.round_open:
            return False
        self.committed_key = self.staged_key
        self.close_window()
        self.fresh.pop(suffix, None)
        self.rebased.add(suffix)
        return True

    def _fresh_ok(self, suffix, bc, fc):
        last = self.fresh.get(suffix)
        if last is None:
            return True
        lbc, lfc = last
        if bc == lbc and fc <= lfc:
            return False
        if bc < lbc and suffix in self.rebased:
            return False
        return True

    def handle(self, wire):
        """Returns (delivered, promoted)."""
        plain = unwrap_psk(self.committed_key, wire)
        used_staged = False
        if plain is None and self.window and self.staged_key is not None:
            plain = unwrap_psk(self.staged_key, wire)
            used_staged = plain is not None
        if plain is None:
            return False, False
        bc, fc = struct.unpack(">II", wire[1:9])
        suffix = struct.unpack(">H", plain[1:3])[0]
        if used_staged and not self.round_open:
            # Promotion candidate: classify under the PRE-rebase
            # high-water first — a replay never promotes (F1c).
            last = self.fresh.get(suffix)
            if last is not None and (bc < last[0] or (bc == last[0] and fc <= last[1])):
                return False, False
            # Rebase (F1b): clear the entry, the frame seeds it, and
            # only now promote — the frame itself is delivered.
            self.fresh[suffix] = (bc, fc)
            self.rebased.add(suffix)
            self.committed_key = self.staged_key
            self.close_window()
            return True, True
        if not self._fresh_ok(suffix, bc, fc):
            return False, False
        self.fresh[suffix] = (bc, fc)
        if used_staged and self.round_open:
            # A round node that committed has bumped its boot_ctr;
            # from its first staged-key frame on, the rebased rule
            # protects its suffix like a promoted one.
            self.rebased.add(suffix)
        return True, False
