@echo off
setlocal
title Install Qicheng Windows Channels
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WindowsChannels.ps1" -Apply -LaunchAfterInstall
if errorlevel 1 (
  echo.
  echo Installation failed. Review the message above, then see QUICKSTART.zh-CN.md.
  pause
  exit /b 1
)
echo.
echo Installation completed. First-time setup or the configured workspace has been opened.
pause
