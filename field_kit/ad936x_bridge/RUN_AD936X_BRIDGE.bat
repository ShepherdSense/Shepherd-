@echo off
REM Shepherd AD936x spectrum-sensor bridge -- double-click launcher.
REM RECEIVE ONLY. This bridge never transmits.
setlocal
cd /d "%~dp0"

where py >nul 2>nul || (echo Python 3 not found. Install it from python.org, then double-click again. & pause & exit /b 1)

if not exist ".venv\Scripts\python.exe" (
  echo Creating virtual environment (first run only)...
  py -3 -m venv .venv || (echo Could not create venv. & pause & exit /b 1)
)
set PY=.venv\Scripts\python.exe

%PY% -c "import numpy" >nul 2>nul || (
  echo Installing dependencies (first run only)...
  %PY% -m pip install --upgrade pip >nul
  %PY% -m pip install -r requirements.txt || (echo Install failed. & pause & exit /b 1)
)

echo.
echo ============================================================
echo  Shepherd AD936x bridge -- RECEIVE ONLY, never transmits
echo  Send band-energy readings to Shepherd at 127.0.0.1:49161
echo ============================================================
echo.
echo  Usage: RUN_AD936X_BRIDGE.bat [--simulate] [other options]
echo.
echo    --simulate        no hardware: synthetic spectrum for testing
echo    --backend pluto   ADALM-Pluto  (needs: pip install pyadi-iio)
echo    --backend uhd     USRP B200/B210 (needs: pip install uhd)
echo    --stare 2437      stare at one band instead of sweeping
echo.

%PY% ad936x_bridge.py %*
pause
