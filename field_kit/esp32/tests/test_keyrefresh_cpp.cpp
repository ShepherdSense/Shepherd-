/*
 * Host C++ test for the Shepherd LoRa key-refresh library — compiles
 * the REAL shepherd_lora_keyrefresh/src/keyrefresh.h, the REAL
 * vendored PQClean ML-KEM-512 code (src/mlkem/), and the REAL codec
 * header (shepherd_lora_psk/src/lora_psk_codec.h):
 *
 *   * test-double anchors: SHA-256 (FIPS 180-4), HMAC (RFC 4231 #1),
 *     HKDF (RFC 5869 #1) — the doubles are trusted only after these;
 *   * ML-KEM-512 known answers vs the official NIST ACVP vectors
 *     (mlkem_kat_vectors.json): keyGen derand, encap derand, decap;
 *   * Mechanism A handshake: happy path (both sides derive the
 *     identical key + key-ID), wrong-PSK authenticator failure,
 *     tampered public key, tampered ciphertext, tampered counter —
 *     each fails closed with its distinct refusal code;
 *   * Mechanism B rotation: happy path via the real codec wrap,
 *     CCM tamper, replayed payload, rollback (counter <= current),
 *     staged-not-committed revert on timeout;
 *   * dual-key window semantics and committed-state persistence
 *     semantics (staged state never promotes itself across a
 *     modeled reboot; committed state survives it).
 *
 * Build & run:  ./run_kr_cpp_tests.sh       (from this folder)
 * Exit code 0 = all checks passed.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

#include "keyrefresh.h"
#include "mbedtls/md.h"   // stub_kr API, for the anchor checks
#include "mbedtls/hkdf.h"

using namespace shepherd_kr;

static int failures = 0;
static int checks = 0;
#define CHECK(cond, ...)                                       \
  do {                                                         \
    checks++;                                                  \
    if (!(cond)) {                                             \
      failures++;                                              \
      printf("FAIL %s:%d: ", __FILE__, __LINE__);              \
      printf(__VA_ARGS__);                                     \
      printf("\n");                                            \
    }                                                          \
  } while (0)

// ---------- tiny JSON hex extraction (same pattern as codec test) --
static std::string slurp(const char *path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
  std::stringstream ss; ss << in.rdbuf();
  return ss.str();
}
static std::string jsonStr(const std::string &doc, const char *key, size_t from) {
  std::string pat = std::string("\"") + key + "\"";
  size_t k = doc.find(pat, from);
  if (k == std::string::npos) return "";
  size_t q1 = doc.find('"', k + pat.size());
  size_t q2 = (q1 == std::string::npos) ? q1 : doc.find('"', q1 + 1);
  if (q1 == std::string::npos || q2 == std::string::npos) return "";
  return doc.substr(q1 + 1, q2 - q1 - 1);
}
static std::vector<uint8_t> unhex(const std::string &h) {
  std::vector<uint8_t> out;
  auto hv = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  for (size_t i = 0; i + 1 < h.size(); i += 2)
    out.push_back((uint8_t)((hv(h[i]) << 4) | hv(h[i + 1])));
  return out;
}
static bool eq(const uint8_t *a, const std::vector<uint8_t> &b) {
  return memcmp(a, b.data(), b.size()) == 0;
}

// ---------------- anchors for the md/hkdf test double ----------------
static void test_stub_anchors() {
  const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  CHECK(md != nullptr, "stub md_info missing");
  uint8_t out[32];
  // FIPS 180-4: SHA-256("abc")
  CHECK(mbedtls_md(md, (const uint8_t *)"abc", 3, out) == 0 &&
        eq(out, unhex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")),
        "stub SHA-256 anchor failed");
  // RFC 4231 HMAC-SHA-256 case 1: key = 20 x 0x0b, data = "Hi There"
  uint8_t key[20]; memset(key, 0x0b, 20);
  CHECK(mbedtls_md_hmac(md, key, 20, (const uint8_t *)"Hi There", 8, out) == 0 &&
        eq(out, unhex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")),
        "stub HMAC anchor failed");
  // RFC 5869 HKDF-SHA-256 case 1
  std::vector<uint8_t> ikm(22, 0x0b);
  std::vector<uint8_t> salt = unhex("000102030405060708090a0b0c");
  std::vector<uint8_t> info = unhex("f0f1f2f3f4f5f6f7f8f9");
  uint8_t okm[42];
  CHECK(mbedtls_hkdf(md, salt.data(), salt.size(), ikm.data(), ikm.size(),
                     info.data(), info.size(), okm, 42) == 0 &&
        eq(okm, unhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                      "34007208d5b887185865")),
        "stub HKDF anchor failed");
  // the LIBRARY's own HKDF (composed from HMAC; the ESP32 core
  // builds mbedTLS without MBEDTLS_HKDF_C) against the same vector:
  uint8_t okm2[42];
  CHECK(shepherd_kr::hkdfSha256(salt.data(), salt.size(), ikm.data(), ikm.size(),
                                info.data(), info.size(), okm2, 42) &&
        eq(okm2, unhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                       "34007208d5b887185865")),
        "library HKDF anchor failed");
}

// ---------------- ML-KEM-512 ACVP known answers ----------------
static void test_mlkem_kats(const std::string &doc) {
  // --- keyGen: coins = d || z -> (ek, dk) ---
  size_t sec = doc.find("\"keygen\"");
  CHECK(sec != std::string::npos, "kat: keygen section missing");
  size_t pos = sec;
  int n = 0;
  while (true) {
    size_t k = doc.find("\"d\":", pos);
    if (k == std::string::npos || (sec && k > doc.find("\"encap\""))) break;
    std::vector<uint8_t> d = unhex(jsonStr(doc, "d", k));
    std::vector<uint8_t> z = unhex(jsonStr(doc, "z", k));
    std::vector<uint8_t> ek = unhex(jsonStr(doc, "ek", k));
    std::vector<uint8_t> dk = unhex(jsonStr(doc, "dk", k));
    CHECK(d.size() == 32 && z.size() == 32 && ek.size() == EK_LEN && dk.size() == SK_LEN,
          "kat keygen sizes (d=%zu z=%zu ek=%zu dk=%zu)", d.size(), z.size(), ek.size(), dk.size());
    uint8_t coins[64];
    memcpy(coins, d.data(), 32); memcpy(coins + 32, z.data(), 32);
    uint8_t pk[EK_LEN], sk[SK_LEN];
    int rc = PQCLEAN_MLKEM512_CLEAN_crypto_kem_keypair_derand(pk, sk, coins);
    CHECK(rc == 0 && eq(pk, ek), "kat keygen ek mismatch (vector %d)", n);
    CHECK(rc == 0 && eq(sk, dk), "kat keygen dk mismatch (vector %d)", n);
    pos = k + 1; n++;
  }
  CHECK(n == 2, "kat: expected 2 keygen vectors, ran %d", n);

  // --- encap: coins = m, ek -> (ct, ss); decap(dk, ct) -> ss ---
  sec = doc.find("\"encap\"");
  size_t decsec = doc.find("\"decap\"");
  pos = sec; n = 0;
  while (true) {
    size_t k = doc.find("\"ek\":", pos);
    if (k == std::string::npos || k > decsec) break;
    std::vector<uint8_t> ek = unhex(jsonStr(doc, "ek", k));
    std::vector<uint8_t> dk = unhex(jsonStr(doc, "dk", k));
    std::vector<uint8_t> m = unhex(jsonStr(doc, "m", k));
    std::vector<uint8_t> c = unhex(jsonStr(doc, "c", k));
    std::vector<uint8_t> kk = unhex(jsonStr(doc, "k", k));
    CHECK(m.size() == 32 && c.size() == CT_LEN && kk.size() == SS_LEN,
          "kat encap sizes (m=%zu c=%zu k=%zu)", m.size(), c.size(), kk.size());
    uint8_t ct[CT_LEN], ss[SS_LEN];
    int rc = PQCLEAN_MLKEM512_CLEAN_crypto_kem_enc_derand(ct, ss, ek.data(), m.data());
    CHECK(rc == 0 && eq(ct, c), "kat encap ct mismatch (vector %d)", n);
    CHECK(rc == 0 && eq(ss, kk), "kat encap ss mismatch (vector %d)", n);
    uint8_t ss2[SS_LEN];
    rc = PQCLEAN_MLKEM512_CLEAN_crypto_kem_dec(ss2, c.data(), dk.data());
    CHECK(rc == 0 && eq(ss2, kk), "kat decap ss mismatch (vector %d)", n);
    pos = k + 1; n++;
  }
  CHECK(n == 2, "kat: expected 2 encap vectors, ran %d", n);

  // --- decap group (independent ciphertexts) ---
  pos = decsec; n = 0;
  while (true) {
    size_t k = doc.find("\"dk\":", pos);
    if (k == std::string::npos) break;
    std::vector<uint8_t> dk = unhex(jsonStr(doc, "dk", k));
    std::vector<uint8_t> c = unhex(jsonStr(doc, "c", k));
    std::vector<uint8_t> kk = unhex(jsonStr(doc, "k", k));
    if (dk.size() != SK_LEN || c.size() != CT_LEN) break;
    uint8_t ss[SS_LEN];
    int rc = PQCLEAN_MLKEM512_CLEAN_crypto_kem_dec(ss, c.data(), dk.data());
    CHECK(rc == 0 && eq(ss, kk), "kat decap-group ss mismatch (vector %d)", n);
    pos = k + 1; n++;
  }
  CHECK(n == 2, "kat: expected 2 decap vectors, ran %d", n);
}

// ---------------- shared fixtures ----------------
static const uint8_t CUR[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
static const uint8_t WRONG[16] = {0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
                                  0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00};
static const uint8_t GWID[8] = {'S', 'L', 'G', '-', '0', '0', 'A', '1'};
static const uint8_t NDID[8] = {'S', 'L', 'N', '-', '0', '0', 'B', '2'};

// Full happy-path Mechanism A run; returns the committed new key.
static void kemHappyPath(uint8_t newKeyOut[16], uint32_t *ctrOut) {
  NodeCtx node; GwCtx gw;
  uint8_t ek[EK_LEN];
  CHECK(nodeBeginKem(node, 5, NDID, GWID, 6, 1000, ek) == KR_OK, "kem: node begin");
  uint8_t ct[CT_LEN], auth[32];
  CHECK(gwEncap(gw, CUR, 5, GWID, NDID, 6, ek, 1000, ct, auth) == KR_OK, "kem: gw encap");
  uint8_t confirm[32];
  CHECK(nodeAcceptEncap(node, CUR, ct, auth, confirm) == KR_OK, "kem: node accept");
  CHECK(gwVerifyConfirm(gw, confirm) == KR_OK, "kem: gw confirm");
  CHECK(memcmp(node.stagedKey, gw.stagedKey, 16) == 0, "kem: sides derived different keys");
  uint8_t cauth[32];
  CHECK(gwMakeCommitAuth(gw, cauth) == KR_OK, "kem: gw commit auth");
  uint32_t co = 0;
  CHECK(nodeCommit(node, cauth, newKeyOut, &co) == KR_OK && co == 6, "kem: node commit");
  uint8_t gk[16]; uint32_t gc = 0;
  CHECK(gwPromote(gw, gk, &gc) == KR_OK && gc == 6 && memcmp(gk, newKeyOut, 16) == 0,
        "kem: gw promote");
  *ctrOut = co;
}

static void test_handshake() {
  uint8_t nk[16]; uint32_t ctr = 0;
  kemHappyPath(nk, &ctr);
  CHECK(memcmp(nk, CUR, 16) != 0, "kem: new key equals old key");
  char idHex[5], idHex2[5];
  keyIdHex(nk, idHex);
  NodeCtx nx; GwCtx gx; // re-derive id from a second run is random; just sanity:
  CHECK(strlen(idHex) == 4 && strcmp(idHex, "----") != 0, "kem: key id hex '%s'", idHex);
  (void)nx; (void)gx; (void)idHex2;

  // wrong-PSK authenticator: gateway authenticates under WRONG key
  {
    NodeCtx node; GwCtx gw;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 6, 0, ek) == KR_OK, "wrongpsk: begin");
    uint8_t ct[CT_LEN], auth[32];
    CHECK(gwEncap(gw, WRONG, 5, GWID, NDID, 6, ek, 0, ct, auth) == KR_OK, "wrongpsk: gw encap");
    uint8_t confirm[32];
    CHECK(nodeAcceptEncap(node, CUR, ct, auth, confirm) == KR_ERR_AUTH,
          "wrongpsk: node must refuse with KR_ERR_AUTH");
    CHECK(node.refuseAuth == 1 && node.state == KR_IDLE, "wrongpsk: counted + aborted");
  }
  // tampered public key: gateway encapsulates to a flipped ek; the
  // transcript it authenticates no longer matches the node's own ek.
  // F15(a): this test DETERMINISTICALLY exercises the node's HMAC
  // refusal — there is no vacuous escape. PQClean's kem entry points
  // always return 0 upstream (mlkem/kem.c), so encapsulation to the
  // tampered ek MUST succeed and produce a (ct, auth) pair whose
  // auth was computed over the tampered transcript; the node, which
  // rebuilds the transcript from its OWN stored ek, must then refuse
  // with KR_ERR_AUTH. (Mutation-checked: removing the node's HMAC
  // comparison makes this test fail — see the build record.)
  {
    NodeCtx node; GwCtx gw;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 6, 0, ek) == KR_OK, "tampk: begin");
    uint8_t badEk[EK_LEN]; memcpy(badEk, ek, EK_LEN); badEk[100] ^= 0x01;
    uint8_t ct[CT_LEN], auth[32];
    KrResult r = gwEncap(gw, CUR, 5, GWID, NDID, 6, badEk, 0, ct, auth);
    CHECK(r == KR_OK,
          "tampk: gw encap to tampered ek must succeed (kem always returns 0), got %d", (int)r);
    uint8_t confirm[32];
    CHECK(nodeAcceptEncap(node, CUR, ct, auth, confirm) == KR_ERR_AUTH,
          "tampk: node must refuse with KR_ERR_AUTH");
    CHECK(node.refuseAuth == 1 && node.state == KR_IDLE,
          "tampk: refusal counted + context aborted");
  }
  // tampered ciphertext: flip a ct byte after honest encapsulation
  {
    NodeCtx node; GwCtx gw;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 6, 0, ek) == KR_OK, "tamct: begin");
    uint8_t ct[CT_LEN], auth[32];
    CHECK(gwEncap(gw, CUR, 5, GWID, NDID, 6, ek, 0, ct, auth) == KR_OK, "tamct: encap");
    ct[200] ^= 0x40;
    uint8_t confirm[32];
    CHECK(nodeAcceptEncap(node, CUR, ct, auth, confirm) == KR_ERR_AUTH,
          "tamct: node must refuse with KR_ERR_AUTH");
  }
  // tampered counter: node staged counter 6, gateway authenticates 7
  {
    NodeCtx node; GwCtx gw;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 6, 0, ek) == KR_OK, "tamctr: begin");
    uint8_t ct[CT_LEN], auth[32];
    CHECK(gwEncap(gw, CUR, 6, GWID, NDID, 7, ek, 0, ct, auth) == KR_OK, "tamctr: gw encap(7)");
    uint8_t confirm[32];
    CHECK(nodeAcceptEncap(node, CUR, ct, auth, confirm) == KR_ERR_AUTH,
          "tamctr: transcript mismatch must refuse KR_ERR_AUTH");
  }
  // rollback / replay at begin: counter <= committed refused distinctly
  {
    NodeCtx node;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 5, 0, ek) == KR_ERR_COUNTER,
          "rollback: counter == committed must refuse KR_ERR_COUNTER");
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 3, 0, ek) == KR_ERR_COUNTER,
          "rollback: counter < committed must refuse KR_ERR_COUNTER");
    CHECK(node.refuseCounter == 2, "rollback: refusal count %u", node.refuseCounter);
    GwCtx gw;
    uint8_t dummyCt[CT_LEN] = {0}; uint8_t dummyAuth[32] = {0};
    CHECK(gwEncap(gw, CUR, 5, GWID, NDID, 5, ek, 0, dummyCt, dummyAuth) == KR_ERR_COUNTER,
          "rollback: gw encap counter==committed refused");
  }
}

// F7 helper: simulate the node's /kr/rotate reply (staged key ID +
// counter read back from the NODE context) and verify it gateway-side.
static void rotConfirmFromNode(GwCtx &gw, const NodeCtx &node) {
  uint8_t id[2];
  CHECK(shepherd_kr::keyId(node.stagedKey, id), "rotconfirm: keyId");
  CHECK(gwConfirmRotation(gw, id, node.targetCounter) == KR_OK,
        "rotconfirm: gateway must accept the honest reply");
  CHECK(gw.state == KR_CONFIRMED, "rotconfirm: window open after confirm");
}

// ---------------- Mechanism B: rotation ----------------
static void test_rotation() {
  static const uint8_t NEWK[16] = {0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
                                   0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f};
  // happy path: make -> stage -> commit auth -> node commit
  {
    GwCtx gw; NodeCtx node;
    uint8_t wire[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK, 6, 0xAABBCCDD, 0x11223344, 500, wire) == KR_OK,
          "rot: gw make");
    CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 500) == KR_OK, "rot: node stage");
    CHECK(memcmp(node.stagedKey, NEWK, 16) == 0, "rot: staged key mismatch");
    rotConfirmFromNode(gw, node);  // F7: window opens only now
    uint8_t cauth[32];
    CHECK(gwMakeCommitAuth(gw, cauth) == KR_OK, "rot: commit auth");
    uint8_t out[16]; uint32_t co = 0;
    CHECK(nodeCommit(node, cauth, out, &co) == KR_OK && co == 6 && memcmp(out, NEWK, 16) == 0,
          "rot: node commit");
    uint8_t gk[16]; uint32_t gc = 0;
    CHECK(gwPromote(gw, gk, &gc) == KR_OK && memcmp(gk, NEWK, 16) == 0, "rot: gw promote");
    // replay of the SAME payload after commit (committed ctr now 6):
    NodeCtx node2;
    CHECK(nodeStageRotation(node2, NEWK, 6, NDID, GWID, wire, 600) == KR_ERR_AUTH,
          "rot replay: payload under old key must fail unwrap after commit");
    // rollback: a fresh payload carrying counter <= committed (made
    // under the NEW current key by a confused/malicious gateway):
    GwCtx gw2;
    uint8_t wire2[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw2, NEWK, 6, GWID, NDID, CUR, 6, 1, 2, 700, wire2) == KR_ERR_COUNTER,
          "rot rollback: gw refuses to build counter<=committed");
    // and node-side rollback refusal with hand-built payload:
    uint8_t plain22[shepherd_psk::V1_LEN];
    memset(plain22, 0, sizeof(plain22));
    plain22[1] = 0x4B; shepherd_kr::putU32(plain22 + 2, 6); memcpy(plain22 + 6, CUR, 16);
    uint8_t wire3[shepherd_psk::WIRE_LEN];
    CHECK(shepherd_psk::wrap(NEWK, 7, 7, plain22, wire3), "rot rollback: hand wrap");
    NodeCtx node3;
    CHECK(nodeStageRotation(node3, NEWK, 6, NDID, GWID, wire3, 700) == KR_ERR_COUNTER,
          "rot rollback: node refuses counter<=committed with KR_ERR_COUNTER");
    CHECK(node3.refuseCounter == 1, "rot rollback: counted");
  }
  // CCM tamper: flip a ciphertext byte -> unwrap fails -> KR_ERR_AUTH
  {
    GwCtx gw; NodeCtx node;
    uint8_t wire[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK, 6, 3, 4, 0, wire) == KR_OK, "tamper: make");
    wire[15] ^= 0x01;
    CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 0) == KR_ERR_AUTH,
          "tamper: node must refuse with KR_ERR_AUTH");
    CHECK(node.refuseAuth == 1 && node.state == KR_IDLE, "tamper: counted, nothing staged");
  }
  // staged-not-committed revert on timeout: staged key never used,
  // context expires and aborts cleanly, old key untouched
  {
    GwCtx gw; NodeCtx node;
    uint8_t wire[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK, 6, 5, 6, 1000, wire) == KR_OK, "timeout: make");
    CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 1000) == KR_OK, "timeout: stage");
    CHECK(!nodeExpired(node, 1000 + 119999, 120000), "timeout: not yet expired");
    CHECK(nodeExpired(node, 1000 + 120001, 120000), "timeout: expired after window");
    nodeAbort(node);
    CHECK(node.state == KR_IDLE, "timeout: aborted to idle");
    uint8_t out[16]; uint32_t co = 0; uint8_t dummyAuth[32] = {0};
    CHECK(nodeCommit(node, dummyAuth, out, &co) == KR_ERR_STATE,
          "timeout: commit after abort refused KR_ERR_STATE");
  }
}

// ---------------- dual-key window + persistence model ----------------
// "NVS" model: ONLY the committed pair is ever written (the sketches
// persist on commit/promote, never on stage). A reboot restores the
// committed pair and a fresh, empty staged context.
struct Nvs { uint8_t key[16]; uint32_t ctr; bool has; };

static void test_dualkey_and_persistence() {
  static const uint8_t NEWK[16] = {0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
                                   0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f};
  uint8_t plain22[shepherd_psk::V1_LEN];
  for (int i = 0; i < (int)sizeof(plain22); i++) plain22[i] = (uint8_t)(i + 1);
  plain22[0] = 1;
  uint8_t wireOld[shepherd_psk::WIRE_LEN], wireNew[shepherd_psk::WIRE_LEN];
  CHECK(shepherd_psk::wrap(CUR, 9, 1, plain22, wireOld), "dual: wrap old");
  CHECK(shepherd_psk::wrap(NEWK, 9, 1, plain22, wireNew), "dual: wrap new");
  uint8_t p21[shepherd_psk::PAYLOAD_LEN]; bool usedStaged = false;

  GwCtx gw; // IDLE: only the committed key is tried
  CHECK(gwUnwrapDual(gw, CUR, wireOld, p21, &usedStaged) && !usedStaged, "dual: idle accepts old");
  CHECK(!gwUnwrapDual(gw, CUR, wireNew, p21, &usedStaged), "dual: idle rejects new");

  // stage a rotation: window stays CLOSED until the F7 reply check,
  // then (CONFIRMED) BOTH keys are accepted
  uint8_t wire[shepherd_psk::WIRE_LEN];
  CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK, 6, 1, 1, 0, wire) == KR_OK, "dual: stage");
  CHECK(gw.state == KR_STAGED, "dual: F7 window must NOT open at make time");
  CHECK(!gwUnwrapDual(gw, CUR, wireNew, p21, &usedStaged), "dual: pre-confirm new rejected");
  {
    uint8_t id[2];
    CHECK(shepherd_kr::keyId(NEWK, id), "dual: keyId");
    CHECK(gwConfirmRotation(gw, id, 6) == KR_OK, "dual: confirm reply");
  }
  CHECK(gw.state == KR_CONFIRMED, "dual: window open after confirm");
  CHECK(gwUnwrapDual(gw, CUR, wireOld, p21, &usedStaged) && !usedStaged, "dual: window accepts old");
  CHECK(gwUnwrapDual(gw, CUR, wireNew, p21, &usedStaged) && usedStaged, "dual: window accepts new (staged)");
  CHECK(gw.dualKeyFrames == 1, "dual: staged-frame counted");

  // abort -> only old again
  gwAbort(gw);
  CHECK(!gwUnwrapDual(gw, CUR, wireNew, p21, &usedStaged), "dual: after abort new rejected");
  CHECK(gwUnwrapDual(gw, CUR, wireOld, p21, &usedStaged), "dual: after abort old accepted");

  // commit path -> promote -> only new (with new committed key)
  GwCtx gw2; NodeCtx node;
  uint8_t wireR[shepherd_psk::WIRE_LEN];
  CHECK(gwMakeRotation(gw2, CUR, 5, GWID, NDID, NEWK, 6, 2, 2, 0, wireR) == KR_OK, "persist: stage");
  Nvs nvs = {{0}, 5, true};
  memcpy(nvs.key, CUR, 16);
  CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wireR, 0) == KR_OK, "persist: node stage");
  // reboot BEFORE commit: staged context (RAM) is gone, NVS unchanged
  node = NodeCtx();
  CHECK(node.state == KR_IDLE, "persist: reboot clears staged context");
  CHECK(nvs.ctr == 5 && memcmp(nvs.key, CUR, 16) == 0, "persist: reboot keeps committed key");
  // redo the stage and commit for real; sketches persist ONLY now
  CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wireR, 10) == KR_OK, "persist: restage");
  rotConfirmFromNode(gw2, node);  // F7
  uint8_t cauth[32];
  CHECK(gwMakeCommitAuth(gw2, cauth) == KR_OK, "persist: commit auth");
  uint8_t out[16]; uint32_t co = 0;
  CHECK(nodeCommit(node, cauth, out, &co) == KR_OK, "persist: commit");
  memcpy(nvs.key, out, 16); nvs.ctr = co; // the sketch's NVS write
  uint8_t gk[16]; uint32_t gc = 0;
  CHECK(gwPromote(gw2, gk, &gc) == KR_OK, "persist: promote");
  // reboot AFTER commit: committed pair survives
  node = NodeCtx();
  CHECK(nvs.ctr == 6 && memcmp(nvs.key, NEWK, 16) == 0, "persist: committed survives reboot");
  GwCtx gw3; // idle again with the NEW committed key
  CHECK(gwUnwrapDual(gw3, nvs.key, wireNew, p21, &usedStaged) && !usedStaged,
        "persist: after commit only new accepted");
  CHECK(!gwUnwrapDual(gw3, nvs.key, wireOld, p21, &usedStaged),
        "persist: after commit old rejected");
}

static const uint8_t NDID_C[8] = {'S', 'L', 'N', '-', '0', '0', 'C', '3'};
static const uint8_t NDID_D[8] = {'S', 'L', 'N', '-', '0', '0', 'D', '4'};
static const uint8_t NEWK2[16] = {0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
                                  0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f};

// ---------------- F2 counter rule: gaps + F15 bad-commit retry ----
static void test_gap_and_retry() {
  // gap counter (committed+2) ACCEPTED at stage, both mechanisms
  {
    NodeCtx node; GwCtx gw;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 7, 1000, ek) == KR_OK, "gap: node begin +2");
    uint8_t ct[CT_LEN], auth[32];
    CHECK(gwEncap(gw, CUR, 5, GWID, NDID, 7, ek, 1000, ct, auth) == KR_OK, "gap: gw encap +2");
    GwCtx gw2; NodeCtx node2;
    uint8_t wire[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw2, CUR, 5, GWID, NDID, NEWK2, 7, 9, 9, 0, wire) == KR_OK,
          "gap: gw rotation +2");
    CHECK(nodeStageRotation(node2, CUR, 5, NDID, GWID, wire, 0) == KR_OK, "gap: node stage +2");
    CHECK(node2.targetCounter == 7, "gap: target recorded");
  }
  // bad commit proof leaves the staged context alive for retry (F15)
  {
    GwCtx gw; NodeCtx node;
    uint8_t wire[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK2, 6, 8, 8, 0, wire) == KR_OK, "retry: make");
    CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 0) == KR_OK, "retry: stage");
    rotConfirmFromNode(gw, node);
    uint8_t junk[32] = {0};
    uint8_t out[16]; uint32_t co = 0;
    CHECK(nodeCommit(node, junk, out, &co) == KR_ERR_AUTH, "retry: bad proof refused");
    CHECK(node.state == KR_CONFIRMED, "retry: context alive after bad proof");
    CHECK(node.refuseAuth == 1, "retry: counted");
    uint8_t cauth[32];
    CHECK(gwMakeCommitAuth(gw, cauth) == KR_OK, "retry: auth");
    CHECK(nodeCommit(node, cauth, out, &co) == KR_OK && co == 6, "retry: honest retry lands");
  }
}

// ---------------- F5: authenticated abort ----------------
static void test_abort_auth() {
  // no staged context => no-op success (auth ignored entirely)
  {
    NodeCtx node;
    uint8_t junk[32] = {0};
    CHECK(nodeVerifyAbort(node, CUR, nullptr, 0) == KR_OK, "abort: idle no-op (empty)");
    CHECK(nodeVerifyAbort(node, CUR, junk, 32) == KR_OK, "abort: idle no-op (junk)");
  }
  // CONFIRMED (rotation): bad proof refused + context kept; good proof aborts
  {
    GwCtx gw; NodeCtx node;
    uint8_t wire[shepherd_psk::WIRE_LEN];
    CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK2, 6, 1, 2, 0, wire) == KR_OK, "abort: make");
    CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 0) == KR_OK, "abort: stage");
    rotConfirmFromNode(gw, node);
    uint8_t junk[32] = {0};
    CHECK(nodeVerifyAbort(node, CUR, junk, 32) == KR_ERR_AUTH, "abort: bad proof refused");
    CHECK(node.state == KR_CONFIRMED, "abort: context kept after bad proof");
    CHECK(nodeVerifyAbort(node, CUR, junk, 0) == KR_ERR_AUTH, "abort: missing proof refused");
    uint8_t proof[32];
    CHECK(gwMakeAbortAuth(gw, CUR, proof) == KR_OK, "abort: gw proof");
    CHECK(nodeVerifyAbort(node, CUR, proof, 32) == KR_OK, "abort: good proof aborts");
    CHECK(node.state == KR_IDLE, "abort: context gone");
  }
  // STAGED Mechanism A: proof keyed by the current PSK
  {
    NodeCtx node; GwCtx gw;
    uint8_t ek[EK_LEN];
    CHECK(nodeBeginKem(node, 5, NDID, GWID, 6, 0, ek) == KR_OK, "abort-kem: begin");
    uint8_t ct[CT_LEN], auth[32];
    CHECK(gwEncap(gw, CUR, 5, GWID, NDID, 6, ek, 0, ct, auth) == KR_OK, "abort-kem: encap");
    uint8_t proof[32];
    CHECK(gwMakeAbortAuth(gw, CUR, proof) == KR_OK, "abort-kem: gw proof");
    CHECK(nodeVerifyAbort(node, CUR, proof, 32) == KR_OK, "abort-kem: node verifies");
    CHECK(node.state == KR_IDLE, "abort-kem: aborted");
  }
}

// ---------------- F6: cross-node commit-proof replay ----------------
static void test_cross_node_proof() {
  GwCtx gwA, gwB; NodeCtx nodeA, nodeB;
  uint8_t wireA[shepherd_psk::WIRE_LEN], wireB[shepherd_psk::WIRE_LEN];
  CHECK(gwMakeRotation(gwA, CUR, 5, GWID, NDID, NEWK2, 6, 1, 1, 0, wireA) == KR_OK, "xnode: make A");
  CHECK(gwMakeRotation(gwB, CUR, 5, GWID, NDID_C, NEWK2, 6, 1, 1, 0, wireB) == KR_OK, "xnode: make B");
  CHECK(nodeStageRotation(nodeA, CUR, 5, NDID, GWID, wireA, 0) == KR_OK, "xnode: stage A");
  CHECK(nodeStageRotation(nodeB, CUR, 5, NDID_C, GWID, wireB, 0) == KR_OK, "xnode: stage B");
  rotConfirmFromNode(gwA, nodeA);
  rotConfirmFromNode(gwB, nodeB);
  uint8_t proofA[32], proofB[32];
  CHECK(gwMakeCommitAuth(gwA, proofA) == KR_OK, "xnode: proof A");
  CHECK(gwMakeCommitAuth(gwB, proofB) == KR_OK, "xnode: proof B");
  CHECK(memcmp(proofA, proofB, 32) != 0, "xnode: proofs differ by identity binding");
  uint8_t out[16]; uint32_t co = 0;
  CHECK(nodeCommit(nodeB, proofA, out, &co) == KR_ERR_AUTH,
        "xnode: A's proof replayed to B must fail");
  CHECK(nodeB.state == KR_CONFIRMED, "xnode: B context survives the replay attempt");
  CHECK(nodeCommit(nodeB, proofB, out, &co) == KR_OK && co == 6, "xnode: B's own proof works");
  CHECK(nodeCommit(nodeA, proofA, out, &co) == KR_OK, "xnode: A's own proof works");
}

// ---------------- F7: rotate-reply gate ----------------
static void test_rotate_reply_gate() {
  GwCtx gw; NodeCtx node;
  uint8_t wire[shepherd_psk::WIRE_LEN];
  CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK2, 6, 3, 3, 0, wire) == KR_OK, "gate: make");
  CHECK(gw.state == KR_STAGED, "gate: window closed at STAGED");
  CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 0) == KR_OK, "gate: node stage");
  uint8_t id[2];
  CHECK(shepherd_kr::keyId(node.stagedKey, id), "gate: keyId");
  uint32_t failsBefore = gw.failures;
  CHECK(gwConfirmRotation(gw, id, 99) == KR_ERR_AUTH, "gate: counter mismatch refused");
  CHECK(gw.rotateMismatch == 1, "gate: mismatch counter incremented");
  CHECK(gw.failures == failsBefore + 1, "gate: failure counter incremented");
  CHECK(gw.state == KR_IDLE, "gate: session failed AT the rotate step");
  // wrong key ID is likewise a mismatch
  GwCtx gw2;
  uint8_t wire2[shepherd_psk::WIRE_LEN];
  CHECK(gwMakeRotation(gw2, CUR, 5, GWID, NDID, NEWK2, 6, 3, 3, 0, wire2) == KR_OK, "gate: make2");
  uint8_t badId[2] = {0xDE, 0xAD};
  CHECK(gwConfirmRotation(gw2, badId, 6) == KR_ERR_AUTH, "gate: key-ID mismatch refused");
  CHECK(gw2.rotateMismatch == 1, "gate: mismatch counted (2)");
}

// ---------------- F15: gwExpired + F4 lost ACK ----------------
static void test_gw_expired_and_ack_lost() {
  GwCtx gw; NodeCtx node;
  uint8_t wire[shepherd_psk::WIRE_LEN];
  CHECK(gwMakeRotation(gw, CUR, 5, GWID, NDID, NEWK2, 6, 4, 4, 1000, wire) == KR_OK, "exp: make");
  CHECK(nodeStageRotation(node, CUR, 5, NDID, GWID, wire, 1000) == KR_OK, "exp: stage");
  CHECK(!gwExpired(gw, 1000 + 119999, 120000), "exp: gw not yet expired");
  CHECK(gwExpired(gw, 1000 + 120001, 120000), "exp: gw expired after window");
  rotConfirmFromNode(gw, node);
  // node commits; the gateway's POST result is lost (F4)
  uint8_t cauth[32];
  CHECK(gwMakeCommitAuth(gw, cauth) == KR_OK, "ack: auth");
  uint8_t out[16]; uint32_t co = 0;
  CHECK(nodeCommit(node, cauth, out, &co) == KR_OK, "ack: node committed");
  CHECK(gwNoteCommitAckLost(gw) == KR_OK, "ack: note lost ACK");
  CHECK(gw.state == KR_CONFIRMED && gw.awaitingFrame, "ack: CONFIRMED + awaiting frame");
  CHECK(gw.commitAckLost == 1, "ack: counted");
  // the frame trigger can still promote
  uint8_t gk[16]; uint32_t gc = 0;
  CHECK(gwPromote(gw, gk, &gc) == KR_OK && gc == 6 && memcmp(gk, NEWK2, 16) == 0,
        "ack: frame-trigger promote still works");
  CHECK(!gw.awaitingFrame, "ack: awaiting cleared by promote");
}

// ---------------- F1: freshness-aware gateway model ----------------
// Test-local model mirroring lora_gateway.ino handlePacket() AFTER
// the F1 fix and keyrefresh_model.FreshnessGateway step for step:
// unwrap -> staged-key frames are promotion CANDIDATES that must
// pass freshness under the rebased state -> freshness -> deliver.
// Node commit bumps boot_ctr (F1a), so post-commit frames are
// (boot+1, 0..); a rebased suffix rejects lower boot counters.
struct FreshGw {
  uint8_t committed[16];
  uint8_t staged[16];
  bool window = false, round = false;
  struct E { bool used = false; uint32_t bc = 0, fc = 0; bool rebased = false; };
  E tab[8]; uint16_t sufs[8]; int n = 0;
  E *find(uint16_t s, bool alloc) {
    for (int i = 0; i < n; i++) if (sufs[i] == s) return &tab[i];
    if (!alloc || n >= 8) return nullptr;
    sufs[n] = s; tab[n] = E(); tab[n].used = true; return &tab[n++];
  }
  // returns 1 delivered, 0 dropped; sets *promoted
  int handle(const uint8_t *wire, bool *promoted) {
    *promoted = false;
    uint8_t plain[shepherd_psk::PAYLOAD_LEN];
    bool usedStaged = false;
    if (!shepherd_psk::unwrap(committed, wire, plain)) {
      if (!(window && shepherd_psk::unwrap(staged, wire, plain))) return 0;
      usedStaged = true;
    }
    uint32_t bc = shepherd_psk::getU32(wire + shepherd_psk::NONCE_OFF);
    uint32_t fc = shepherd_psk::getU32(wire + shepherd_psk::NONCE_OFF + 4);
    uint16_t suffix = shepherd_psk::getU16(plain + 1);
    E *e = find(suffix, false);
    if (usedStaged && !round) {
      if (e && (bc < e->bc || (bc == e->bc && fc <= e->fc))) return 0;  // replay: NO promote
      if (!e) e = find(suffix, true);
      if (!e) return 0;
      e->bc = bc; e->fc = fc; e->rebased = true;                        // rebase (F1b)
      memcpy(committed, staged, 16); window = false;                    // promote
      *promoted = true;
      return 1;                                                         // frame delivered
    }
    if (e) {
      if (bc == e->bc && fc <= e->fc) return 0;
      if (bc < e->bc && e->rebased) return 0;
    } else {
      e = find(suffix, true);
      if (!e) return 0;
    }
    e->bc = bc; e->fc = fc;
    if (usedStaged && round) e->rebased = true;
    return 1;
  }
};

static void makeFrame(const uint8_t key[16], uint32_t bc, uint32_t fc,
                      uint16_t suffix, uint8_t *wire) {
  uint8_t plain22[shepherd_psk::V1_LEN];
  for (int i = 0; i < (int)sizeof(plain22); i++) plain22[i] = (uint8_t)(i + 1);
  plain22[0] = 1; plain22[1] = 1;
  plain22[2] = (uint8_t)(suffix >> 8); plain22[3] = (uint8_t)suffix;
  CHECK(shepherd_psk::wrap(key, bc, fc, plain22, wire), "fresh: wrap");
}

static void test_freshness_f1() {
  FreshGw fg;
  memcpy(fg.committed, CUR, 16);
  uint8_t wire[shepherd_psk::WIRE_LEN];
  bool prom = false;
  makeFrame(CUR, 7, 2800, 0x00B2, wire);
  CHECK(fg.handle(wire, &prom) == 1 && !prom, "f1: pre-refresh frame delivered");
  // refresh: window opens with the staged (new) key
  memcpy(fg.staged, NEWK2, 16); fg.window = true;
  // node commits -> boot bumped 7->8, frame counter restarts
  makeFrame(NEWK2, 8, 0, 0x00B2, wire);
  CHECK(fg.handle(wire, &prom) == 1 && prom, "f1: promoting frame delivered + promotes");
  CHECK(memcmp(fg.committed, NEWK2, 16) == 0, "f1: gateway on new key");
  makeFrame(NEWK2, 8, 1, 0x00B2, wire);
  CHECK(fg.handle(wire, &prom) == 1 && !prom, "f1: post-commit frames decode");
  makeFrame(NEWK2, 8, 0, 0x00B2, wire);  // exact replay of promoting frame
  CHECK(fg.handle(wire, &prom) == 0, "f1: duplicate promoting frame rejected");
  makeFrame(CUR, 7, 2800, 0x00B2, wire);  // replayed OLD frame, old key
  CHECK(fg.handle(wire, &prom) == 0, "f1: old replay (old key) rejected");
  makeFrame(NEWK2, 7, 2800, 0x00B2, wire);  // old counters under the new key
  CHECK(fg.handle(wire, &prom) == 0, "f1: old replay (new key) rejected — rebased suffix");
  // a replay-classified staged-key frame never promotes
  FreshGw fg2;
  memcpy(fg2.committed, CUR, 16);
  makeFrame(CUR, 7, 2800, 0x00B2, wire);
  CHECK(fg2.handle(wire, &prom) == 1, "f1b: seed high-water");
  memcpy(fg2.staged, NEWK2, 16); fg2.window = true;
  makeFrame(NEWK2, 7, 100, 0x00B2, wire);  // staged key, stale counters
  CHECK(fg2.handle(wire, &prom) == 0 && !prom, "f1b: stale staged frame dropped");
  CHECK(memcmp(fg2.committed, CUR, 16) == 0 && fg2.window, "f1b: no promotion, window survives");
}

// ---------------- F2: gateway round, 3 nodes ----------------
static void test_round() {
  GwCtx gw;
  CHECK(gwRoundBegin(gw, 5, GWID, NEWK2, 6, 0) == KR_OK, "round: begin");
  CHECK(gw.roundOpen && gw.state == KR_CONFIRMED, "round: window open for the round");
  CHECK(gwRoundAbortPermitted(gw), "round: abort permitted before any commit");
  const uint8_t *ids[3] = {NDID, NDID_C, NDID_D};
  NodeCtx nodes[3];
  // stage + commit A and B into the round (F6 cross-check between them)
  uint8_t proofA[32];
  for (int i = 0; i < 2; i++) {
    uint8_t wire[shepherd_psk::WIRE_LEN], ctx[32];
    CHECK(gwRoundMakeRotation(gw, CUR, ids[i], 10 + i, 20 + i, wire, ctx) == KR_OK,
          "round: make rotation %d", i);
    CHECK(nodeStageRotation(nodes[i], CUR, 5, ids[i], GWID, wire, 0) == KR_OK,
          "round: node stage %d", i);
    uint8_t rid[2];
    CHECK(shepherd_kr::keyId(nodes[i].stagedKey, rid) &&
          shepherd_kr::krReplyMatches(gw.stagedKey, gw.targetCounter, rid, 6),
          "round: reply verify %d", i);
    gwRoundNoteStaged(gw);
    if (i == 0) CHECK(gwRoundCommitAuth(gw, ids[0], proofA) == KR_OK, "round: proof A");
  }
  {
    uint8_t out[16]; uint32_t co = 0;
    CHECK(nodeCommit(nodes[1], proofA, out, &co) == KR_ERR_AUTH,
          "round: A's proof replayed to B fails (F6)");
    CHECK(nodes[1].state == KR_CONFIRMED, "round: B context survives");
  }
  for (int i = 0; i < 2; i++) {
    uint8_t proof[32];
    CHECK(gwRoundCommitAuth(gw, ids[i], proof) == KR_OK, "round: proof %d", i);
    uint8_t out[16]; uint32_t co = 0;
    CHECK(nodeCommit(nodes[i], proof, out, &co) == KR_OK && co == 6 &&
          memcmp(out, NEWK2, 16) == 0, "round: node commit %d", i);
    gwRoundNoteCommitted(gw);
  }
  CHECK(!gwRoundAbortPermitted(gw), "round: abort forbidden after first commit");
  CHECK(gw.roundCommitted == 2, "round: committed tracked");
  // mid-round dual-key: old-key AND round-key frames both accepted,
  // gateway NOT promoted
  uint8_t plain22[shepherd_psk::V1_LEN];
  for (int i = 0; i < (int)sizeof(plain22); i++) plain22[i] = (uint8_t)(i + 1);
  plain22[0] = 1;
  uint8_t wOld[shepherd_psk::WIRE_LEN], wNew[shepherd_psk::WIRE_LEN];
  CHECK(shepherd_psk::wrap(CUR, 3, 10, plain22, wOld), "round: wrap old");
  CHECK(shepherd_psk::wrap(NEWK2, 4, 0, plain22, wNew), "round: wrap new");
  uint8_t p21[shepherd_psk::PAYLOAD_LEN]; bool usedStaged = false;
  CHECK(gwUnwrapDual(gw, CUR, wOld, p21, &usedStaged) && !usedStaged,
        "round: old-key node still decodes mid-round");
  CHECK(gwUnwrapDual(gw, CUR, wNew, p21, &usedStaged) && usedStaged,
        "round: committed node decodes mid-round");
  // third node joins the round the same way
  {
    uint8_t wire[shepherd_psk::WIRE_LEN], ctx[32];
    CHECK(gwRoundMakeRotation(gw, CUR, NDID_D, 12, 22, wire, ctx) == KR_OK, "round: make D");
    CHECK(nodeStageRotation(nodes[2], CUR, 5, NDID_D, GWID, wire, 0) == KR_OK, "round: stage D");
    gwRoundNoteStaged(gw);
    uint8_t proof[32];
    CHECK(gwRoundCommitAuth(gw, NDID_D, proof) == KR_OK, "round: proof D");
    uint8_t out[16]; uint32_t co = 0;
    CHECK(nodeCommit(nodes[2], proof, out, &co) == KR_OK, "round: commit D");
    gwRoundNoteCommitted(gw);
  }
  // explicit promote: gateway joins the round key at counter 6
  uint8_t gk[16]; uint32_t gc = 0;
  CHECK(gwPromote(gw, gk, &gc) == KR_OK && gc == 6 && memcmp(gk, NEWK2, 16) == 0,
        "round: explicit promote");
  CHECK(!gw.roundOpen, "round: closed by promote");
  GwCtx gwIdle;
  CHECK(gwUnwrapDual(gwIdle, NEWK2, wNew, p21, &usedStaged) && !usedStaged,
        "round: post-promote new key is the committed key");
  CHECK(!gwUnwrapDual(gwIdle, NEWK2, wOld, p21, &usedStaged),
        "round: post-promote old key rejected");
  // abort-before-any-commit round (fresh contexts)
  {
    GwCtx gw2; NodeCtx nd;
    CHECK(gwRoundBegin(gw2, 5, GWID, NEWK2, 6, 0) == KR_OK, "round-abort: begin");
    uint8_t wire[shepherd_psk::WIRE_LEN], ctx[32];
    CHECK(gwRoundMakeRotation(gw2, CUR, NDID, 5, 5, wire, ctx) == KR_OK, "round-abort: make");
    CHECK(nodeStageRotation(nd, CUR, 5, NDID, GWID, wire, 0) == KR_OK, "round-abort: stage");
    gwRoundNoteStaged(gw2);
    uint8_t aproof[32];
    CHECK(gwRoundAbortAuth(gw2, NDID, aproof) == KR_OK, "round-abort: proof");
    CHECK(gwRoundAbortPermitted(gw2), "round-abort: permitted (no commits)");
    gwAbort(gw2);
    CHECK(!gw2.roundOpen && gw2.state == KR_IDLE, "round-abort: gateway scrubbed");
    CHECK(nodeVerifyAbort(nd, CUR, aproof, 32) == KR_OK, "round-abort: node honors proof");
    CHECK(nd.state == KR_IDLE, "round-abort: node scrubbed");
  }
}

int main(int argc, char **argv) {
  const char *katPath = argc > 1 ? argv[1] : "mlkem_kat_vectors.json";
  std::string katDoc = slurp(katPath);
  test_stub_anchors();
  test_mlkem_kats(katDoc);
  test_handshake();
  test_rotation();
  test_dualkey_and_persistence();
  test_gap_and_retry();
  test_abort_auth();
  test_cross_node_proof();
  test_rotate_reply_gate();
  test_gw_expired_and_ack_lost();
  test_freshness_f1();
  test_round();
  if (failures == 0) {
    printf("PASS: %d checks, real keyrefresh.h + vendored ML-KEM-512 vs ACVP KATs\n", checks);
    return 0;
  }
  printf("FAILED: %d of %d checks failed\n", failures, checks);
  return 1;
}
