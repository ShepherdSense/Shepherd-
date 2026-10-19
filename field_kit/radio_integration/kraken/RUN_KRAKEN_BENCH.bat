@echo off
title KrakenSDR Bench Capture
cd /d "%~dp0"
set /p KRAKEN_IP=Enter the Kraken Pi IP address (e.g. 192.168.1.50):
where python >nul 2>nul && (python kraken_bench_capture.py --ip %KRAKEN_IP% --minutes 5) || (py kraken_bench_capture.py --ip %KRAKEN_IP% --minutes 5)
echo.
echo Capture saved in this folder. Send the newest kraken_bench_*.jsonl back,
echo and tell me the KNOWN bearing of your test emitter.
pause
