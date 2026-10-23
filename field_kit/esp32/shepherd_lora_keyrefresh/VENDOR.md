# Vendored ML-KEM-512 — provenance

**Implementation chosen:** PQClean, `crypto_kem/ml-kem-512/clean`
(the portable, readable C implementation of FIPS 203 ML-KEM-512).

- Upstream: https://github.com/PQClean/PQClean
- Commit: `0586a824fc0d49df0b6b6e9179d8d15d06d0974f`
  ("Merge pull request #614 from PQClean/readme-retirement-alternatives")
- Vendored: 2026-10-23, ML-KEM-512 **only** (no other parameter sets,
  no other schemes), portable "clean" C backend only (no AVX2/asm).
- License: public domain / CC0 — see `src/mlkem/LICENSE` (PQClean's
  per-scheme license file, preserved in-tree) and the upstream
  repository's `LICENSE` (CC0). The Keccak/FIPS-202 code
  (`fips202.c/.h`, from PQClean `common/`) is likewise public domain
  (TweetFips202 / supercop lineage, credited in its file header).
- Known-answer anchoring: the vendored code is tested **unmodified**
  against the official NIST ACVP ML-KEM vectors (FIPS 203 keyGen and
  encapDecap internalProjection sets) — see
  `esp32/tests/mlkem_kat_vectors.json` and
  `esp32/tests/test_keyrefresh_cpp.cpp`.

## Why PQClean and not mlkem-native

The brief recommended mlkem-native (Apache-2.0) first. mlkem-native
was evaluated and set aside for this prototype: its build is driven
by a meta-config system (per-scheme `config.h` generation,
FIPS-202 multiplexing backends, and a native/opt source split) that
does not drop cleanly into an Arduino library folder or a two-file
host test harness without generating/patching sources. PQClean's
`clean` tree is a flat set of self-contained C files with a stable
SUPERCERC-style API plus `*_derand` entry points — the derand API is
what makes byte-exact ACVP known-answer testing possible at all, and
the tree compiles unchanged under both xtensa-esp32-elf-gcc (ESP32
Arduino core 2.0.17) and host gcc/g++. No functional modifications
were needed. If this prototype graduates, re-evaluate mlkem-native
(or PQClean's successor lines) for its side-channel hardening story.

## Modifications to upstream files

**None** to any vendored PQClean file (all `src/mlkem/*.c` / `*.h`
except the two Shepherd-authored files below are byte-identical to
upstream at the commit above — including `compat.h` and
`crypto_declassify.h`, copied unmodified from PQClean `common/`
because the `clean` sources include them).

Shepherd-authored files in `src/mlkem/` (not upstream):

- `randombytes.h` — shim header declaring the exact interface
  PQClean's `kem.c`/`indcpa.c` include, with PQClean's own symbol
  rename (`randombytes` → `PQCLEAN_randombytes`). PQClean's
  `common/randombytes.h` was not copied; this header replaces it.
- `kr_randombytes.c` — implementation: `esp_fill_random()` on
  ESP32, `/dev/urandom` on host. PQClean's `common/randombytes.c`
  was deliberately **not** vendored (desktop-OS RNG APIs only;
  does not build for ESP32).

## What is NOT vendored

- Azevedo et al. (SBSeg 2025) code — explicitly excluded by the
  brief (no side-channel masking) and not publicly licensed for
  reuse; only their published ESP32 timing measurements informed
  the design (see `docs/lora_key_refresh_spec.md`).
- Any hand-rolled KEM math — none exists in this library; all KEM
  operations call the vendored code.
