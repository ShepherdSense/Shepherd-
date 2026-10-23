/*
 * keyrefresh.h — Shepherd LoRa key refresh / rotation protocol.
 *
 * Single shared implementation of the stage -> confirm -> commit
 * machinery used by BOTH mechanisms in docs/lora_key_refresh_spec.md:
 *
 *   Mechanism A (ML-KEM-512 refresh): node generates an ephemeral
 *     ML-KEM-512 keypair (vendored PQClean code, src/mlkem/); the
 *     gateway encapsulates; the transcript is authenticated with
 *     HMAC-SHA256 keyed by the CURRENT PSK (the PSK acts as the
 *     authenticator, not the key source); the new PSK is
 *     HKDF-SHA256 over the ML-KEM shared secret, bound to the
 *     transcript hash, the current-PSK hash, and the key_counter.
 *   Mechanism B (gateway-pushed rotation): the gateway wraps a new
 *     16-byte PSK in the EXISTING codec wrap (shepherd_psk::wrap —
 *     AES-128-CCM under the current PSK, lora_psk_codec.h) and the
 *     node unwraps it. No crypto is duplicated here for this path.
 *
 * Both mechanisms converge on the same staged-candidate state: the
 * candidate key is stored SEPARATELY, TX/RX keep using the committed
 * key, and only an authenticated COMMIT promotes it. A monotonic
 * key_counter (persisted in NVS by the sketches, committed state
 * only) refuses any stage at counter <= committed counter; any
 * target > committed is accepted and commit sets committed :=
 * target (spec §8, F2 counter rule — payloads are authenticated
 * under the current shared key, skipped counters are unused
 * numbers, rollback remains impossible). Staged state is RAM-only:
 * a reboot anywhere before commit is an automatic, safe abort —
 * the old key was never deleted.
 *
 * Mechanism B additionally supports a gateway ROUND (spec §11):
 * one round key staged on many nodes while the gateway holds its
 * dual-key window open, with promotion only on the operator's
 * explicit round promote. The round helpers below keep the round
 * key in the same GwCtx (stagedKey/targetCounter) and compute
 * per-node commit contexts on demand (F6 identity binding).
 *
 * This header is the pure byte-buffer logic: no Wi-Fi, no NVS, no
 * Arduino types. The sketches own transport (Wi-Fi HTTP) and
 * persistence. Host tests (esp32/tests/test_keyrefresh_cpp.cpp)
 * compile THIS header plus the REAL vendored ML-KEM and the REAL
 * codec header. Device crypto (SHA-256 / HMAC / HKDF) is mbedTLS
 * from the ESP32 Arduino core; host tests serve those calls from an
 * anchored test double (esp32/tests/stub_kr/).
 *
 * Keys are never logged by this code (it has no logging at all) and
 * never leave a device in clear: Mechanism A transmits only ML-KEM
 * public key / ciphertext (the shared secret is never transmitted);
 * Mechanism B transmits only CCM ciphertext.
 */

#ifndef SHEPHERD_LORA_KEYREFRESH_H
#define SHEPHERD_LORA_KEYREFRESH_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "mbedtls/md.h"   // SHA-256 one-shot + HMAC (ESP32 core mbedTLS)
#include <lora_psk_codec.h> // shepherd_psk::wrap/unwrap — Mechanism B reuse

extern "C" {
#include "mlkem/kem.h" // PQCLEAN_MLKEM512_CLEAN_* sizes + KEM entry points
}

namespace shepherd_kr {

// ---- sizes (FIPS 203, ML-KEM-512) ----
static const size_t EK_LEN = PQCLEAN_MLKEM512_CLEAN_CRYPTO_PUBLICKEYBYTES;  // 800
static const size_t SK_LEN = PQCLEAN_MLKEM512_CLEAN_CRYPTO_SECRETKEYBYTES;  // 1632
static const size_t CT_LEN = PQCLEAN_MLKEM512_CLEAN_CRYPTO_CIPHERTEXTBYTES; // 768
static const size_t SS_LEN = PQCLEAN_MLKEM512_CLEAN_CRYPTO_BYTES;           // 32
static const size_t KEY_LEN = 16;  // AES-128 PSK, same as codec v2
static const size_t ID_LEN = 8;    // identity field: "SLN-XXXX"/"SLG-XXXX"

// ---- result codes (distinct refusals; counted separately) ----
enum KrResult : uint8_t {
  KR_OK = 0,
  KR_ERR_COUNTER = 1, // target <= committed (rollback / replay)
  KR_ERR_AUTH = 2,    // HMAC or CCM tag verification failed
  KR_ERR_STATE = 3,   // no staged context, wrong state, or expired
  KR_ERR_FORMAT = 4,  // malformed message (length / magic)
  KR_ERR_CRYPTO = 5,  // underlying primitive returned an error
};

enum KrMechanism : uint8_t { KR_MECH_NONE = 0, KR_MECH_KEM = 1, KR_MECH_ROT = 2 };
enum KrState : uint8_t { KR_IDLE = 0, KR_STAGED = 1, KR_CONFIRMED = 2 };

// ---- small helpers ----
inline void putU32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
inline uint32_t getU32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

inline bool sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  return info && mbedtls_md(info, data, len, out) == 0;
}
inline bool hmacSha256(const uint8_t *key, size_t klen, const uint8_t *data,
                       size_t len, uint8_t out[32]) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  return info && mbedtls_md_hmac(info, key, klen, data, len, out) == 0;
}
// Constant-time equality for tag comparisons (tags are 32 B here).
inline bool ctEqual(const uint8_t *a, const uint8_t *b, size_t n) {
  uint8_t d = 0;
  for (size_t i = 0; i < n; i++) d |= (uint8_t)(a[i] ^ b[i]);
  return d == 0;
}

