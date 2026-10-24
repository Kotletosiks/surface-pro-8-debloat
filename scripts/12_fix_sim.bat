@echo off
setlocal
chcp 65001 >nul
title Debloat wave2 - restore smartcard services for SIM slot

rem Admin check via fltmc: does NOT depend on the Server service (net session does)
fltmc >nul 2>&1
if %errorlevel% neq 0 (
  if /i "%~1"=="ELEVATED" (
    echo Could not obtain administrator rights. Right-click this file and choose "Run as administrator".
    pause
    exit /b 1
  )
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'ELEVATED' -Verb RunAs"
  exit /b
)

set "LOGDIR=%SystemDrive%\Debloat\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%i"
set "CONSOLE=%LOGDIR%\console_simfix_%TS%.log"

if not exist "%~dp0debloat2.ps1" (
  echo debloat2.ps1 not found next to this file.
  pause
  exit /b 1
)

echo Console log: %CONSOLE%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Continue'; & '%~dp0debloat2.ps1' -Step simfix *>&1 | Tee-Object -FilePath '%CONSOLE%'"
set RC=%errorlevel%
echo.>> "%CONSOLE%"
echo Exit code: %RC%>> "%CONSOLE%"
echo.
echo Exit code: %RC%  ^(0 = ok, 2 = some actions failed^)
echo Console log saved: %CONSOLE%
echo Logs folder:       %LOGDIR%
pause
exit /b %RC%
