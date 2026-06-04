@echo off
setlocal
rem Explorer-double-click launcher for ops/create-users.sh. The .sh is
rem the real entry; this .bat exists so an operator can run the
rem create-users flow without first opening a WSL terminal.
rem
rem _find-bash.bat from GitHub-Common locates Git Bash robustly and
rem sets %BASH%; reused rather than reimplemented (the lookup probes
rem several install layouts and has its own rationale comments).
rem GitHub-Common is expected as a sibling checkout under the same
rem parent directory as this repo - same convention used by
rem scripts/run-tests.bat.
rem
rem We hold the window open here with `pause` so Explorer-click users
rem can read the play recap; the .sh itself stays quiet on exit.

call "%~dp0..\..\GitHub-Common\scripts\_find-bash.bat" || exit /b 1

"%BASH%" "%~dp0create-users.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
