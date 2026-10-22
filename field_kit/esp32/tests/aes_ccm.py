"""Dependency-free AES-128 (encrypt direction) + AES-CCM reference
implementation, used ONLY by the host-side codec tests in this folder.

The firmware uses mbedTLS on the ESP32's hardware AES peripheral; this
pure-Python version exists so the shared test vectors can be generated
and checked on any machine with python3 — no pip installs, which fits
how the field kit is distributed.

Correctness anchors (see test_lora_psk.py):
  * AES-128 block: FIPS-197 known-answer test.
  * CCM: RFC 3610 test vector #1.
Only the AES *encryption* direction is implemented: CCM (CTR + CBC-MAC)
never needs the inverse cipher.
"""

# --- AES-128 ---------------------------------------------------------------

_SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else (a << 1) & 0xFF


def _expand_key(key):
    """AES-128 key schedule -> list of 11 round keys (16 bytes each)."""
    w = list(key)
    for i in range(4, 44):
        t = w[4 * (i - 1):4 * i]
        if i % 4 == 0:
            t = [_SBOX[t[1]] ^ _RCON[i // 4 - 1], _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
        w += [w[4 * (i - 4) + j] ^ t[j] for j in range(4)]
    return [bytes(w[16 * r:16 * r + 16]) for r in range(11)]


def aes128_encrypt_block(key, block):
    """Encrypt one 16-byte block with a 16-byte key (FIPS-197)."""
    assert len(key) == 16 and len(block) == 16
    rk = _expand_key(key)
    s = [b ^ k for b, k in zip(block, rk[0])]          # state, column-major
    for rnd in range(1, 11):
        s = [_SBOX[b] for b in s]                       # SubBytes
        # ShiftRows on column-major state: row r lives at s[r::4]
        t = [0] * 16
        for r in range(4):
            for c in range(4):
                t[4 * c + r] = s[4 * ((c + r) % 4) + r]
        s = t
        if rnd < 10:                                    # MixColumns
            out = [0] * 16
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                out[4 * c + 0] = _xtime(a[0]) ^ (_xtime(a[1]) ^ a[1]) ^ a[2] ^ a[3]
                out[4 * c + 1] = a[0] ^ _xtime(a[1]) ^ (_xtime(a[2]) ^ a[2]) ^ a[3]
                out[4 * c + 2] = a[0] ^ a[1] ^ _xtime(a[2]) ^ (_xtime(a[3]) ^ a[3])
                out[4 * c + 3] = (_xtime(a[0]) ^ a[0]) ^ a[1] ^ a[2] ^ _xtime(a[3])
            s = out
        s = [b ^ k for b, k in zip(s, rk[rnd])]         # AddRoundKey
    return bytes(s)


# --- CCM (RFC 3610 / NIST SP 800-38C) ---------------------------------------

def _pad16(data):
    return data + b"\x00" * ((16 - len(data) % 16) % 16)


def _ccm_mac(key, nonce, plaintext, aad, tag_len):
    L = 15 - len(nonce)
    flags = (0x40 if aad else 0) | (((tag_len - 2) // 2) << 3) | (L - 1)
    b0 = bytes([flags]) + nonce + len(plaintext).to_bytes(L, "big")
    data = b0
    if aad:
        if len(aad) >= 0xFF00:  # not needed by this codec; refuse, don't mis-encode
            raise ValueError("AAD too long for this implementation")
        # AAD is encoded (2-byte length prefix + data) and zero-padded
        # as its own segment following B0.
        data += _pad16(len(aad).to_bytes(2, "big") + aad)
    data += _pad16(plaintext)
    x = b"\x00" * 16
    for i in range(0, len(data), 16):
        x = aes128_encrypt_block(key, bytes(a ^ b for a, b in zip(x, data[i:i + 16])))
    return x


def _ccm_ctr(key, nonce, data, tag_mac):
    L = 15 - len(nonce)

    def ctr_block(i):
        return bytes([L - 1]) + nonce + i.to_bytes(L, "big")

    s0 = aes128_encrypt_block(key, ctr_block(0))
    out = bytearray()
    for off in range(0, len(data), 16):
        s = aes128_encrypt_block(key, ctr_block(off // 16 + 1))
        chunk = data[off:off + 16]
        out += bytes(a ^ b for a, b in zip(chunk, s))
    tag = bytes(a ^ b for a, b in zip(tag_mac, s0))
    return bytes(out), tag


def ccm_encrypt(key, nonce, plaintext, aad=b"", tag_len=4):
    """Returns ciphertext concatenated with the tag."""
    assert 7 <= len(nonce) <= 13 and tag_len in (4, 6, 8, 10, 12, 14, 16)
    mac = _ccm_mac(key, nonce, plaintext, aad, tag_len)
    ct, tag = _ccm_ctr(key, nonce, plaintext, mac)
    return ct + tag[:tag_len]


def ccm_decrypt(key, nonce, ct_and_tag, aad=b"", tag_len=4):
    """Returns the plaintext, or None if the tag does not verify."""
    assert 7 <= len(nonce) <= 13
    if len(ct_and_tag) < tag_len:
        return None
    if tag_len:
        ct, tag_rx = ct_and_tag[:-tag_len], ct_and_tag[-tag_len:]
    else:
        ct, tag_rx = ct_and_tag, b""
    L = 15 - len(nonce)

    def ctr_block(i):
        return bytes([L - 1]) + nonce + i.to_bytes(L, "big")

    out = bytearray()
    for off in range(0, len(ct), 16):
        s = aes128_encrypt_block(key, ctr_block(off // 16 + 1))
        chunk = ct[off:off + 16]
        out += bytes(a ^ b for a, b in zip(chunk, s))
    pt = bytes(out)
    mac = _ccm_mac(key, nonce, pt, aad, tag_len)
    s0 = aes128_encrypt_block(key, ctr_block(0))
    tag_calc = bytes(a ^ b for a, b in zip(mac, s0))[:tag_len]
    # constant-work compare (good hygiene even in test code)
    ok = len(tag_rx) == tag_len
    diff = 0
    for a, b in zip(tag_calc, tag_rx):
        diff |= a ^ b
    return pt if (ok and diff == 0) else None