// Key ID by the codec convention: first 2 bytes of SHA-256(key), and
// its 4-hex-char display form ("----" when no key).
inline bool keyId(const uint8_t key[KEY_LEN], uint8_t out[2]) {
  uint8_t digest[32];
  if (!sha256(key, KEY_LEN, digest)) return false;
  out[0] = digest[0]; out[1] = digest[1];
  return true;
}
inline void keyIdHex(const uint8_t key[KEY_LEN], char out[5]) {
  uint8_t id[2];
  if (!keyId(key, id)) { memcpy(out, "----", 5); return; }
  static const char *H = "0123456789ABCDEF";
  out[0] = H[id[0] >> 4]; out[1] = H[id[0] & 15];
  out[2] = H[id[1] >> 4]; out[3] = H[id[1] & 15]; out[4] = 0;
}

// HKDF-SHA256 (RFC 5869 extract + expand) composed from the
// mbedTLS HMAC above. NOTE: ESP32 Arduino core 2.0.17 builds its
// mbedTLS with MBEDTLS_HKDF_C disabled (no mbedtls_hkdf symbol in
// libmbedcrypto), so the library composes HKDF from HMAC — the
// identical code path runs on device and in the host tests, and the
// composition is anchored to RFC 5869 case 1 in both suites.
inline bool hkdfSha256(const uint8_t *salt, size_t saltLen, const uint8_t *ikm,
                       size_t ikmLen, const uint8_t *info, size_t infoLen,
                       uint8_t *okm, size_t okmLen) {
  // F14: prk/t are key material — wiped on EVERY exit path.
  uint8_t prk[32];
  uint8_t t[32];
  memset(prk, 0, sizeof(prk));
  memset(t, 0, sizeof(t));
  if (infoLen > 64) return false;
  if (!hmacSha256(salt, saltLen, ikm, ikmLen, prk)) {
    memset(prk, 0, sizeof(prk));
    return false;
  }
  size_t done = 0;
  uint8_t ctr = 1;
  bool ok = true;
  while (done < okmLen) {
    // T(i) = HMAC(prk, T(i-1) || info || i). HMAC here is one-shot,
    // so assemble the (small) input in a scratch buffer.
    uint8_t msg[32 + 64 + 1];
    size_t m = 0;
    if (ctr > 1) { memcpy(msg, t, 32); m = 32; }
    memcpy(msg + m, info, infoLen); m += infoLen;
    msg[m++] = ctr;
    if (!hmacSha256(prk, 32, msg, m, t)) { ok = false; break; }
    size_t take = (okmLen - done < 32) ? (okmLen - done) : 32;
    memcpy(okm + done, t, take);
    done += take;
    ctr++;
  }
  memset(prk, 0, sizeof(prk));
  memset(t, 0, sizeof(t));
  return ok;
}

// New-key derivation (Mechanism A), normative per spec §5:
//   salt = SHA-256(transcript)
//   info = "shepherd-kr-v1" || SHA-256(current PSK) || key_counter BE
//   newkey = HKDF-SHA256(ikm = ML-KEM shared secret, salt, info)[0..16)
inline bool deriveKey(const uint8_t ss[SS_LEN], const uint8_t transcriptHash[32],
                      const uint8_t curKey[KEY_LEN], uint32_t counter,
                      uint8_t outKey[KEY_LEN]) {
  uint8_t pskHash[32];
  if (!sha256(curKey, KEY_LEN, pskHash)) return false;
  uint8_t info[14 + 32 + 4];
  memcpy(info, "shepherd-kr-v1", 14);
  memcpy(info + 14, pskHash, 32);
  putU32(info + 46, counter);
  bool ok = hkdfSha256(transcriptHash, 32, ss, SS_LEN, info, sizeof(info),
                       outKey, KEY_LEN);
  memset(pskHash, 0, sizeof(pskHash));  // F14: wipe temporary
  memset(info, 0, sizeof(info));
  return ok;
}

// Mechanism B commit context (F6, normative per spec §6/§7):
//   SHA-256("SHKR1-ROT" || gwId[8] || nodeId[8] || key_counter BE)
// Binding BOTH identities means a commit/abort proof made for one
// node cannot be replayed to another node, even at the same counter
// with the same fleet key.
inline bool rotCommitCtx(const uint8_t gwId[ID_LEN], const uint8_t nodeId[ID_LEN],
                         uint32_t counter, uint8_t out[32]) {
  uint8_t buf[9 + 8 + 8 + 4];
  memcpy(buf, "SHKR1-ROT", 9);
  memcpy(buf + 9, gwId, ID_LEN);
  memcpy(buf + 17, nodeId, ID_LEN);
  putU32(buf + 25, counter);
  return sha256(buf, sizeof(buf), out);
}

