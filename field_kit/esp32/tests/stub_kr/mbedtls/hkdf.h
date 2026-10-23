/*
 * TEST DOUBLE for mbedtls/hkdf.h — host tests ONLY. Declares the one
 * mbedTLS 2.28 HKDF entry point keyrefresh.h calls. Implementation
 * (md_stub.cpp) follows RFC 5869 and is anchored to its test case 1
 * by the host test. See stub_kr/mbedtls/md.h for the rationale.
 */
#ifndef MBEDTLS_HKDF_H_KR_STUB
#define MBEDTLS_HKDF_H_KR_STUB

#include <stddef.h>
#include "mbedtls/md.h"

#ifdef __cplusplus
extern "C" {
#endif

int mbedtls_hkdf(const mbedtls_md_info_t *md, const unsigned char *salt,
                 size_t salt_len, const unsigned char *ikm, size_t ikm_len,
                 const unsigned char *info, size_t info_len,
                 unsigned char *okm, size_t okm_len);

#ifdef __cplusplus
}
#endif

#endif /* MBEDTLS_HKDF_H_KR_STUB */
