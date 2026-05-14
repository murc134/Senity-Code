@echo off
echo =====================================
echo Senity Workspace - Setup
echo =====================================
echo.

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %ERRORLEVEL%
