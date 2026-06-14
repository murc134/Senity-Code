@echo off
where pwsh >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoLogo -ExecutionPolicy Bypass -File "%~dp0senity.ps1" %*
) else (
    pwsh -NoLogo -ExecutionPolicy Bypass -File "%~dp0senity.ps1" %*
)
