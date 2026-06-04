@echo off
rem Explorer-double-click launcher for the controller bootstrap. The
rem real logic lives in bootstrap-controller.ps1 - this just invokes
rem pwsh against it with the policy bypass needed for unsigned local
rem scripts and holds the window open so the operator can read the
rem WSL-install or reboot-required message before the cmd window
rem closes.
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-controller.ps1" %*
pause
