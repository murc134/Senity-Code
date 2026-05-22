@echo off
chcp 65001 >nul 2>&1
rem ════════════════════════════════════════════════════════════
rem claude-senity.bat — Senity Workspace (Docker Container)
rem ════════════════════════════════════════════════════════════
setlocal EnableDelayedExpansion

echo.
echo   ╔══════════════════════════════════════════╗
echo   ║   Senity Workspace  —  Launcher (bat)   ║
echo   ╚══════════════════════════════════════════╝
echo.

rem ── [1/4] PowerShell 7 suchen ──────────────────────────────
echo   [1/4] PowerShell 7 (pwsh) suchen...

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

if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" (
    set "PWSH_BIN=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
    goto :found_pwsh
)

echo   [WARN] PowerShell 7 nicht gefunden. Installationsversuch...
echo.

where winget >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    echo   [INFO] Installiere PowerShell 7 via winget...
    winget install --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
    if exist "C:\Program Files\PowerShell\7\pwsh.exe" (
        set "PWSH_BIN=C:\Program Files\PowerShell\7\pwsh.exe"
        goto :found_pwsh
    )
    echo   [WARN] winget-Installation abgeschlossen, pwsh aber nicht gefunden.
) else (
    echo   [WARN] winget nicht verfuegbar.
)

echo   [INFO] Versuche PowerShell 7 MSI herunterzuladen (~100 MB)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$p=Join-Path $env:TEMP 'PS7Setup.msi'; $ProgressPreference='SilentlyContinue'; ^
     Invoke-WebRequest -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi' ^
     -OutFile $p -UseBasicParsing; ^
     Start-Process msiexec.exe -ArgumentList '/i',$p,'/quiet','/norestart' -Verb RunAs -Wait; ^
     Write-Host 'MSI-Installation abgeschlossen'"

if exist "C:\Program Files\PowerShell\7\pwsh.exe" (
    set "PWSH_BIN=C:\Program Files\PowerShell\7\pwsh.exe"
    goto :found_pwsh
)

echo.
echo   [FAIL] PowerShell 7 konnte nicht installiert werden.
echo   [INFO] Bitte manuell installieren:
echo          https://github.com/PowerShell/PowerShell/releases
echo          oder: winget install Microsoft.PowerShell
echo.
pause
exit /b 1

:found_pwsh
echo   [OK]   PowerShell 7: %PWSH_BIN%

rem ── [2/4] Docker-CLI pruefen ────────────────────────────────
echo   [2/4] Docker-CLI pruefen...
where docker >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    for /f "usebackq tokens=*" %%v in (`docker --version 2^>^&1`) do (
        echo   [OK]   %%v
    )
) else (
    echo   [WARN] Docker nicht im PATH (bitte Docker Desktop installieren: winget install Docker.DockerDesktop)
)

rem ── [3/4] git pruefen (das Repo-Setup im Launcher braucht git) ──
echo   [3/4] git pruefen...
where git >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    for /f "usebackq tokens=*" %%g in (`git --version 2^>^&1`) do (
        echo   [OK]   %%g
    )
) else (
    echo   [WARN] git nicht gefunden. Installationsversuch via winget...
    where winget >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements
    ) else (
        echo   [WARN] winget nicht verfuegbar - git manuell installieren: https://git-scm.com/download/win
    )
)

rem ── [4/4] PowerShell-Script starten ────────────────────────
echo   [4/4] Starte claude-senity.ps1...
echo.

rem Stderr mit in Stdout leiten, damit Fehler sichtbar sind
rem DisableDelayedExpansion schuetzt %* vor !-Zeicheninterpretation
setlocal DisableDelayedExpansion
"%PWSH_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-senity.ps1" %* 2>&1
set "EXITCODE=%ERRORLEVEL%"
endlocal & set "EXITCODE=%EXITCODE%"

echo.
if %EXITCODE% EQU 0 (
    echo   [OK]   Senity Workspace beendet (Exit 0)
) else if %EXITCODE% EQU 130 (
    echo   [OK]   Beendet durch Ctrl+C
) else (
    echo   [FAIL] Script beendet mit Exit-Code: %EXITCODE%
    echo   [INFO] Bitte Ausgabe oben auf Fehlermeldungen pruefen.
    echo.
    echo   Druecke eine Taste zum Schliessen...
    pause >nul
)

endlocal & exit /b %EXITCODE%
