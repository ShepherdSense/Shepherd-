/*
 * md_stub.cpp — host-test implementations of the mbedTLS MD/HKDF
 * slice declared in stub_kr/mbedtls/{md,hkdf}.h. TEST CODE ONLY.
 * SHA-256 per FIPS 180-4, HMAC per RFC 2104, HKDF per RFC 5869.
 * Anchored to published vectors by test_keyrefresh_cpp.cpp before
 * any protocol check runs (SHA-256 "abc", RFC 4231 case 1,
 * RFC 5869 case 1) — a wrong double fails loudly, never silently.
 */
#include "mbedtls/md.h"
#include "mbedtls/hkdf.h"
#include <string.h>

namespace {

struct Sha256 {
  uint32_t h[8];
  uint64_t len;
  uint8_t buf[64];
  size_t buflen;
};

const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

void block(Sha256 &s, const uint8_t *p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
           ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = s.h[0], b = s.h[1], c = s.h[2], d = s.h[3], e = s.h[4],
           f = s.h[5], g = s.h[6], h = s.h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = h + S1 + ch + K[i] + w[i];
    uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + mj;
    h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  s.h[0] += a; s.h[1] += b; s.h[2] += c; s.h[3] += d;
  s.h[4] += e; s.h[5] += f; s.h[6] += g; s.h[7] += h;
}

void sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
  Sha256 s = {{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f,
               0x9b05688c, 0x1f83d9ab, 0x5be0cd19},
              0, {0}, 0};
  s.len = len;
  while (len >= 64) { block(s, data); data += 64; len -= 64; }
  memcpy(s.buf, data, len);
  s.buflen = len;
  s.buf[s.buflen++] = 0x80;
  if (s.buflen > 56) {
    while (s.buflen < 64) s.buf[s.buflen++] = 0;
    block(s, s.buf);
    s.buflen = 0;
  }
  while (s.buflen < 56) s.buf[s.buflen++] = 0;
  uint64_t bits = s.len * 8;
  for (int i = 0; i < 8; i++) s.buf[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
  block(s, s.buf);
  for (int i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(s.h[i] >> 24); out[4 * i + 1] = (uint8_t)(s.h[i] >> 16);
    out[4 * i + 2] = (uint8_t)(s.h[i] >> 8); out[4 * i + 3] = (uint8_t)s.h[i];
  }
}

void hmacSha256(const uint8_t *key, size_t klen, const uint8_t *data,
                size_t len, uint8_t out[32]) {
  uint8_t k0[64];
  memset(k0, 0, sizeof(k0));
  if (klen > 64) sha256(key, klen, k0);
  else memcpy(k0, key, klen);
  // messages here are < 2048 B; assemble ipad||data / opad||inner
  static thread_local uint8_t buf[4200];
  for (int i = 0; i < 64; i++) buf[i] = (uint8_t)(k0[i] ^ 0x36);
  memcpy(buf + 64, data, len);
  uint8_t inner[32];
  sha256(buf, 64 + len, inner);
  for (int i = 0; i < 64; i++) buf[i] = (uint8_t)(k0[i] ^ 0x5c);
  memcpy(buf + 64, inner, 32);
  sha256(buf, 64 + 32, out);
}

} // namespace

extern "C" {

static const mbedtls_md_info_t kSha256Info = {MBEDTLS_MD_SHA256};

const mbedtls_md_info_t *mbedtls_md_info_from_type(mbedtls_md_type_t type) {
  return type == MBEDTLS_MD_SHA256 ? &kSha256Info : nullptr;
}

int mbedtls_md(const mbedtls_md_info_t *md_info, const unsigned char *input,
               size_t ilen, unsigned char *output) {
  if (!md_info || md_info->type != MBEDTLS_MD_SHA256) return -1;
  sha256(input, ilen, output);
  return 0;
}

int mbedtls_md_hmac(const mbedtls_md_info_t *md_info, const unsigned char *key,
                    size_t keylen, const unsigned char *input, size_t ilen,
                    unsigned char *output) {
  if (!md_info || md_info->type != MBEDTLS_MD_SHA256) return -1;
  hmacSha256(key, keylen, input, ilen, output);
  return 0;
}

int mbedtls_hkdf(const mbedtls_md_info_t *md, const unsigned char *salt,
                 size_t salt_len, const unsigned char *ikm, size_t ikm_len,
                 const unsigned char *info, size_t info_len,
                 unsigned char *okm, size_t okm_len) {
  if (!md || md->type != MBEDTLS_MD_SHA256) return -1;
  uint8_t zeros[32] = {0};
  if (!salt) { salt = zeros; salt_len = 32; }
  uint8_t prk[32];
  hmacSha256(salt, salt_len, ikm, ikm_len, prk);
  uint8_t t[32];
  size_t done = 0;
  uint8_t ctr = 1;
  while (done < okm_len) {
    // T(i) = HMAC(prk, T(i-1) || info || i) — assembled in the hmac
    // helper's buffer via a scratch concat (inputs here are small).
    uint8_t msg[32 + 512 + 1];
    size_t m = 0;
    if (ctr > 1) { memcpy(msg, t, 32); m = 32; }
    if (info_len > 512) return -1;
    memcpy(msg + m, info, info_len); m += info_len;
    msg[m++] = ctr;
    hmacSha256(prk, 32, msg, m, t);
    size_t take = okm_len - done < 32 ? okm_len - done : 32;
    memcpy(okm + done, t, take);
    done += take;
    ctr++;
  }
  return 0;
}

} // extern "C"
