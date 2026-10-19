@echo off
title BEAST+ CoT Capture
cd /d "%~dp0"
where python >nul 2>nul && (python beast_cot_capture.py --minutes 5) || (py beast_cot_capture.py --minutes 5)
echo.
echo Capture saved in this folder. Send the newest beast_capture_*.jsonl back.
pause
