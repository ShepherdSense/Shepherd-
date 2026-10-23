/*
 * TEST DOUBLE for mbedtls/md.h — host tests ONLY, never shipped to a
 * device. Declares exactly the slice of the mbedTLS 2.28 MD API that
 * shepherd_lora_keyrefresh/src/keyrefresh.h calls (SHA-256 one-shot
 * + HMAC), so the REAL library header compiles unchanged on a host.
 * The implementation (md_stub.cpp) is a from-scratch FIPS 180-4
 * SHA-256 + RFC 2104 HMAC written for this test; the test anchors it
 * to FIPS 180-4 ("abc"), RFC 4231 HMAC case 1, and RFC 5869 HKDF
 * case 1 before trusting it — any error fails those checks loudly.
 * See stub/mbedtls/ccm.h for the same pattern used by the codec test.
 */
#ifndef MBEDTLS_MD_H_KR_STUB
#define MBEDTLS_MD_H_KR_STUB

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { MBEDTLS_MD_NONE = 0, MBEDTLS_MD_SHA256 = 6 } mbedtls_md_type_t;

typedef struct mbedtls_md_info_t { mbedtls_md_type_t type; } mbedtls_md_info_t;

const mbedtls_md_info_t *mbedtls_md_info_from_type(mbedtls_md_type_t type);
int mbedtls_md(const mbedtls_md_info_t *md_info, const unsigned char *input,
               size_t ilen, unsigned char *output);
int mbedtls_md_hmac(const mbedtls_md_info_t *md_info, const unsigned char *key,
                    size_t keylen, const unsigned char *input, size_t ilen,
                    unsigned char *output);

#ifdef __cplusplus
}
#endif

#endif /* MBEDTLS_MD_H_KR_STUB */
