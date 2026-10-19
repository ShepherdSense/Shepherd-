@echo off
title MRSI Probe - BEAST+ bearing capture
cd /d "%~dp0"
where python >nul 2>nul && (python mrsi_probe.py --minutes 5) || (py mrsi_probe.py --minutes 5)
echo.
echo Probe saved in this folder. Send the newest mrsi_probe_*.jsonl back.
pause
