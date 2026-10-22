/*
 * TEST DOUBLE for mbedtls/ccm.h — host tests ONLY, never shipped to a
 * device. Declares exactly the slice of the mbedTLS 2.28 CCM API that
 * src/lora_psk_codec.h calls, with the real API's signatures and
 * cipher-id values, so the REAL shared header compiles unchanged on a
 * host. The implementation (ccm_stub.cpp, next to this file) is a
 * from-scratch AES-128 + CCM written for this test.
 *
 * Why a double instead of linking the host's libmbedcrypto: the host
 * has the runtime library but no headers and no linker symlink, and
 * hand-declaring the real context struct would be an ABI guess. The
 * double is anchored the same way the Python reference (aes_ccm.py)
 * is: the C++ test runs it against the RFC 3610 test vector #1 AND
 * the frozen codec vectors (which the Python reference generated).
 * If the double's CCM were wrong, those checks fail loudly. What this
 * proves and does not prove is written out in
 * docs/lora_psk_codec_spec.md ("Tests").
 */

#ifndef MBEDTLS_CCM_H_STUB
#define MBEDTLS_CCM_H_STUB

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Values match mbedtls/cipher.h (2.28). */
typedef enum {
  MBEDTLS_CIPHER_ID_NONE = 0,
  MBEDTLS_CIPHER_ID_NULL = 1,
  MBEDTLS_CIPHER_ID_AES = 2,
  MBEDTLS_CIPHER_ID_DES = 3,
  MBEDTLS_CIPHER_ID_3DES = 4,
  MBEDTLS_CIPHER_ID_CAMELLIA = 5,
  MBEDTLS_CIPHER_ID_BLOWFISH = 6,
  MBEDTLS_CIPHER_ID_ARC4 = 7,
} mbedtls_cipher_id_t;

#define MBEDTLS_ERR_CCM_BAD_INPUT      -0x000D
#define MBEDTLS_ERR_CCM_AUTH_FAILED    -0x000F

typedef struct mbedtls_ccm_context {
  uint8_t key[16];
  int key_set;
} mbedtls_ccm_context;

void mbedtls_ccm_init(mbedtls_ccm_context *ctx);
int mbedtls_ccm_setkey(mbedtls_ccm_context *ctx, mbedtls_cipher_id_t cipher,
                       const unsigned char *key, unsigned int keybits);
int mbedtls_ccm_encrypt_and_tag(mbedtls_ccm_context *ctx, size_t length,
                                const unsigned char *iv, size_t iv_len,
                                const unsigned char *add, size_t add_len,
                                const unsigned char *input, unsigned char *output,
                                unsigned char *tag, size_t tag_len);
int mbedtls_ccm_auth_decrypt(mbedtls_ccm_context *ctx, size_t length,
                             const unsigned char *iv, size_t iv_len,
                             const unsigned char *add, size_t add_len,
                             const unsigned char *input, unsigned char *output,
                             const unsigned char *tag, size_t tag_len);
void mbedtls_ccm_free(mbedtls_ccm_context *ctx);

#ifdef __cplusplus
}
#endif

#endif  // MBEDTLS_CCM_H_STUB
