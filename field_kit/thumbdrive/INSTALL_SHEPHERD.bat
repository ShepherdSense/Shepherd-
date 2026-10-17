@echo off
setlocal EnableDelayedExpansion
title Shepherd Field Installer
echo ============================================================
echo  Shepherd Field Installer
echo  Installs the latest Shepherd build on this Windows device
echo  and stages automatic node detection.
echo ============================================================
echo.
echo NOTE: Windows blocks true plug-and-play auto-run on USB drives
echo for security. This one double-click IS the install step.
echo.

set "DRIVE=%~d0"
set "KIT=%DRIVE%\shepherd-field-kit"
set "TARGET=%USERPROFILE%\Shepherd"
set "REPO_URL=https://github.com/thedracospark-prog/Shepherd-"

if not exist "%KIT%\shepherd" (
  echo [ERROR] Kit folder not found: %KIT%\shepherd
  echo Make sure you copied the whole kit to the thumb drive.
  pause & exit /b 1
)

:: ---------- 1. newest source: bundled vs GitHub ----------
set "BUNDLED_VER=unknown"
if exist "%KIT%\shepherd\VERSION" set /p BUNDLED_VER=<"%KIT%\shepherd\VERSION"
echo Bundled Shepherd version: %BUNDLED_VER%

set "USE_BUNDLED=1"
set "USE_VER=%BUNDLED_VER%"
where powershell >nul 2>&1 && (
  echo Checking GitHub for a newer release...
  for /f "delims=" %%v in ('powershell -noprofile -command ^
    "try { (Invoke-RestMethod -Uri 'https://api.github.com/repos/thedracospark-prog/Shepherd-/releases/latest' -TimeoutSec 15).tag_name } catch { '' }"') do set "GH_VER=%%v"
  if defined GH_VER (
    echo Latest GitHub release: !GH_VER!
    if /i not "!GH_VER!"=="%BUNDLED_VER%" (
      echo Newer release found - downloading...
      powershell -noprofile -command ^
        "Invoke-WebRequest -Uri 'https://github.com/thedracospark-prog/Shepherd-/archive/refs/tags/!GH_VER!.zip' -OutFile '%TEMP%\shepherd-latest.zip'" && (
        set "USE_BUNDLED=0"
        set "USE_VER=!GH_VER!"
      ) || echo Download failed - using bundled copy.
    ) else (
      echo Bundled copy is current.
    )
  ) else (
    echo Offline - using bundled copy.
  )
)

:: ---------- 2. stage source outside OneDrive ----------
if exist "%TARGET%" (
  echo Backing up existing %TARGET% to %TARGET%.bak
  if exist "%TARGET%.bak" rmdir /s /q "%TARGET%.bak"
  move "%TARGET%" "%TARGET%.bak" >nul
)
mkdir "%TARGET%"
if "%USE_BUNDLED%"=="1" (
  echo Copying bundled Shepherd source...
  xcopy "%KIT%\shepherd" "%TARGET%\" /E /I /Q /EXCLUDE:%KIT%\xcopy-exclude.txt
) else (
  echo Extracting downloaded release...
  powershell -noprofile -command "Expand-Archive -Path '%TEMP%\shepherd-latest.zip' -DestinationPath '%TEMP%\shp' -Force"
  for /d %%d in ("%TEMP%\shp\*") do xcopy "%%d" "%TARGET%\" /E /I /Q
)
echo !USE_VER!>"%TARGET%\INSTALLED_VERSION"

:: ---------- 3. flutter ----------
where flutter >nul 2>&1
if errorlevel 1 (
  echo.
  echo Flutter not found. Trying winget install (may need admin)...
  winget install -e --id Flutter.Flutter --silent --accept-source-agreements --accept-package-agreements
  where flutter >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] Could not install Flutter automatically.
    echo Install it once from https://docs.flutter.dev/get-started/install/windows
    echo then re-run this script.
    pause & exit /b 1
  )
)
set "TAR_OPTIONS=--no-same-owner"

:: ---------- 4. build ----------
echo.
echo Building Shepherd for Windows (release)...
cd /d "%TARGET%"
call flutter pub get || (echo [ERROR] flutter pub get failed & pause & exit /b 1)
call flutter build windows --release || (echo [ERROR] build failed & pause & exit /b 1)

:: ---------- 5. install + shortcut ----------
set "APP=%TARGET%\Shepherd-Windows"
if exist "%APP%" rmdir /s /q "%APP%"
mkdir "%APP%"
xcopy "%TARGET%\build\windows\x64\runner\Release" "%APP%\" /E /I /Q
powershell -noprofile -command ^
  "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'),'Shepherd.lnk'));$s.TargetPath='%APP%\shepherd.exe';$s.Save()"

:: ---------- 6. stage automatic node detection ----------
:: Contract for the ESP32Driver (mesh-mode Phase 1): UDP beacons+events
:: on port 49160, mDNS service _shepherd-node._udp. Shepherd reads this
:: file on startup when the driver lands; until then nodes are visible
:: on the network and the app installs cleanly.
(
echo {
echo   "node_discovery": {
echo     "enabled": true,
echo     "udp_port": 49160,
echo     "mdns_service": "_shepherd-node._udp",
echo     "beacon_interval_s": 5
echo   },
echo   "installed_from": "field-kit",
echo   "installed_version": "!USE_VER!"
echo }
) > "%APP%\shepherd_field_kit.json"
echo.
echo Node auto-detection staged: shepherd_field_kit.json written.
echo Full zero-click node pickup activates with the ESP32 driver
echo (mesh-mode Phase 1). Until then, nodes are on the LAN and
echo broadcasting - the app is ready for them.

echo.
echo ============================================================
echo  DONE. Shepherd is at %APP%
echo  Desktop shortcut created. Press any key to launch it now,
echo  or close this window.
echo ============================================================
pause >nul
start "" "%APP%\shepherd.exe"
