@echo off
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-auth.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-auth.ps1" %*
)
