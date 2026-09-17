@echo off
setlocal
title Install Qicheng Lite
set "RESULT=%TEMP%\qicheng-lite-install-%RANDOM%-%RANDOM%.json"
set "QICHENG_LITE_RESULT=%RESULT%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Qicheng-Lite.ps1" -PackageRoot "%~dp0." -Apply -NonInteractive -DisableLegacyWindowsChannelsStartup -LaunchAfterInstall %* > "%RESULT%"
set "INSTALL_EXIT=%ERRORLEVEL%"
if exist "%RESULT%" type "%RESULT%"
if not "%INSTALL_EXIT%"=="0" (
  del /q "%RESULT%" >nul 2>nul
  echo.
  echo Installation did not complete. Review the message above, then open QUICKSTART.zh-CN.md.
  if not defined QICHENG_LITE_NO_PAUSE pause
  exit /b 1
)
powershell.exe -NoProfile -Command "$t=Get-Content -LiteralPath $env:QICHENG_LITE_RESULT -Raw; if($t -match '\"status\"\s*:\s*\"installed-start-failed\"'){exit 2}; if($t -match '\"status\"\s*:\s*\"installed\"'){exit 0}; exit 1"
set "STATUS_EXIT=%ERRORLEVEL%"
del /q "%RESULT%" >nul 2>nul
set "QICHENG_LITE_RESULT="
if "%STATUS_EXIT%"=="2" (
  echo.
  echo Qicheng Lite was installed, but its first backend build or health check failed.
  echo Your installation and data were kept. Start Docker, then use the Qicheng Lite shortcut to retry.
  if not defined QICHENG_LITE_NO_PAUSE pause
  exit /b 2
)
if not "%STATUS_EXIT%"=="0" (
  echo.
  echo Installation returned an unexpected status. Review the JSON above.
  if not defined QICHENG_LITE_NO_PAUSE pause
  exit /b 1
)
echo.
echo Qicheng Lite installation finished. The viewer starts in the background by default.
if not defined QICHENG_LITE_NO_PAUSE pause
