@echo off
rem Launches IP Check without a console window.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0IPCheck.ps1" %*
