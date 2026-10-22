/*
 * Implementation of the mbedtls/ccm.h TEST DOUBLE (see the header next
 * to this file for why it exists and how it is anchored). AES-128
 * (encrypt direction only — CCM never needs the inverse cipher) and
 * CCM per RFC 3610 / NIST SP 800-38C, mirroring the construction of
 * the Python reference in ../aes_ccm.py step for step.
 *
 * Host tests ONLY. The firmware links the real mbedTLS on the ESP32.
 */

#include "mbedtls/ccm.h"

#include <string.h>

// ---------------- AES-128 (FIPS-197, encrypt direction) ----------------

static const uint8_t SBOX[256] = {
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
};
static const uint8_t RCON[10] = {0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36};

static uint8_t xtime(uint8_t a) {
  return (a & 0x80) ? (uint8_t)((a << 1) ^ 0x1B) : (uint8_t)(a << 1);
}

static void aes128_encrypt_block(const uint8_t key[16], const uint8_t in[16],
                                 uint8_t out[16]) {
  uint8_t w[176];
  memcpy(w, key, 16);
  for (int i = 4; i < 44; i++) {
    uint8_t t[4] = {w[4*(i-1)+0], w[4*(i-1)+1], w[4*(i-1)+2], w[4*(i-1)+3]};
    if (i % 4 == 0) {
      uint8_t r[4] = {(uint8_t)(SBOX[t[1]] ^ RCON[i/4 - 1]), SBOX[t[2]],
                      SBOX[t[3]], SBOX[t[0]]};
      memcpy(t, r, 4);
    }
    for (int j = 0; j < 4; j++) w[4*i + j] = (uint8_t)(w[4*(i-4) + j] ^ t[j]);
  }
  uint8_t s[16];
  for (int i = 0; i < 16; i++) s[i] = (uint8_t)(in[i] ^ w[i]);
  for (int rnd = 1; rnd <= 10; rnd++) {
    for (int i = 0; i < 16; i++) s[i] = SBOX[s[i]];
    uint8_t t[16];
    for (int r = 0; r < 4; r++)
      for (int c = 0; c < 4; c++)
        t[4*c + r] = s[4*((c + r) % 4) + r];
    memcpy(s, t, 16);
    if (rnd < 10) {
      uint8_t o[16];
      for (int c = 0; c < 4; c++) {
        uint8_t *a = s + 4*c;
        o[4*c+0] = (uint8_t)(xtime(a[0]) ^ (xtime(a[1]) ^ a[1]) ^ a[2] ^ a[3]);
        o[4*c+1] = (uint8_t)(a[0] ^ xtime(a[1]) ^ (xtime(a[2]) ^ a[2]) ^ a[3]);
        o[4*c+2] = (uint8_t)(a[0] ^ a[1] ^ xtime(a[2]) ^ (xtime(a[3]) ^ a[3]));
        o[4*c+3] = (uint8_t)((xtime(a[0]) ^ a[0]) ^ a[1] ^ a[2] ^ xtime(a[3]));
      }
      memcpy(s, o, 16);
    }
    for (int i = 0; i < 16; i++) s[i] = (uint8_t)(s[i] ^ w[16*rnd + i]);
  }
  memcpy(out, s, 16);
}

// ---------------- CCM (RFC 3610) ----------------

static void ccm_mac(const uint8_t key[16], const uint8_t *nonce, size_t nonce_len,
                    const uint8_t *pt, size_t pt_len,
                    const uint8_t *aad, size_t aad_len, size_t tag_len,
                    uint8_t mac_out[16]) {
  const size_t L = 15 - nonce_len;
  uint8_t flags = (uint8_t)(((aad_len > 0) ? 0x40 : 0) |
                            (((tag_len - 2) / 2) << 3) | (L - 1));
  // B0 || encoded-AAD (own padded segment) || plaintext (padded)
  uint8_t x[16] = {0};
  uint8_t block[16];
  // B0
  memset(block, 0, 16);
  block[0] = flags;
  memcpy(block + 1, nonce, nonce_len);
  for (size_t i = 0; i < L; i++)
    block[15 - i] = (uint8_t)(pt_len >> (8 * i));
  for (int i = 0; i < 16; i++) block[i] ^= x[i];
  aes128_encrypt_block(key, block, x);
  // AAD segment: 2-byte length prefix + aad, zero-padded to 16
  if (aad_len > 0) {
    size_t seg = 2 + aad_len;
    size_t total = seg + ((16 - seg % 16) % 16);
    for (size_t off = 0; off < total; off += 16) {
      for (size_t i = 0; i < 16; i++) {
        size_t pos = off + i;
        uint8_t b = 0;
        if (pos == 0) b = (uint8_t)(aad_len >> 8);
        else if (pos == 1) b = (uint8_t)aad_len;
        else if (pos - 2 < aad_len) b = aad[pos - 2];
        block[i] = (uint8_t)(x[i] ^ b);
      }
      aes128_encrypt_block(key, block, x);
    }
  }
  // Plaintext, zero-padded to 16
  for (size_t off = 0; off < pt_len; off += 16) {
    size_t n = pt_len - off; if (n > 16) n = 16;
    for (size_t i = 0; i < 16; i++)
      block[i] = (uint8_t)(x[i] ^ (i < n ? pt[off + i] : 0));
    aes128_encrypt_block(key, block, x);
  }
  memcpy(mac_out, x, 16);
}

