@echo off
setlocal
title Connect Agent Channel to Codex
set "EXIT_CODE=0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-CodexMcp.ps1" %*
if errorlevel 1 goto failed
echo.
choice /c YN /n /m "Apply this Codex MCP registration to the current user? [Y/N] "
if errorlevel 2 goto cancelled
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-CodexMcp.ps1" -Apply %*
if errorlevel 1 goto failed
echo.
echo Registration completed. Restart Codex and verify the channel tools before use.
goto end
:failed
set "EXIT_CODE=1"
echo.
echo Registration was not completed. Review the message above.
goto end
:cancelled
set "EXIT_CODE=0"
echo.
echo No Codex configuration was changed.
:end
pause
exit /b %EXIT_CODE%
