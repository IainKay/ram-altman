@echo off
setlocal
title RAM Altman for Windows

set "SCRIPT=%~dp0ram-altman.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: ram-altman.ps1 was not found beside this launcher.
    echo Keep ram-altman.bat and ram-altman.ps1 in the same folder.
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

exit /b %ERRORLEVEL%
