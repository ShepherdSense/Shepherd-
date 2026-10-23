/*
 * randombytes.h — Shepherd shim header for the vendored PQClean
 * ML-KEM-512 code. Declares exactly the interface PQClean's kem.c /
 * indcpa.c expect (same include guard and symbol rename as PQClean's
 * own common/randombytes.h), but the IMPLEMENTATION is ours
 * (kr_randombytes.c, next to this file):
 *   - ESP32 (ESP_PLATFORM): esp_fill_random() — hardware RNG; the
 *     Shepherd nodes run Wi-Fi continuously, which is the entropy
 *     precondition Espressif documents for the HWRNG.
 *   - Host tests: /dev/urandom.
 * PQClean's own common/randombytes.c is deliberately NOT vendored
 * (it targets desktop OS RNG APIs and does not build for ESP32).
 */
#ifndef PQCLEAN_RANDOMBYTES_H
#define PQCLEAN_RANDOMBYTES_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

#define randombytes     PQCLEAN_randombytes
int randombytes(uint8_t *output, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* PQCLEAN_RANDOMBYTES_H */
