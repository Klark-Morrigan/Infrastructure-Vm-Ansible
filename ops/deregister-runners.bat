@echo off
setlocal
rem Explorer-double-click launcher for ops/deregister-runners.sh. Same
rem Git-Bash-find pattern as register-runners.bat; the .sh is the real
rem entry. Any args (notably --force) pass through verbatim.

call "%~dp0..\..\Common-Automation\scripts\_find-bash.bat" || exit /b 1

"%BASH%" "%~dp0deregister-runners.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
