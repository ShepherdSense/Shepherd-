@echo off
REM ============================================================
REM  Shepherd mesh — WireGuard keypair generator (double-click)
REM
REM  Creates this mesh's WireGuard identity for the secured
REM  Shepherd -> ZMeta link. The PRIVATE key never leaves this PC.
REM  Send only mesh.pub (the public key) to the ZMeta gateway operator.
REM ============================================================
setlocal

echo.
echo  === Shepherd mesh WireGuard key setup ===
echo.

REM --- Find wg.exe (WireGuard for Windows) ---
set "WG="
if exist "%ProgramFiles%\WireGuard\wg.exe" set "WG=%ProgramFiles%\WireGuard\wg.exe"
if exist "%ProgramFiles(x86)%\WireGuard\wg.exe" set "WG=%ProgramFiles(x86)%\WireGuard\wg.exe"
where wg.exe >nul 2>nul && for /f "delims=" %%i in ('where wg.exe') do set "WG=%%i"

if not defined WG (
    echo  [!] WireGuard for Windows was not found.
    echo.
    echo  Install it first (free, one installer):
    echo    https://www.wireguard.com/install/
    echo.
    echo  Then run this file again.
    echo.
    pause
    exit /b 1
)

echo  Using: %WG%
echo.

if exist mesh.key (
    echo  [!] mesh.key already exists in this folder.
    echo      Delete mesh.key and mesh.pub if you want a FRESH identity
    echo      (the gateway operator must then replace your old public key).
    echo.
    pause
    exit /b 1
)

REM --- Generate keypair ---
"%WG%" genkey > mesh.key
"%WG%" pubkey < mesh.key > mesh.pub

echo  Keypair created:
echo    mesh.key  - PRIVATE - never share, never email in the clear
echo    mesh.pub  - PUBLIC  - send this to the ZMeta gateway operator
echo.
echo  Your PUBLIC key (give this to the gateway operator):
echo.
type mesh.pub
echo.
echo  The operator adds you as a peer and gives you:
echo    1. Your tunnel IP (e.g. 10.99.0.11)
echo    2. The gateway's public key and public endpoint (host:port)
echo.
echo  Then edit shepherd-mesh.conf.example with those values,
echo  rename it to shepherd-mesh.conf, and import it into WireGuard.
echo.
pause
