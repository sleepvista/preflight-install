@echo off
rem Double-click launcher for install.ps1. Open this file in Notepad to read it.
rem -ExecutionPolicy Bypass applies to this one run only; it changes no setting
rem on your computer. It does not remove Windows download warnings (INSTALL.md
rem says how to avoid those). Unblock-File clears a download mark on the files
rem this installer needs, if there is one.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Where-Object { $_.Name -in 'install.ps1','docker-compose.yml','.env.example' } | Unblock-File -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
pause
exit /b %EXITCODE%
