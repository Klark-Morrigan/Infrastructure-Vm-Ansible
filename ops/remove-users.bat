@echo off
setlocal
rem Explorer-double-click launcher for ops/remove-users.sh. Mirror of
rem create-users.bat: the .sh is the real entry; this .bat exists so an
rem operator can run the remove-users flow without first opening a WSL
rem terminal.
rem
rem _find-bash.bat from Common-Automation locates Git Bash robustly and
rem sets %BASH%; reused rather than reimplemented (the lookup probes
rem several install layouts and has its own rationale comments).
rem Common-Automation is expected as a sibling checkout under the same
rem parent directory as this repo - same convention used by
rem scripts/run-tests.bat.
rem
rem We hold the window open here with `pause` so Explorer-click users
rem can read the play recap; the .sh itself stays quiet on exit.

call "%~dp0..\..\Common-Automation\scripts\_find-bash.bat" || exit /b 1

"%BASH%" "%~dp0remove-users.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
