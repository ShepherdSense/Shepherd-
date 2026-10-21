#!/usr/bin/env python3
"""Render a filled WireGuard tunnel config as a scannable QR code.

For the manual tunnel flow (PAIRING.md): NEW_MESH_KEY.bat -> fill in
shepherd-mesh.conf -> run this -> the EUD operator opens the WireGuard
app, taps + -> "Scan from QR code", and the tunnel is imported. No
file copying to the phone, no typing keys.

Usage:
    python make_tunnel_qr.py [path-to.conf]
(default: shepherd-mesh.conf next to this script)

The QR payload is the config with comment and blank lines stripped —
semantically identical, but a much smaller QR that a phone camera can
actually read off a screen. The .conf file itself is never modified.

SECURITY: the config contains the tunnel PRIVATE key, so the QR code
and the generated tunnel_qr.png are exactly as secret as the key.
Show them to the EUD, scan, and do not send screenshots of them
anywhere you would not send the key itself.

Rendering needs the `qrcode` pip package (MAKE_TUNNEL_QR.bat installs
it automatically). Without it this prints the fix and exits.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def conf_payload(text):
    """Strip full-line comments and blank lines from a wg config.

    WireGuard keys/sections/order are untouched; the result is the
    smallest faithful encoding of the same tunnel."""
    lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lines.append(line)
    return "\n".join(lines) + "\n"


def unfilled_fields(text):
    """Names of template placeholders still present in the config."""
    return list(dict.fromkeys(re.findall(r"PASTE_[A-Z0-9_]+", text)))


def conf_address(text):
    """The tunnel Address value from the config, or None."""
    m = re.search(r"^\s*Address\s*=\s*(\S+)", text, re.MULTILINE)
    return m.group(1) if m else None


def main(argv):
    conf_path = argv[1] if len(argv) > 1 else os.path.join(
        HERE, "shepherd-mesh.conf")
    if not os.path.isfile(conf_path):
        print(f"[!] No config found at: {conf_path}")
        print()
        print("The tunnel config comes first:")
        print("  1. Double-click NEW_MESH_KEY.bat (creates mesh.key).")
        print("  2. Copy shepherd-mesh.conf.example to shepherd-mesh.conf")
        print("     and fill in the 4 values (private key, tunnel IP,")
        print("     gateway public key, gateway endpoint).")
        print("  3. Run this again.")
        return 2

    # utf-8-sig: a conf saved by Notepad / PowerShell 5.1 may carry a
    # BOM, which would otherwise land in the payload's first line and
    # silently break the EUD's import while this script reports success.
    text = open(conf_path, encoding="utf-8-sig").read()
    missing = unfilled_fields(text)
    if missing:
        print(f"[!] {os.path.basename(conf_path)} still has unfilled "
              "template values:")
        for m in missing:
            print(f"      {m}")
        print()
        print("Fill them in first (see PAIRING.md) — a QR of the "
              "template would not connect anything.")
        return 2

    payload = conf_payload(text)

    # The template ships Address pre-filled (10.99.0.11) — legitimate
    # for the first mesh, silently fatal for any later one (the
    # gateway binds each peer's key to its assigned IP). Not a hard
    # refusal, but the operator must see the value and confirm it.
    addr = conf_address(text)
    print()
    if addr:
        print(f"  Tunnel address in this config: {addr}")
        print("  This must be the IP the gateway operator assigned to")
        print("  THIS mesh. Two meshes on one address = a tunnel that")
        print("  imports fine and then silently never connects.")
    else:
        print("  [!] No Address line found in the config — the tunnel")
        print("      will not work without one (see the .example).")

    try:
        import qrcode  # type: ignore
        from qrcode.constants import ERROR_CORRECT_M  # type: ignore
    except ImportError:
        print("[!] The 'qrcode' Python package is not installed.")
        print("    Fix:  python -m pip install \"qrcode[pil]\"")
        print("    (or just double-click MAKE_TUNNEL_QR.bat, which "
              "installs it for you)")
        return 3

    print()
    print("  *** SECRET: this QR code contains the tunnel PRIVATE KEY. ***")
    print("  Scan it with the EUD's WireGuard app, then close the image.")
    print("  Do not screenshot it or send it anywhere the key itself")
    print("  would not go.")
    print()

    qr = qrcode.QRCode(error_correction=ERROR_CORRECT_M, border=2)
    qr.add_data(payload)
    qr.make()

    png_path = os.path.join(HERE, "tunnel_qr.png")
    try:
        img = qr.make_image(fill_color="black", back_color="white")
        img = img.resize((img.width * 6, img.height * 6))
        img.save(png_path)
        print(f"  QR image: {png_path}")
        print("  On the EUD: WireGuard app -> + -> Scan from QR code.")
        print("  DELETE tunnel_qr.png once the EUD has scanned it —")
        print("  it carries the private key, and this folder travels.")
        try:
            os.startfile(png_path)  # Windows: open in the image viewer
            print("  (Opened the image for scanning.)")
        except (AttributeError, OSError):
            pass  # not Windows / no viewer — the file is there to open
    except Exception as e:  # Pillow missing etc. — ASCII still works
        print(f"  (PNG skipped: {e})")

    print()
    try:
        qr.print_ascii(invert=True)
    except Exception:
        print("  (This console can't render the ASCII QR — use the "
              "PNG image instead.)")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
