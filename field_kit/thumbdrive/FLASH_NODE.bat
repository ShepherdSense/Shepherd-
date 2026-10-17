@echo off
setlocal
title Shepherd Node Flasher
echo ============================================================
echo  Shepherd Node Flasher
echo  Flashes the Shepherd sensor firmware onto a plugged-in ESP32.
echo  Plug the ESP32 in via USB first, then press any key.
echo ============================================================
pause >nul

set "DRIVE=%~d0"
set "FW=%DRIVE%\shepherd-field-kit\firmware"

if not exist "%FW%\shepherd_node.ino.bin" (
  echo [ERROR] Firmware files not found in %FW%
  pause & exit /b 1
)

:: ---------- python + esptool ----------
py -3 --version >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Python 3 not found. Install it from https://www.python.org/downloads/
  echo (check "Add python.exe to PATH"), then re-run this script.
  pause & exit /b 1
)
py -3 -m esptool version >nul 2>&1
if errorlevel 1 (
  echo Installing esptool (one time)...
  py -3 -m pip install --quiet esptool || (
    echo [ERROR] pip install esptool failed. Check internet and re-run.
    pause & exit /b 1
  )
)

:: ---------- find the ESP32 COM port ----------
for /f "delims=" %%p in ('py -3 -c "import serial.tools.list_ports as lp; ps=[(p.device, (p.description or '')) for p in lp.comports()]; cands=[d for d,desc in ps if any(k in desc for k in ['CP210','CH340','USB Serial','UART'])] or [d for d,desc in ps]; print(cands[0] if cands else '')"') do set "PORT=%%p"
if "%PORT%"=="" (
  echo [ERROR] No USB-serial device found.
  echo If this is the first flash on this PC, install the USB driver:
  echo   CP210x: https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers
  echo   CH340:  https://www.wch.cn/downloads/CH341SER_EXE.html
  echo Then unplug/replug the ESP32 and re-run.
  pause & exit /b 1
)
echo Found device on %PORT%

:: ---------- flash ----------
echo Flashing - do NOT unplug until done...
py -3 -m esptool --chip esp32 --port %PORT% --baud 460800 write_flash -z ^
  0x1000 "%FW%\shepherd_node.ino.bootloader.bin" ^
  0x8000 "%FW%\shepherd_node.ino.partitions.bin" ^
  0xe000 "%FW%\boot_app0.bin" ^
  0x10000 "%FW%\shepherd_node.ino.bin"
if errorlevel 1 (
  echo [ERROR] Flash failed. Hold the BOOT button on the ESP32 and re-run.
  pause & exit /b 1
)

echo.
echo ============================================================
echo  DONE. The node will now boot as WiFi AP "Shepherd-SHNX-XXXX".
echo  Join it from the Shepherd device - password: shepherd-field
echo  Status page: http://192.168.4.1  (change defaults later)
echo ============================================================
pause
