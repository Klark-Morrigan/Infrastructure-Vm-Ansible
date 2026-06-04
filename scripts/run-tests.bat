@echo off
setlocal
rem Explorer-double-click launcher for scripts/run-tests.sh (this
rem repo's local entry). The local .sh transitively exec's
rem GitHub-Common's canonical runner with GHCOMMON_TARGET_REPO set, so
rem the chain is local.bat -> local.sh -> shared engine - one entry
rem point per layer, no shortcutting.
rem
rem _find-bash.bat from GitHub-Common resolves Git Bash robustly and
rem sets %BASH%; reused rather than duplicated.
rem
rem GitHub-Common is expected as a sibling checkout under the same
rem parent directory (c:\a_Code\GitHub-Common alongside this repo).

call "%~dp0..\..\GitHub-Common\scripts\_find-bash.bat" || exit /b 1

rem GHCOMMON_NO_PAUSE silences the shared engine's EXIT trap pause;
rem this .bat holds the window itself with the `pause` below so
rem Explorer-click users can read the output.
set GHCOMMON_NO_PAUSE=1
"%BASH%" "%~dp0run-tests.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
