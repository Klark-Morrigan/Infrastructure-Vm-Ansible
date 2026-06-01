@echo off
setlocal
rem Explorer-double-click launcher for the bash test runner. The
rem canonical runner is GitHub-Common\scripts\run-tests.bat, which
rem resolves Git Bash and forwards to its own run-tests.sh; we point
rem it at this repo via GHCOMMON_TARGET_REPO so the same single
rem source of truth lints/tests this repo too.
rem
rem GitHub-Common is expected as a sibling checkout under the same
rem parent directory (c:\a_Code\GitHub-Common alongside this repo).

rem pushd/popd resolves the trailing `..` so docker mounts and bash
rem cd targets get an absolute path with no `..` segments.
pushd "%~dp0.."
set "GHCOMMON_TARGET_REPO=%CD%"
popd

call "%GHCOMMON_TARGET_REPO%\..\GitHub-Common\scripts\run-tests.bat" %*
exit /b %errorlevel%
