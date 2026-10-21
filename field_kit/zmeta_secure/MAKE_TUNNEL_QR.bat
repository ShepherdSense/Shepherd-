@echo off
REM ============================================================
REM  WireGuard tunnel QR maker (double-click)
REM
REM  Renders shepherd-mesh.conf (or a .conf you drag onto this
REM  file) as a QR code the EUD can scan with the WireGuard app
REM  (+ -> Scan from QR code) to import the tunnel.
REM
REM  Run the manual flow first: NEW_MESH_KEY.bat, then fill in
REM  shepherd-mesh.conf from the .example (see PAIRING.md).
REM
REM  The QR contains the tunnel PRIVATE KEY - treat it like
REM  the key itself.
REM ============================================================
setlocal
cd /d "%~dp0"

echo.
echo  === WireGuard tunnel QR ===
echo.

REM --- Find Python ---
set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
    where py >nul 2>nul && set "PY=py -3"
)
if not defined PY (
    echo  [!] Python was not found. Install it from python.org
    echo      and run this again.
    echo.
    pause
    exit /b 1
)

REM --- Make sure the qrcode package is available (one-time) ---
%PY% -c "import qrcode, PIL" >nul 2>nul
if errorlevel 1 (
    echo  Installing the qrcode package (one time)...
    %PY% -m pip install "qrcode[pil]"
    %PY% -c "import qrcode, PIL" >nul 2>nul
    if errorlevel 1 (
        echo.
        echo  [!] Could not install the qrcode package.
        echo      Check the network connection and run this again.
        echo.
        pause
        exit /b 1
    )
)

if "%~1"=="" (
    %PY% make_tunnel_qr.py
) else (
    %PY% make_tunnel_qr.py "%~1"
)

echo.
pause
