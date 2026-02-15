@echo off
setlocal
set "_ARGS="
:loop
if "%~1"=="" goto run
if /I "%~1"=="--full" (
  set "_ARGS=%_ARGS% -Full"
) else (
  set "_ARGS=%_ARGS% %~1"
)
shift
goto loop

:run
where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset.ps1" %_ARGS%
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset.ps1" %_ARGS%
)
