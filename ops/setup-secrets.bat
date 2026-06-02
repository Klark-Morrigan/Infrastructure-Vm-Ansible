@echo off
rem Explorer-double-click launcher for setup-secrets.ps1. The real
rem logic lives in the .ps1 - this just forwards the first dropped
rem argument as -ConfigFile and holds the window so the operator can
rem read the SecretStore init / vault-register output before cmd
rem closes. Mirrors Infrastructure-E2E/agent/setup-secrets.bat.
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-secrets.ps1" -ConfigFile "%~1"
pause
