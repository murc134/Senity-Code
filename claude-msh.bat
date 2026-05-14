@echo off
rem ----------------------------------------------------------------
rem claude-msh.bat - Senity Workspace (Docker Container)
rem ----------------------------------------------------------------
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-msh.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
