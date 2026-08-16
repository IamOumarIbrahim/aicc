@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0aicc.ps1" %*
endlocal