static void ccm_ctr_block(const uint8_t key[16], const uint8_t *nonce,
                            size_t nonce_len, uint64_t ctr, uint8_t out[16]) {
  const size_t L = 15 - nonce_len;
  uint8_t block[16] = {0};
  block[0] = (uint8_t)(L - 1);
  memcpy(block + 1, nonce, nonce_len);
  for (size_t i = 0; i < L; i++)
    block[15 - i] = (uint8_t)(ctr >> (8 * i));
  aes128_encrypt_block(key, block, out);
}

static int ccm_check_args(mbedtls_ccm_context *ctx, size_t iv_len,
                          size_t add_len, size_t tag_len) {
  if (!ctx || !ctx->key_set) return MBEDTLS_ERR_CCM_BAD_INPUT;
  if (iv_len < 7 || iv_len > 13) return MBEDTLS_ERR_CCM_BAD_INPUT;
  if (add_len >= 0xFF00) return MBEDTLS_ERR_CCM_BAD_INPUT;  // 2-byte AAD len only
  if (tag_len != 4 && tag_len != 6 && tag_len != 8 && tag_len != 10 &&
      tag_len != 12 && tag_len != 14 && tag_len != 16)
    return MBEDTLS_ERR_CCM_BAD_INPUT;
  return 0;
}

extern "C" {

void mbedtls_ccm_init(mbedtls_ccm_context *ctx) {
  if (ctx) memset(ctx, 0, sizeof(*ctx));
}

int mbedtls_ccm_setkey(mbedtls_ccm_context *ctx, mbedtls_cipher_id_t cipher,
                       const unsigned char *key, unsigned int keybits) {
  if (!ctx || cipher != MBEDTLS_CIPHER_ID_AES || keybits != 128 || !key)
    return MBEDTLS_ERR_CCM_BAD_INPUT;
  memcpy(ctx->key, key, 16);
  ctx->key_set = 1;
  return 0;
}

int mbedtls_ccm_encrypt_and_tag(mbedtls_ccm_context *ctx, size_t length,
                                const unsigned char *iv, size_t iv_len,
                                const unsigned char *add, size_t add_len,
                                const unsigned char *input, unsigned char *output,
                                unsigned char *tag, size_t tag_len) {
  int rc = ccm_check_args(ctx, iv_len, add_len, tag_len);
  if (rc != 0) return rc;
  uint8_t mac[16], s0[16];
  ccm_mac(ctx->key, iv, iv_len, input, length, add, add_len, tag_len, mac);
  ccm_ctr_block(ctx->key, iv, iv_len, 0, s0);
  for (size_t i = 0; i < tag_len; i++) tag[i] = (uint8_t)(mac[i] ^ s0[i]);
  for (size_t off = 0; off < length; off += 16) {
    uint8_t s[16];
    ccm_ctr_block(ctx->key, iv, iv_len, off / 16 + 1, s);
    size_t n = length - off; if (n > 16) n = 16;
    for (size_t i = 0; i < n; i++) output[off + i] = (uint8_t)(input[off + i] ^ s[i]);
  }
  return 0;
}

int mbedtls_ccm_auth_decrypt(mbedtls_ccm_context *ctx, size_t length,
                             const unsigned char *iv, size_t iv_len,
                             const unsigned char *add, size_t add_len,
                             const unsigned char *input, unsigned char *output,
                             const unsigned char *tag, size_t tag_len) {
  int rc = ccm_check_args(ctx, iv_len, add_len, tag_len);
  if (rc != 0) return rc;
  // Decrypt into a scratch buffer first: on tag failure the caller's
  // output stays untouched (stricter than the real API, same contract:
  // the caller must drop the packet either way).
  uint8_t plain[4096];
  if (length > sizeof(plain)) return MBEDTLS_ERR_CCM_BAD_INPUT;
  for (size_t off = 0; off < length; off += 16) {
    uint8_t s[16];
    ccm_ctr_block(ctx->key, iv, iv_len, off / 16 + 1, s);
    size_t n = length - off; if (n > 16) n = 16;
    for (size_t i = 0; i < n; i++) plain[off + i] = (uint8_t)(input[off + i] ^ s[i]);
  }
  uint8_t mac[16], s0[16];
  ccm_mac(ctx->key, iv, iv_len, plain, length, add, add_len, tag_len, mac);
  ccm_ctr_block(ctx->key, iv, iv_len, 0, s0);
  uint8_t diff = 0;
  for (size_t i = 0; i < tag_len; i++)
    diff |= (uint8_t)((mac[i] ^ s0[i]) ^ tag[i]);
  if (diff != 0) return MBEDTLS_ERR_CCM_AUTH_FAILED;
  memcpy(output, plain, length);
  return 0;
}

void mbedtls_ccm_free(mbedtls_ccm_context *ctx) {
  if (ctx) memset(ctx, 0, sizeof(*ctx));
}

}  // extern "C"
