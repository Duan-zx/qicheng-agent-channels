@echo off
setlocal
title Agent Channel - Keep Data Uninstall
set "ARGS=%*"
:scan
if "%~1"=="" goto preview
if /I "%~1"=="-Apply" (
  echo This launcher confirms Apply after preview. Run the .ps1 directly for scripted Apply.
  exit /b 2
)
shift
goto scan
:preview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Qicheng-Lite.ps1" %ARGS%
if errorlevel 1 (
  echo Preview failed. Inspect the error above; no Apply was requested.
  if not defined QICHENG_LITE_NO_PAUSE pause
  exit /b 1
)
choice /c YN /n /m "Apply keep-data uninstall? [Y/N] "
if errorlevel 2 (
  echo Cancelled. No Apply was requested.
  exit /b 0
)
if errorlevel 1 goto apply
echo Confirmation could not be read. No Apply was requested.
exit /b 1
:apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Qicheng-Lite.ps1" -Apply -NonInteractive %ARGS%
set "UNINSTALL_EXIT=%ERRORLEVEL%"
if not "%UNINSTALL_EXIT%"=="0" (
  echo Uninstall did not complete. Review the error and current paths above before retrying.
  if not defined QICHENG_LITE_NO_PAUSE pause
  exit /b %UNINSTALL_EXIT%
)
if not defined QICHENG_LITE_NO_PAUSE pause
