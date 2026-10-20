@echo off
rem ============================================================
rem  START_HUB.bat - double-click to run the ZMeta pairing hub.
rem  Reads pairing.conf and picks the right mode automatically:
rem    certfp=-  ->  --no-tls (Cloudflare terminates TLS upstream)
rem    otherwise ->  normal TLS with the self-signed pairing cert
rem  Leave this window open while meshes are joining.
rem ============================================================
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo.
  echo  Python was not found. Install Python 3 from python.org,
  echo  tick "Add python.exe to PATH", then run this again.
  echo.
  pause
  exit /b 1
)

if not exist pairing.conf (
  echo.
  echo  No pairing.conf found. Run SETUP_PAIRING.bat once first.
  echo.
  pause
  exit /b 1
)

set "MODE="
for /f "tokens=1,2 delims==" %%a in (pairing.conf) do (
  if "%%a"=="certfp" if "%%b"=="-" set "MODE=--no-tls"
)

echo.
if defined MODE (
  echo  Starting hub in CLOUDFLARE mode ^(--no-tls, loopback only^)...
  echo  Make sure cloudflared is pointing at localhost:8443.
  echo.
  python zmeta_pairing_server.py --no-tls --pair-host 127.0.0.1
) else (
  echo  Starting hub in DIRECT mode ^(self-signed TLS, app pins the cert^)...
  echo.
  python zmeta_pairing_server.py
)

echo.
echo  Hub stopped.
pause