// Transcript (Mechanism A), normative per spec §4:
//   "SHKR1" || gwId[8] || nodeId[8] || key_counter u32 BE || ek || ct
static const size_t TRANSCRIPT_LEN = 5 + 8 + 8 + 4 + EK_LEN + CT_LEN; // 1593
inline void buildTranscript(const uint8_t gwId[ID_LEN], const uint8_t nodeId[ID_LEN],
                            uint32_t counter, const uint8_t *ek, const uint8_t *ct,
                            uint8_t *out /*[TRANSCRIPT_LEN]*/) {
  memcpy(out, "SHKR1", 5);
  memcpy(out + 5, gwId, ID_LEN);
  memcpy(out + 13, nodeId, ID_LEN);
  putU32(out + 21, counter);
  memcpy(out + 25, ek, EK_LEN);
  memcpy(out + 25 + EK_LEN, ct, CT_LEN);
}

// confirm proof: HMAC(new key, "SHKR1-CONFIRM" || commitCtx)
// commit  proof: HMAC(new key, "SHKR1-COMMIT"  || commitCtx)
// abort   proof: HMAC(new key, "SHKR1-ABORT"   || commitCtx)  (F5)
// commitCtx is the transcript hash (Mechanism A) or
// rotCommitCtx(gwId, nodeId, counter) (Mechanism B, F6).
inline bool makeProof(const uint8_t newKey[KEY_LEN], const char *label,
                      const uint8_t commitCtx[32], uint8_t out[32]) {
  uint8_t buf[13 + 32];
  size_t ll = strlen(label);
  memcpy(buf, label, ll);
  memcpy(buf + ll, commitCtx, 32);
  return hmacSha256(newKey, KEY_LEN, buf, ll + 32, out);
}

// ============================ NODE SIDE ============================
// RAM-only staged context. stagedKey is NEVER used for TX/RX and
// NEVER persisted; only commitKeyOut() hands it to the sketch, which
// persists it as the new committed key and then clears the context.
struct NodeCtx {
  KrState state = KR_IDLE;
  KrMechanism mech = KR_MECH_NONE;
  uint32_t targetCounter = 0;
  uint8_t peerId[ID_LEN] = {0};
  uint8_t selfId[ID_LEN] = {0};
  uint8_t sk[SK_LEN] = {0};   // ephemeral ML-KEM secret (Mechanism A)
  uint8_t ek[EK_LEN] = {0};   // ephemeral ML-KEM public (Mechanism A)
  uint8_t stagedKey[KEY_LEN] = {0};
  uint8_t commitCtx[32] = {0};
  uint32_t stagedAtMs = 0;
  // counters (RAM; surfaced on the status page)
  uint32_t refuseAuth = 0, refuseCounter = 0, refuseState = 0, failures = 0;
  uint32_t okKem = 0, okRot = 0;
};

inline void nodeAbort(NodeCtx &c) {
  // Scrub ephemeral secret material on any abort/timeout (F14).
  memset(c.sk, 0, sizeof(c.sk));
  memset(c.ek, 0, sizeof(c.ek));
  memset(c.stagedKey, 0, sizeof(c.stagedKey));
  memset(c.commitCtx, 0, sizeof(c.commitCtx));
  c.state = KR_IDLE; c.mech = KR_MECH_NONE; c.targetCounter = 0;
}
inline bool nodeExpired(const NodeCtx &c, uint32_t nowMs, uint32_t timeoutMs) {
  return c.state != KR_IDLE && (uint32_t)(nowMs - c.stagedAtMs) > timeoutMs;
}

// Mechanism A step 1: validate counter, generate the ephemeral
// keypair, remember the peer identity. ekOut receives the public key
// to send to the gateway.
inline KrResult nodeBeginKem(NodeCtx &c, uint32_t committedCtr,
                             const uint8_t selfId[ID_LEN], const uint8_t peerId[ID_LEN],
                             uint32_t counter, uint32_t nowMs, uint8_t *ekOut) {
  if (c.state != KR_IDLE) { c.refuseState++; return KR_ERR_STATE; }
  // F2 counter rule: accept iff target > committed (u32 wrap: at
  // committed == 0xFFFFFFFF every target is <= committed, so all
  // staging refuses — wrap is unreachable in practice and, if ever
  // reached, recovery is manual re-provisioning; spec §8).
  if (counter <= committedCtr) { c.refuseCounter++; return KR_ERR_COUNTER; }
  // NOTE (F14): PQClean's kem entry points always return 0 upstream
  // (see mlkem/kem.c — every path returns 0); the != 0 checks on KEM
  // calls in this header are belt-and-braces against a corrupted or
  // substituted build, not expected failure handling.
  if (PQCLEAN_MLKEM512_CLEAN_crypto_kem_keypair(c.ek, c.sk) != 0) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  memcpy(ekOut, c.ek, EK_LEN);
  memcpy(c.selfId, selfId, ID_LEN);
  memcpy(c.peerId, peerId, ID_LEN);
  c.targetCounter = counter; c.stagedAtMs = nowMs;
  c.mech = KR_MECH_KEM; c.state = KR_STAGED;
  return KR_OK;
}

