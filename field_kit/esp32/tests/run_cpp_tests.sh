#!/bin/sh
# Build and run the host C++ codec test: the REAL shared header
# (../shepherd_lora_psk/src/lora_psk_codec.h) against the frozen
# vectors in lora_psk_vectors.json, with the mbedTLS test double in
# stub/ standing in for the ESP32's mbedTLS (see stub/mbedtls/ccm.h).
# Needs only a host g++ — no installs, like the rest of the kit.
set -e
cd "$(dirname "$0")"
OUT="$(mktemp -d)/test_lora_psk_cpp"
g++ -std=c++11 -Wall -Wextra -O1 \
    -I stub -I ../shepherd_lora_psk/src \
    test_lora_psk_cpp.cpp stub/ccm_stub.cpp -o "$OUT"
"$OUT" lora_psk_vectors.json
