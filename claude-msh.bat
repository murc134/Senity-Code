@echo off
rem ----------------------------------------------------------------
rem claude-msh.bat - Wrapper, leitet alle Argumente an claude-msh.ps1
rem ----------------------------------------------------------------
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-msh.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
