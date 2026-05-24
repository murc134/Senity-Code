@echo off
REM senity-start.bat - cmd.exe-Shim, der nach pwsh / powershell delegiert.
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%senity-start.ps1"

where pwsh >nul 2>&1
if %ERRORLEVEL% equ 0 (
    pwsh -NoLogo -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

where powershell >nul 2>&1
if %ERRORLEVEL% equ 0 (
    powershell -NoLogo -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

echo [senity-start] Weder pwsh noch powershell gefunden. 1>&2
exit /b 1
