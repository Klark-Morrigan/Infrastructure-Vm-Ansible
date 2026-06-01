@echo off
setlocal
rem Explorer-double-click launcher for scripts/fix-permissions.sh
rem (this repo's local entry). The local .sh transitively exec's
rem GitHub-Common's canonical fix engine with GHCOMMON_TARGET_REPO
rem set, so the chain is local.bat -> local.sh -> shared engine - one
rem entry point per layer, no shortcutting.
rem
rem _find-bash.bat from GitHub-Common resolves Git Bash robustly and
rem sets %BASH%; reused rather than duplicated.
rem
rem GitHub-Common is expected as a sibling checkout under the same
rem parent directory.

call "%~dp0..\..\GitHub-Common\scripts\_find-bash.bat" || exit /b 1

set GHCOMMON_NO_PAUSE=1
"%BASH%" "%~dp0fix-permissions.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
