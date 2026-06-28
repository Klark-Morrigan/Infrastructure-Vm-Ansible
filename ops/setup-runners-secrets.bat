@echo off
rem Explorer-double-click launcher for setup-runners-secrets.ps1. The
rem real logic lives in the .ps1 - this just forwards the first dropped
rem argument as -ConfigFile and holds the window so the operator can
rem read the SecretStore init / vault-register output before cmd
rem closes.
rem
rem -SecretSuffix is mandatory on the .ps1 and intentionally not
rem hardcoded here: pwsh prompts for it interactively when omitted,
rem so the operator confirms the target lifecycle (Production,
rem fixture label, etc.) at drop time instead of silently inheriting
rem a default.
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-runners-secrets.ps1" -ConfigFile "%~1"
pause
