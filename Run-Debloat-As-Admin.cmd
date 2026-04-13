@echo off
REM Double-click to open the cleanup menu in an elevated PowerShell window.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Invoke-WindowsDebloat.ps1\"'"
exit /b 0
