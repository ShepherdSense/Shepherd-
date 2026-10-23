/*
 * kr_randombytes.c — implementation of PQCLEAN_randombytes for the
 * vendored ML-KEM-512 code. See randombytes.h (this folder) for why
 * this file exists and why PQClean's own randombytes.c is not used.
 *
 * ESP32: esp_fill_random() draws from the hardware RNG. Espressif's
 * contract: true randomness is guaranteed while the RF subsystem
 * (Wi-Fi/BT) is running — Shepherd nodes and gateways run Wi-Fi
 * continuously (AP + status page), so the precondition holds in this
 * firmware. A future variant that generates keys before Wi-Fi starts
 * MUST call bootloader_random_enable() first.
 */
#include "randombytes.h"

#if defined(ESP_PLATFORM)
#include "esp_system.h" /* esp_fill_random */

int PQCLEAN_randombytes(uint8_t *output, size_t n) {
  esp_fill_random(output, n);
  return 0;
}

#else /* host (tests) */
#include <stdio.h>

int PQCLEAN_randombytes(uint8_t *output, size_t n) {
  FILE *f = fopen("/dev/urandom", "rb");
  if (f == NULL) {
    return -1;
  }
  size_t got = fread(output, 1, n, f);
  fclose(f);
  return (got == n) ? 0 : -1;
}
#endif
