@echo off
rem Windows runs this file automatically as SYSTEM at the end of setup (before the
rem first logon). It only chains to the PowerShell script, whose output is logged.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Post-Install.ps1" > C:\Windows\Temp\post-install-console.log 2>&1
