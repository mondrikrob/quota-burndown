@echo off
rem Quota Burndown installer. It does two things, both on the QuotaBurndown.ps1 that
rem sits next to this file (read it first if you like):
rem   1. Unblock-File, so Windows stops treating the downloaded script as untrusted.
rem   2. QuotaBurndown.ps1 -Install, which copies it to %USERPROFILE%\.quota-burndown,
rem      adds a Start menu shortcut and starts the widget.
rem -ExecutionPolicy Bypass applies only to these two PowerShell processes.
setlocal
set "QB_SCRIPT=%~dp0QuotaBurndown.ps1"
set "QB_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%QB_SCRIPT%" (
    echo QuotaBurndown.ps1 was not found next to Install.cmd. Extract the whole zip first.
    pause
    exit /b 1
)
"%QB_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; Unblock-File -LiteralPath $env:QB_SCRIPT"
if errorlevel 1 (
    echo Could not unblock the script. Check file permissions and try again.
    pause
    exit /b 1
)
"%QB_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%QB_SCRIPT%" -Install
set "QB_RESULT=%ERRORLEVEL%"
if not "%QB_RESULT%"=="0" echo Installation failed. Read the error above before trying again.
echo.
pause
exit /b %QB_RESULT%
