@echo off
REM Double-click, or run from PowerShell with arguments, e.g.:
REM   Probe-163.bat --ip 192.168.1.50 --community public
setlocal enabledelayedexpansion
if not "%~1"=="" (
  python "%~dp0l3harris_snmp_probe.py" %*
  goto done
)
:prompt
set /p IP="Radio IP address: "
if "!IP!"=="" goto prompt
python "%~dp0l3harris_snmp_probe.py" --ip !IP!
:done
pause
