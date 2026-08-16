@echo off
title aicc Setup & Configuration Wizard
setlocal
echo ========================================================
echo   aicc — AI Commit & Changelog Automation Setup
echo ========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
endlocal
