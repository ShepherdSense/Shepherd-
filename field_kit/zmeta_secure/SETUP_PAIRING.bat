@echo off
REM ============================================================
REM SETUP_PAIRING.bat — one-time hub setup for ZMeta invite pairing.
REM  1. Makes sure Python + the cryptography package exist.
REM  2. Generates a self-signed TLS cert (5 years) for the pairing
REM     server: pairing.crt / pairing.key
REM  3. Prints the cert SHA256 fingerprint (goes into invite codes).
REM  4. Writes pairing.conf from your answers.
REM ============================================================
cd /d "%~dp0"

where python >nul 2>&1
if errorlevel 1 (
  echo.
  echo ERROR: Python not found. Install Python 3 from python.org
  echo ^(tick "Add python.exe to PATH"^), then re-run this file.
  echo.
  pause
  exit /b 1
)

echo Checking for the 'cryptography' package...
python -c "import cryptography" >nul 2>&1
if errorlevel 1 (
  echo Installing 'cryptography' ^(one time^)...
  python -m pip install cryptography
  if errorlevel 1 (
    echo.
    echo ERROR: pip install failed. Check your internet connection
    echo and re-run.
    echo.
    pause
    exit /b 1
  )
)

if not exist pairing.crt (
  echo.
  echo Generating self-signed pairing cert ^(5 years^)...
  python -c "from cryptography import x509; from cryptography.x509.oid import NameOID; from cryptography.hazmat.primitives import hashes, serialization; from cryptography.hazmat.primitives.asymmetric import rsa; import datetime; key=rsa.generate_private_key(public_exponent=65537, key_size=2048); name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'ZMeta-Pairing')]); now=datetime.datetime.now(datetime.timezone.utc); cert=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now).not_valid_after(now+datetime.timedelta(days=1825)).add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True).sign(key, hashes.SHA256())); open('pairing.key','wb').write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())); open('pairing.crt','wb').write(cert.public_bytes(serialization.Encoding.PEM)); print('cert written')"
  if errorlevel 1 (
    echo ERROR generating cert.
    pause
    exit /b 1
  )
) else (
  echo Existing pairing.crt found - keeping it.
)

echo.
echo Cert SHA256 fingerprint ^(this goes into every invite code^):
python -c "import hashlib; from cryptography.x509 import load_pem_x509_certificate; from cryptography.hazmat.primitives import serialization; der=load_pem_x509_certificate(open('pairing.crt','rb').read()).public_bytes(serialization.Encoding.DER); print(hashlib.sha256(der).hexdigest())" > "%TEMP%\zmeta_certfp.txt"
set /p CERTFP=<"%TEMP%\zmeta_certfp.txt"
del "%TEMP%\zmeta_certfp.txt" >nul 2>&1
echo   %CERTFP%
echo.
echo The Shepherd app pins this fingerprint. If you ever regenerate the
echo cert, re-run this setup and hand out fresh invites.
echo.

if not exist pairing.conf copy pairing.conf.example pairing.conf >nul

REM --- Hub WireGuard keypair: generate automatically, never ask ---
set "WG="
if exist "%ProgramFiles%\WireGuard\wg.exe" set "WG=%ProgramFiles%\WireGuard\wg.exe"
if exist "%ProgramFiles(x86)%\WireGuard\wg.exe" set "WG=%ProgramFiles(x86)%\WireGuard\wg.exe"
where wg.exe >nul 2>nul && for /f "delims=" %%i in ('where wg.exe') do set "WG=%%i"
if not defined WG (
  echo.
  echo  [!] WireGuard for Windows was not found, and the hub needs a
  echo      WireGuard identity even for HTTPS-only meshes.
  echo.
  echo  Install it (free, one installer): https://www.wireguard.com/install/
  echo  Then re-run this file - it will pick up where it left off.
  echo.
  pause
  exit /b 1
)
if not exist gateway.key (
  echo.
  echo Generating hub WireGuard keypair...
  "%WG%" genkey > gateway.key
  "%WG%" pubkey < gateway.key > gateway.pub 2>nul || (
    for /f "delims=" %%k in ('type gateway.key ^| "%WG%" pubkey') do echo %%k> gateway.pub
  )
  echo   gateway.key kept PRIVATE on this hub. Public key:
  type gateway.pub
) else (
  echo Existing gateway.key found - keeping it.
  "%WG%" pubkey < gateway.key > gateway.pub 2>nul || (
    for /f "delims=" %%k in ('type gateway.key ^| "%WG%" pubkey') do echo %%k> gateway.pub
  )
)
set /p HUBPUB=<gateway.pub

echo.
echo The next question is ONLY for the WireGuard fallback path.
echo If every mesh joins over HTTPS (Cloudflare), it is never used -
echo you can just press Enter.
set /p HUBHOST="Public hostname/IP for WireGuard (blank = unused): "
set /p WGPORT="Hub WireGuard UDP port [51820]: "
if "%WGPORT%"=="" set WGPORT=51820
set /p PAIRPORT="Pairing HTTPS TCP port [8443]: "
if "%PAIRPORT%"=="" set PAIRPORT=8443

REM Write pairing.conf fresh (keeps the file predictable).
if "%HUBHOST%"=="" (
  set "WGENDPOINT="
) else (
  set "WGENDPOINT=%HUBHOST%:%WGPORT%"
)
(
  echo # ZMeta pairing hub config - written by SETUP_PAIRING.bat
  echo hub_pubkey=%HUBPUB%
  echo wg_port=%WGPORT%
  echo wg_endpoint=%WGENDPOINT%
  echo wg_interface=wg0
  echo pair_port=%PAIRPORT%
  echo zmeta_target=10.99.0.1:5555
  echo certfp=%CERTFP%
) > pairing.conf

echo.
echo ============================================================
echo pairing.conf written.
echo.
echo Next steps:
echo   1. HTTPS-only meshes ^(Cloudflare^): edit pairing.conf, set
echo      certfp=- and add: ingest_url=https://YOUR-DOMAIN/zmeta/ingest
echo      then start with:  python zmeta_pairing_server.py --no-tls --pair-host 127.0.0.1
echo      ^(behind cloudflared -^> localhost:%PAIRPORT%^)
echo   2. Direct mode: just run:  python zmeta_pairing_server.py
echo      ^(uses the self-signed cert; the app pins its fingerprint^)
echo   3. Or double-click START_HUB.bat - it picks the right mode.
echo   4. Make an invite:  python zmeta_invite.py invite --label "Team A" --hub YOUR-HUB-HOST
echo.
echo If you ever need the WireGuard path: gateway.key is this hub's
echo private key ^(already generated above^). Open UDP %WGPORT% in the
echo firewall and set wg_endpoint in pairing.conf to your public IP.
echo ============================================================
echo.
pause
