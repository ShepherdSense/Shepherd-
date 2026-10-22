/*
 * lora_psk_codec.h — Shepherd LoRa codec v2 (PSK wrap), SHARED code.
 *
 * This header is the single implementation of the v2 wrap/unwrap codec
 * used by BOTH firmware sketches:
 *   - lora_node/lora_node.ino      (wrap: shepherd_psk::wrap)
 *   - lora_gateway/lora_gateway.ino (unwrap + rebuildV1)
 *
 * It exists so the two sketches can never drift apart on the wire
 * format: nonce construction, CCM call parameters, AAD, tag placement,
 * and the rebuild of the equivalent v1 buffer live here exactly once.
 * The host C++ test (esp32/tests/test_lora_psk_cpp.cpp) compiles THIS
 * header and runs it against the frozen vectors in
 * esp32/tests/lora_psk_vectors.json, byte for byte.
 *
 * Wire format (docs/lora_psk_codec_spec.md):
 *   [0]      schema = 2 (PLAINTEXT — gateway gate + CCM AAD)
 *   [1..8]   nonce: boot_ctr u32 BE || frame_ctr u32 BE (PLAINTEXT)
 *   [9..29]  ciphertext: AES-128-CCM of v1 payload bytes [1..21]
 *   [30..33] CCM tag (4 bytes)
 *
 * Arduino: this folder is a library — copy esp32/shepherd_lora_psk/
 * into your Arduino libraries folder, then both sketches find it via
 * #include <lora_psk_codec.h>. (The thumbdrive FLASH_*.bat flow uses
 * pre-compiled binaries and needs no compiling at all.)
 */

#ifndef SHEPHERD_LORA_PSK_CODEC_H
#define SHEPHERD_LORA_PSK_CODEC_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "mbedtls/ccm.h"   // AES-128-CCM (HW AES on ESP32)

namespace shepherd_psk {

// Wire constants — the ONLY definitions; sketches must not re-define.
static const uint8_t SCHEMA_V1  = 1;
static const uint8_t SCHEMA_PSK = 2;
static const size_t  V1_LEN      = 22;   // full v1 packet
static const size_t  WIRE_LEN    = 34;   // full v2 wire packet
static const size_t  NONCE_OFF   = 1;    // wire[1..8]
static const size_t  CT_OFF      = 9;    // wire[9..29]
static const size_t  TAG_OFF     = 30;   // wire[30..33]
static const size_t  TAG_LEN     = 4;
static const size_t  PAYLOAD_LEN = 21;   // v1 bytes [1..21]

inline void putU32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
inline uint16_t getU16(const uint8_t *p) {
  return (uint16_t)((p[0] << 8) | p[1]);
}
inline uint32_t getU32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

// Wrap a complete 22-byte v1 packet into its 34-byte v2 wire form
// under key, with the given nonce counters. The caller owns counter
// state: on success the caller advances frame_ctr; on failure the
// packet must NOT be sent (returns false on any crypto error).
// AAD = the schema byte (wire[0]); the nonce is authenticated by the
// CCM computation, so it cannot be altered without failing the tag.
inline bool wrap(const uint8_t key[16], uint32_t bootCtr, uint32_t frameCtr,
                 const uint8_t *plain22, uint8_t *wire) {
  wire[0] = SCHEMA_PSK;
  putU32(wire + NONCE_OFF, bootCtr);
  putU32(wire + NONCE_OFF + 4, frameCtr);
  mbedtls_ccm_context ctx;
  mbedtls_ccm_init(&ctx);
  int rc = mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (rc == 0) {
    rc = mbedtls_ccm_encrypt_and_tag(&ctx, PAYLOAD_LEN,
                                     wire + NONCE_OFF, 8,   // nonce
                                     wire, 1,               // AAD = schema
                                     plain22 + 1, wire + CT_OFF,
                                     wire + TAG_OFF, TAG_LEN);
  }
  mbedtls_ccm_free(&ctx);
  return rc == 0;
}

// Authenticate-and-decrypt a 34-byte v2 wire packet into its 21-byte
// payload. Returns false on tag failure — the caller MUST drop the
// packet and never look at plain21 in that case (its contents are
// unverified by definition). The caller is responsible for the schema
// gate and the length check BEFORE calling (byte [0] and length are
// how the gateway decides this is a v2 frame at all).
inline bool unwrap(const uint8_t key[16], const uint8_t *wire,
                   uint8_t *plain21) {
  mbedtls_ccm_context ctx;
  mbedtls_ccm_init(&ctx);
  int rc = mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (rc == 0) {
    rc = mbedtls_ccm_auth_decrypt(&ctx, PAYLOAD_LEN,
                                  wire + NONCE_OFF, 8,   // nonce
                                  wire, 1,               // AAD = schema
                                  wire + CT_OFF, plain21,
                                  wire + TAG_OFF, TAG_LEN);
  }
  mbedtls_ccm_free(&ctx);
  return rc == 0;
}

// Rebuild the equivalent 22-byte v1 packet from a decrypted 21-byte
// payload, for the shared v1 decode path. This rebuild is what makes
// the gateway's re-emitted JSON byte-identical for v1 and v2 frames.
inline void rebuildV1(const uint8_t *plain21, uint8_t *v1) {
  v1[0] = SCHEMA_V1;
  memcpy(v1 + 1, plain21, PAYLOAD_LEN);
}

}  // namespace shepherd_psk

#endif  // SHEPHERD_LORA_PSK_CODEC_H
