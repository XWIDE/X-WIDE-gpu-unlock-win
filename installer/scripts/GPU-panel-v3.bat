@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0gpu-panel-v3.ps1"
if errorlevel 1 pause
