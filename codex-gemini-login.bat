@echo off
chcp 65001 >nul 2>&1
rem ════════════════════════════════════════════════════════════
rem codex-gemini-login.bat — Codex / Gemini CLI-Login (Senity)
rem Bootstrappt PowerShell 7 und startet codex-gemini-login.ps1
rem ════════════════════════════════════════════════════════════
setlocal EnableDelayedExpansion

echo.
echo   Codex / Gemini - CLI-Login (Senity)
echo.

set "PWSH_BIN="
where pwsh >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    for /f "usebackq tokens=*" %%i in (`where pwsh 2^>nul`) do (
        set "PWSH_BIN=%%i"
        goto :found_pwsh
    )
)
if exist "C:\Program Files\PowerShell\7\pwsh.exe" (
    set "PWSH_BIN=C:\Program Files\PowerShell\7\pwsh.exe"
    goto :found_pwsh
)

echo   [FAIL] PowerShell 7 (pwsh) nicht gefunden.
echo   [INFO] Bitte einmal claude-senity.bat ausfuehren (installiert pwsh)
echo          oder manuell: winget install Microsoft.PowerShell
echo.
pause
exit /b 1

:found_pwsh
echo   [OK]   PowerShell 7: %PWSH_BIN%
echo.

setlocal DisableDelayedExpansion
"%PWSH_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-gemini-login.ps1" %* 2>&1
set "EXITCODE=%ERRORLEVEL%"
endlocal & set "EXITCODE=%EXITCODE%"

echo.
if not %EXITCODE% EQU 0 (
    echo   [FAIL] Beendet mit Exit-Code: %EXITCODE%
    echo   Druecke eine Taste zum Schliessen...
    pause >nul
)
endlocal & exit /b %EXITCODE%
