@echo off
REM Double-click, or run from PowerShell with arguments, e.g.:
REM   RUN_MPU5_PROBE.bat --ip 192.168.1.50 --community public
setlocal enabledelayedexpansion
if not "%~1"=="" (
  python "%~dp0mpu5_snmp_probe.py" %*
  goto done
)
:prompt
set /p IP="MPU5 IP address: "
if "!IP!"=="" goto prompt
python "%~dp0mpu5_snmp_probe.py" --ip !IP!
:done
pause
