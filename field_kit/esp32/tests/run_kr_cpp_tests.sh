#!/bin/sh
# Build and run the host C++ key-refresh test: the REAL
# shepherd_lora_keyrefresh header + REAL vendored PQClean ML-KEM-512
# + REAL codec header, against the NIST ACVP vectors in
# mlkem_kat_vectors.json. mbedTLS calls are served by the anchored
# test doubles in stub/ (CCM, existing) and stub_kr/ (MD/HKDF).
# Needs only host gcc/g++ — no installs.
set -e
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
MLKEM=../shepherd_lora_keyrefresh/src/mlkem
for f in "$MLKEM"/*.c; do
  gcc -std=c99 -Wall -Wextra -O1 -I "$MLKEM" -c "$f" -o "$TMP/$(basename "$f" .c).o"
done
g++ -std=c++11 -Wall -Wextra -O1 \
    -I stub -I stub_kr \
    -I ../shepherd_lora_psk/src -I ../shepherd_lora_keyrefresh/src \
    test_keyrefresh_cpp.cpp stub/ccm_stub.cpp stub_kr/md_stub.cpp \
    "$TMP"/*.o -o "$TMP/test_keyrefresh_cpp"
"$TMP/test_keyrefresh_cpp" mlkem_kat_vectors.json