// Mechanism A step 2: verify the gateway's transcript authentication
// (HMAC under the CURRENT PSK), decapsulate, derive + stage the
// candidate key, and produce the confirm proof for the gateway.
inline KrResult nodeAcceptEncap(NodeCtx &c, const uint8_t curKey[KEY_LEN],
                                const uint8_t *ct, const uint8_t auth[32],
                                uint8_t confirmOut[32]) {
  if (c.state != KR_STAGED || c.mech != KR_MECH_KEM) {
    c.refuseState++; return KR_ERR_STATE;
  }
  uint8_t transcript[TRANSCRIPT_LEN];
  buildTranscript(c.peerId, c.selfId, c.targetCounter, c.ek, ct, transcript);
  uint8_t expect[32];
  if (!hmacSha256(curKey, KEY_LEN, transcript, TRANSCRIPT_LEN, expect)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  bool authOk = ctEqual(expect, auth, 32);
  memset(expect, 0, sizeof(expect));  // F14: wipe HMAC temporary
  if (!authOk) {
    c.refuseAuth++; nodeAbort(c); return KR_ERR_AUTH;
  }
  uint8_t ss[SS_LEN];
  if (PQCLEAN_MLKEM512_CLEAN_crypto_kem_dec(ss, ct, c.sk) != 0) {
    memset(ss, 0, sizeof(ss));
    c.failures++; nodeAbort(c); return KR_ERR_CRYPTO;
  }
  memset(c.sk, 0, sizeof(c.sk)); // ephemeral secret no longer needed
  uint8_t th[32];
  if (!sha256(transcript, TRANSCRIPT_LEN, th)) {
    memset(ss, 0, sizeof(ss));
    c.failures++; nodeAbort(c); return KR_ERR_CRYPTO;
  }
  memcpy(c.commitCtx, th, 32);
  bool derived = deriveKey(ss, th, curKey, c.targetCounter, c.stagedKey);
  memset(ss, 0, sizeof(ss));  // F14: wipe ss on success AND failure
  memset(th, 0, sizeof(th));
  if (!derived) {
    c.failures++; nodeAbort(c); return KR_ERR_CRYPTO;
  }
  if (!makeProof(c.stagedKey, "SHKR1-CONFIRM", c.commitCtx, confirmOut)) {
    c.failures++; nodeAbort(c); return KR_ERR_CRYPTO;
  }
  c.state = KR_CONFIRMED;
  return KR_OK;
}

// Mechanism B: unwrap a rotation payload with the EXISTING codec wrap
// under the current PSK and stage the carried key. Wire layout of the
// 21-byte CCM plaintext (codec payload bytes), normative per spec §6:
//   [0] = 0x4B ('K' rotation magic)  [1..4] = key_counter u32 BE
//   [5..20] = new PSK (16 bytes)
inline KrResult nodeStageRotation(NodeCtx &c, const uint8_t curKey[KEY_LEN],
                                  uint32_t committedCtr,
                                  const uint8_t selfId[ID_LEN],
                                  const uint8_t peerId[ID_LEN],
                                  const uint8_t *wire /*[WIRE_LEN]*/,
                                  uint32_t nowMs) {
  if (c.state != KR_IDLE) { c.refuseState++; return KR_ERR_STATE; }
  uint8_t plain[shepherd_psk::PAYLOAD_LEN];
  if (!shepherd_psk::unwrap(curKey, wire, plain)) {
    c.refuseAuth++; return KR_ERR_AUTH; // wrong key / tampered — drop
  }
  if (plain[0] != 0x4B) {
    memset(plain, 0, sizeof(plain));
    c.failures++; return KR_ERR_FORMAT;
  }
  uint32_t counter = getU32(plain + 1);
  if (counter <= committedCtr) {  // F2 counter rule (see nodeBeginKem)
    memset(plain, 0, sizeof(plain));
    c.refuseCounter++; return KR_ERR_COUNTER;
  }
  memcpy(c.stagedKey, plain + 5, KEY_LEN);
  memset(plain, 0, sizeof(plain));  // F14: plaintext carried the new key
  memcpy(c.selfId, selfId, ID_LEN);
  memcpy(c.peerId, peerId, ID_LEN);
  c.targetCounter = counter; c.stagedAtMs = nowMs;
  // commitCtx binds BOTH identities (F6): peerId is the gateway,
  // selfId is this node.
  if (!rotCommitCtx(peerId, selfId, counter, c.commitCtx)) {
    c.failures++; nodeAbort(c); return KR_ERR_CRYPTO;
  }
  c.mech = KR_MECH_ROT; c.state = KR_CONFIRMED; // wrap tag IS the stage authentication
  return KR_OK;
}

// Shared commit: verify the gateway's commit proof (HMAC under the
// STAGED key — only a peer that derived/received the same candidate
// can produce it), then hand the candidate to the caller. The caller
// MUST persist (key, targetCounter) as committed and only then treat
// the rotation as done; this function clears the staged context.
inline KrResult nodeCommit(NodeCtx &c, const uint8_t commitAuth[32],
                           uint8_t newKeyOut[KEY_LEN], uint32_t *counterOut) {
  if (c.state != KR_CONFIRMED) { c.refuseState++; return KR_ERR_STATE; }
  uint8_t expect[32];
  if (!makeProof(c.stagedKey, "SHKR1-COMMIT", c.commitCtx, expect)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  bool ok = ctEqual(expect, commitAuth, 32);
  memset(expect, 0, sizeof(expect));
  if (!ok) {
    c.refuseAuth++; return KR_ERR_AUTH; // staged context kept: commit may be retried until timeout
  }
  memcpy(newKeyOut, c.stagedKey, KEY_LEN);
  *counterOut = c.targetCounter;
  if (c.mech == KR_MECH_KEM) c.okKem++; else if (c.mech == KR_MECH_ROT) c.okRot++;
  nodeAbort(c); // clears staged copies; newKeyOut is the caller's now
  return KR_OK;
}

// Authenticated abort (F5, spec §7/§12). The gateway must prove
// possession of the staged candidate — the same style as the commit
// proof — before the node discards a CONFIRMED context:
//   abort = HMAC-SHA256(staged key, "SHKR1-ABORT" || commitCtx)
// A STAGED Mechanism A context has no candidate yet (no commitCtx);
// its abort proof is keyed by the CURRENT PSK over a stage context:
//   abortCtx = SHA-256("SHKR1-ABORT-CTX" || targetCounter BE)
//   abort    = HMAC-SHA256(current PSK, "SHKR1-ABORT" || abortCtx)
// With NO staged context the call is a no-op success (auth ignored):
// there is nothing to protect. A bad proof is refused and counted
// and the staged context SURVIVES (same rule as a bad commit proof).
inline bool abortStageCtx(uint32_t counter, uint8_t out[32]) {
  uint8_t buf[15 + 4];
  memcpy(buf, "SHKR1-ABORT-CTX", 15);
  putU32(buf + 15, counter);
  return sha256(buf, sizeof(buf), out);
}
inline KrResult nodeVerifyAbort(NodeCtx &c, const uint8_t curKey[KEY_LEN],
                                const uint8_t *auth, size_t authLen) {
  if (c.state == KR_IDLE) return KR_OK;  // no-op success
  if (authLen != 32 || auth == nullptr) {
    c.refuseAuth++; return KR_ERR_AUTH;  // context kept
  }
  uint8_t expect[32];
  bool made;
  if (c.state == KR_CONFIRMED) {
    made = makeProof(c.stagedKey, "SHKR1-ABORT", c.commitCtx, expect);
  } else {  // KR_STAGED (Mechanism A, pre-encap)
    uint8_t actx[32];
    if (!abortStageCtx(c.targetCounter, actx)) {
      c.failures++; return KR_ERR_CRYPTO;
    }
    made = makeProof(curKey, "SHKR1-ABORT", actx, expect);
    memset(actx, 0, sizeof(actx));
  }
  if (!made) { c.failures++; return KR_ERR_CRYPTO; }
  bool ok = ctEqual(expect, auth, 32);
  memset(expect, 0, sizeof(expect));
  if (!ok) { c.refuseAuth++; return KR_ERR_AUTH; }  // context kept
  nodeAbort(c);
  return KR_OK;
}

// =========================== GATEWAY SIDE ===========================
struct GwCtx {
  KrState state = KR_IDLE;
  KrMechanism mech = KR_MECH_NONE;
  uint32_t targetCounter = 0;
  uint8_t selfId[ID_LEN] = {0};
  uint8_t peerId[ID_LEN] = {0};
  uint8_t stagedKey[KEY_LEN] = {0};
  uint8_t commitCtx[32] = {0};
  uint32_t stagedAtMs = 0;
  uint32_t refuseAuth = 0, refuseCounter = 0, refuseState = 0, failures = 0;
  uint32_t okKem = 0, okRot = 0, dualKeyFrames = 0;
  // F7: /kr/rotate reply mismatches (staged key-ID / counter).
  uint32_t rotateMismatch = 0;
  // F4: a /kr/commit POST failed after possible delivery; the
  // session stays CONFIRMED with the window open, awaiting the
  // frame-confirmation promotion trigger.
  bool awaitingFrame = false;
  uint32_t commitAckLost = 0;
  // F2: gateway round state (Mechanism B fleet rounds, spec §11).
  // roundOpen implies state == KR_CONFIRMED with stagedKey == the
  // round key; per-node contexts are computed on demand (F6).
  bool roundOpen = false;
  uint32_t roundStaged = 0, roundCommitted = 0;
};

inline void gwAbort(GwCtx &c) {
  // F14: scrub the candidate and its context on any abort/timeout.
  memset(c.stagedKey, 0, sizeof(c.stagedKey));
  memset(c.commitCtx, 0, sizeof(c.commitCtx));
  c.state = KR_IDLE; c.mech = KR_MECH_NONE; c.targetCounter = 0;
  c.awaitingFrame = false;
  c.roundOpen = false; c.roundStaged = 0; c.roundCommitted = 0;
}
inline bool gwExpired(const GwCtx &c, uint32_t nowMs, uint32_t timeoutMs) {
  return c.state != KR_IDLE && (uint32_t)(nowMs - c.stagedAtMs) > timeoutMs;
}

// Mechanism A step 2 (gateway): encapsulate to the node's ek, build
// the transcript, authenticate it under the current PSK, derive the
// candidate. Outputs ct + auth to send; stages the candidate locally.
inline KrResult gwEncap(GwCtx &c, const uint8_t curKey[KEY_LEN],
                        uint32_t committedCtr, const uint8_t selfId[ID_LEN],
                        const uint8_t peerId[ID_LEN], uint32_t counter,
                        const uint8_t *ek, uint32_t nowMs,
                        uint8_t *ctOut, uint8_t authOut[32]) {
  if (c.state != KR_IDLE) { c.refuseState++; return KR_ERR_STATE; }
  if (counter <= committedCtr) { c.refuseCounter++; return KR_ERR_COUNTER; }  // F2 rule
  uint8_t ss[SS_LEN];
  if (PQCLEAN_MLKEM512_CLEAN_crypto_kem_enc(ctOut, ss, ek) != 0) {
    memset(ss, 0, sizeof(ss));
    c.failures++; return KR_ERR_CRYPTO;
  }
  uint8_t transcript[TRANSCRIPT_LEN];
  buildTranscript(selfId, peerId, counter, ek, ctOut, transcript);
  if (!hmacSha256(curKey, KEY_LEN, transcript, TRANSCRIPT_LEN, authOut)) {
    memset(ss, 0, sizeof(ss));
    c.failures++; return KR_ERR_CRYPTO;
  }
  uint8_t th[32];
  if (!sha256(transcript, TRANSCRIPT_LEN, th)) {
    memset(ss, 0, sizeof(ss));
    c.failures++; return KR_ERR_CRYPTO;
  }
  memcpy(c.commitCtx, th, 32);
  bool derived = deriveKey(ss, th, curKey, counter, c.stagedKey);
  memset(ss, 0, sizeof(ss));  // F14: wipe ss on success AND failure
  memset(th, 0, sizeof(th));
  if (!derived) {
    c.failures++; gwAbort(c); return KR_ERR_CRYPTO;
  }
  memcpy(c.selfId, selfId, ID_LEN);
  memcpy(c.peerId, peerId, ID_LEN);
  c.targetCounter = counter; c.stagedAtMs = nowMs;
  c.mech = KR_MECH_KEM; c.state = KR_STAGED;
  return KR_OK;
}

// Verify the node's confirm proof; on success the dual-key window
// OPENS (state CONFIRMED: gateway unwrap tries current, then staged).
inline KrResult gwVerifyConfirm(GwCtx &c, const uint8_t confirm[32]) {
  if (c.state != KR_STAGED) { c.refuseState++; return KR_ERR_STATE; }
  uint8_t expect[32];
  if (!makeProof(c.stagedKey, "SHKR1-CONFIRM", c.commitCtx, expect)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  bool ok = ctEqual(expect, confirm, 32);
  memset(expect, 0, sizeof(expect));
  if (!ok) { c.refuseAuth++; gwAbort(c); return KR_ERR_AUTH; }
  c.state = KR_CONFIRMED;
  return KR_OK;
}

// Mechanism B (gateway): wrap the operator/CSPRNG-chosen new key for
// delivery. nonceParts are two u32 halves of a fresh random u64 —
// (key, nonce) uniqueness is what CCM requires; the counters carry
// no meaning on this path. Stages the candidate locally in STAGED —
// the dual-key window does NOT open here (F7): it opens only in
// gwConfirmRotation(), after the node's /kr/rotate reply (staged
// key ID + counter) has been verified against what was pushed.
inline KrResult gwMakeRotation(GwCtx &c, const uint8_t curKey[KEY_LEN],
                               uint32_t committedCtr, const uint8_t selfId[ID_LEN],
                               const uint8_t peerId[ID_LEN],
                               const uint8_t newKey[KEY_LEN], uint32_t counter,
                               uint32_t nonceA, uint32_t nonceB, uint32_t nowMs,
                               uint8_t *wireOut /*[WIRE_LEN]*/) {
  if (c.state != KR_IDLE) { c.refuseState++; return KR_ERR_STATE; }
  if (counter <= committedCtr) { c.refuseCounter++; return KR_ERR_COUNTER; }  // F2 rule
  uint8_t plain22[shepherd_psk::V1_LEN];
  memset(plain22, 0, sizeof(plain22));
  plain22[0] = 0x4B; // not encrypted by wrap(); mirrors payload[0] for readers
  plain22[1] = 0x4B;
  putU32(plain22 + 2, counter);
  memcpy(plain22 + 6, newKey, KEY_LEN);
  bool wrapped = shepherd_psk::wrap(curKey, nonceA, nonceB, plain22, wireOut);
  memset(plain22, 0, sizeof(plain22));  // F14: plaintext carried the new key
  if (!wrapped) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  memcpy(c.stagedKey, newKey, KEY_LEN);
  memcpy(c.selfId, selfId, ID_LEN);
  memcpy(c.peerId, peerId, ID_LEN);
  c.targetCounter = counter; c.stagedAtMs = nowMs;
  if (!rotCommitCtx(selfId, peerId, counter, c.commitCtx)) {
    c.failures++; gwAbort(c); return KR_ERR_CRYPTO;
  }
  c.mech = KR_MECH_ROT; c.state = KR_STAGED;  // F7: window NOT yet open
  return KR_OK;
}

// F7: verify the node's /kr/rotate reply (staged key ID, 2 B + staged
// counter, u32) against the candidate this gateway pushed. Only on a
// match does the context become CONFIRMED — the moment the dual-key
// window opens. A mismatch fails the session AT the rotate step:
// counted in BOTH failures and the dedicated rotateMismatch counter
// (surfaced on the gateway status page), context aborted.
inline KrResult gwConfirmRotation(GwCtx &c, const uint8_t nodeKeyId[2],
                                  uint32_t nodeCounter) {
  if (c.state != KR_STAGED || c.mech != KR_MECH_ROT) {
    c.refuseState++; return KR_ERR_STATE;
  }
  uint8_t id[2];
  if (!keyId(c.stagedKey, id)) { c.failures++; return KR_ERR_CRYPTO; }
  if (nodeCounter != c.targetCounter || !ctEqual(id, nodeKeyId, 2)) {
    c.failures++; c.rotateMismatch++;
    gwAbort(c);
    return KR_ERR_AUTH;
  }
  c.state = KR_CONFIRMED;
  return KR_OK;
}

// Value-only variant of the F7 reply check, for round sessions
// (where the round context must not change state per node).
inline bool krReplyMatches(const uint8_t stagedKey[KEY_LEN], uint32_t targetCtr,
                           const uint8_t nodeKeyId[2], uint32_t nodeCounter) {
  uint8_t id[2];
  if (!keyId(stagedKey, id)) return false;
  return nodeCounter == targetCtr && ctEqual(id, nodeKeyId, 2);
}

// Produce the commit proof to send to the node.
inline KrResult gwMakeCommitAuth(GwCtx &c, uint8_t out[32]) {
  if (c.state != KR_CONFIRMED) { c.refuseState++; return KR_ERR_STATE; }
  if (!makeProof(c.stagedKey, "SHKR1-COMMIT", c.commitCtx, out)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  return KR_OK;
}

// Produce the abort proof to send to the node (F5; mirror of
// nodeVerifyAbort). IDLE produces no proof (the node's no-context
// abort is a no-op success) and returns KR_ERR_STATE so the caller
// knows to send an empty body instead.
inline KrResult gwMakeAbortAuth(GwCtx &c, const uint8_t curKey[KEY_LEN],
                                uint8_t out[32]) {
  if (c.state == KR_CONFIRMED) {
    if (!makeProof(c.stagedKey, "SHKR1-ABORT", c.commitCtx, out)) {
      c.failures++; return KR_ERR_CRYPTO;
    }
    return KR_OK;
  }
  if (c.state == KR_STAGED && c.mech == KR_MECH_KEM) {
    uint8_t actx[32];
    if (!abortStageCtx(c.targetCounter, actx)) {
      c.failures++; return KR_ERR_CRYPTO;
    }
    bool made = makeProof(curKey, "SHKR1-ABORT", actx, out);
    memset(actx, 0, sizeof(actx));
    if (!made) { c.failures++; return KR_ERR_CRYPTO; }
    return KR_OK;
  }
  if (c.state == KR_STAGED && c.mech == KR_MECH_ROT) {
    // A rotation the gateway made but the node has not confirmed:
    // the node holds no context until it stages, and if it did stage
    // its context is CONFIRMED under the candidate — the CONFIRMED
    // proof above is the one that applies from the node's view, but
    // this side cannot know the node staged. Use the candidate
    // proof: it verifies exactly when the node holds the context
    // that needs protecting, and the node treats a context-free
    // abort as a no-op anyway.
    if (!makeProof(c.stagedKey, "SHKR1-ABORT", c.commitCtx, out)) {
      c.failures++; return KR_ERR_CRYPTO;
    }
    return KR_OK;
  }
  c.refuseState++;
  return KR_ERR_STATE;
}

// F4: the /kr/commit POST failed or timed out AFTER possible
// delivery (the node may have committed and its 200 was lost).
// Do NOT abort: stay CONFIRMED with the dual-key window open,
// marked awaitingFrame — the first staged-key frame still promotes
// (gwPromote). Only operator abort or window expiry tears down.
inline KrResult gwNoteCommitAckLost(GwCtx &c) {
  if (c.state != KR_CONFIRMED) { c.refuseState++; return KR_ERR_STATE; }
  c.awaitingFrame = true;
  c.commitAckLost++;
  return KR_OK;
}

// ==================== GATEWAY ROUND (F2, spec §11) ====================
// A round stages ONE key on many nodes at ONE target counter while
// the gateway's dual-key window stays open; the gateway promotes
// only on the operator's explicit round promote. Auto-promote on a
// staged-key frame is DISABLED by the caller while roundOpen (the
// sketch checks roundOpen before its frame-promotion trigger).
// Abort semantics (chosen, spec §11): a round may be aborted only
// BEFORE any node has committed into it (gwRoundAbortPermitted);
// after the first node commit, only promote or per-node recovery
// remains — aborting then would strand committed nodes.

// Open a round: counter must satisfy the F2 rule (> committed).
// The window opens immediately (CONFIRMED) with the round key.
inline KrResult gwRoundBegin(GwCtx &c, uint32_t committedCtr,
                             const uint8_t selfId[ID_LEN],
                             const uint8_t roundKey[KEY_LEN], uint32_t counter,
                             uint32_t nowMs) {
  if (c.state != KR_IDLE || c.roundOpen) { c.refuseState++; return KR_ERR_STATE; }
  if (counter <= committedCtr) { c.refuseCounter++; return KR_ERR_COUNTER; }
  memcpy(c.stagedKey, roundKey, KEY_LEN);
  memcpy(c.selfId, selfId, ID_LEN);
  c.targetCounter = counter; c.stagedAtMs = nowMs;
  memset(c.commitCtx, 0, sizeof(c.commitCtx));  // per-node ctx is on-demand
  c.mech = KR_MECH_ROT; c.state = KR_CONFIRMED;
  c.roundOpen = true; c.roundStaged = 0; c.roundCommitted = 0;
  c.awaitingFrame = false;
  return KR_OK;
}

// Wrap the round key for one node; also yields that node's F6
// commit context. Round state does not change.
inline KrResult gwRoundMakeRotation(GwCtx &c, const uint8_t curKey[KEY_LEN],
                                    const uint8_t peerId[ID_LEN],
                                    uint32_t nonceA, uint32_t nonceB,
                                    uint8_t *wireOut, uint8_t ctxOut[32]) {
  if (!c.roundOpen || c.state != KR_CONFIRMED) {
    c.refuseState++; return KR_ERR_STATE;
  }
  uint8_t plain22[shepherd_psk::V1_LEN];
  memset(plain22, 0, sizeof(plain22));
  plain22[0] = 0x4B;
  plain22[1] = 0x4B;
  putU32(plain22 + 2, c.targetCounter);
  memcpy(plain22 + 6, c.stagedKey, KEY_LEN);
  bool wrapped = shepherd_psk::wrap(curKey, nonceA, nonceB, plain22, wireOut);
  memset(plain22, 0, sizeof(plain22));  // F14
  if (!wrapped) { c.failures++; return KR_ERR_CRYPTO; }
  if (!rotCommitCtx(c.selfId, peerId, c.targetCounter, ctxOut)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  memcpy(c.peerId, peerId, ID_LEN);
  return KR_OK;
}

// Per-node commit proof inside a round (F6 context for that node).
inline KrResult gwRoundCommitAuth(GwCtx &c, const uint8_t peerId[ID_LEN],
                                  uint8_t out[32]) {
  if (!c.roundOpen || c.state != KR_CONFIRMED) {
    c.refuseState++; return KR_ERR_STATE;
  }
  uint8_t ctx[32];
  if (!rotCommitCtx(c.selfId, peerId, c.targetCounter, ctx)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  bool made = makeProof(c.stagedKey, "SHKR1-COMMIT", ctx, out);
  memset(ctx, 0, sizeof(ctx));
  if (!made) { c.failures++; return KR_ERR_CRYPTO; }
  return KR_OK;
}

// Per-node abort proof inside a round (F5, that node's F6 context).
inline KrResult gwRoundAbortAuth(GwCtx &c, const uint8_t peerId[ID_LEN],
                                 uint8_t out[32]) {
  if (!c.roundOpen) { c.refuseState++; return KR_ERR_STATE; }
  uint8_t ctx[32];
  if (!rotCommitCtx(c.selfId, peerId, c.targetCounter, ctx)) {
    c.failures++; return KR_ERR_CRYPTO;
  }
  bool made = makeProof(c.stagedKey, "SHKR1-ABORT", ctx, out);
  memset(ctx, 0, sizeof(ctx));
  if (!made) { c.failures++; return KR_ERR_CRYPTO; }
  return KR_OK;
}

inline void gwRoundNoteStaged(GwCtx &c) { if (c.roundOpen) c.roundStaged++; }
inline void gwRoundNoteCommitted(GwCtx &c) { if (c.roundOpen) c.roundCommitted++; }
inline bool gwRoundAbortPermitted(const GwCtx &c) {
  return c.roundOpen && c.roundCommitted == 0;
}

// Promote the staged key after the node confirms the commit (explicit
// ACK) or after the first valid v2 frame under the staged key. The
// caller persists (key, targetCounter) as committed, then calls this
// to clear the staged context.
inline KrResult gwPromote(GwCtx &c, uint8_t newKeyOut[KEY_LEN], uint32_t *counterOut) {
  if (c.state != KR_CONFIRMED) { c.refuseState++; return KR_ERR_STATE; }
  memcpy(newKeyOut, c.stagedKey, KEY_LEN);
  *counterOut = c.targetCounter;
  if (c.mech == KR_MECH_KEM) c.okKem++; else if (c.mech == KR_MECH_ROT) c.okRot++;
  gwAbort(c);
  return KR_OK;
}

// Dual-key unwrap for the gateway's LoRa path during the window.
// Order is normative (spec §7): try the COMMITTED key first, then the
// STAGED key (the wire format carries no key-ID field, so acceptance
// is ordered try-both). Outside the window (state != CONFIRMED) only
// the committed key is tried — exactly today's single-key behavior.
// Returns true on success; *usedStaged reports which key matched.
inline bool gwUnwrapDual(GwCtx &c, const uint8_t curKey[KEY_LEN],
                         const uint8_t *wire, uint8_t *plain21, bool *usedStaged) {
  *usedStaged = false;
  if (shepherd_psk::unwrap(curKey, wire, plain21)) return true;
  if (c.state == KR_CONFIRMED &&
      shepherd_psk::unwrap(c.stagedKey, wire, plain21)) {
    *usedStaged = true;
    c.dualKeyFrames++;
    return true;
  }
  return false;
}

} // namespace shepherd_kr

#endif // SHEPHERD_LORA_KEYREFRESH_H
