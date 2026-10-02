@echo off
rem Quota Burndown installer. It does two things, both on the QuotaBurndown.ps1 that
rem sits next to this file (read it first if you like):
rem   1. Unblock-File, so Windows stops treating the downloaded script as untrusted.
rem   2. QuotaBurndown.ps1 -Install, which copies it to %USERPROFILE%\.quota-burndown,
rem      adds a Start menu shortcut and starts the widget.
rem -ExecutionPolicy Bypass applies only to these two PowerShell processes.
setlocal
set "QB_SCRIPT=%~dp0QuotaBurndown.ps1"
if not exist "%QB_SCRIPT%" (
    echo QuotaBurndown.ps1 was not found next to Install.cmd. Extract the whole zip first.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath $env:QB_SCRIPT"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%QB_SCRIPT%" -Install
echo.
pause
