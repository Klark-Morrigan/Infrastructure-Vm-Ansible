#!/usr/bin/env bats
# Tests for ops/_ensure-apt-command.sh - the sourced presence-or-install
# helper used by ops/bootstrap-controller.sh. Sourced directly here so
# the function can be exercised in isolation without standing up the
# whole bootstrap; the script-level wiring (gate order, which cmd/pkgs
# the script passes) is covered separately by bootstrap-controller.bats.
#
# Strategy: each test runs `ensure_apt_command` in a subshell under a
# scrubbed PATH that contains only per-test stubs, so the function's
# `command -v` lookups see exactly what the test seeds. Subshell
# isolation lets the helper's `exit 1` fail-path be asserted without
# killing the test runner.
# Run with: bats Tests/ops/_ensure-apt-command.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
HELPER="${REPO_ROOT}/ops/_ensure-apt-command.sh"

setup() {
    # Bash absolute path baked into stub shebangs so they resolve under
    # the scrubbed PATH (git-bash on Windows cannot be symlinked into a
    # tmp dir without losing its shared libraries; see the matching
    # comment in bootstrap-controller.bats).
    BASH_BIN="$(command -v bash)"

    TEST_TMP="$(mktemp -d -t ensureAptCmd.XXXXXX)"
    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

# seed_stub <name> [exit_code] - drops a no-op executable stub on PATH
# so `command -v <name>` finds it. Default exit is 0.
seed_stub() {
    local name="$1"
    local rc="${2:-0}"
    cat >"${STUBS}/${name}" <<STUB
#!${BASH_BIN}
exit ${rc}
STUB
    chmod +x "${STUBS}/${name}"
}

# seed_apt_install_stub <exit_code> - drops sudo + apt-get stubs that
# simulate `sudo apt-get install -y <pkgs...>` by dropping a presence
# stub for each requested package into STUBS, so the helper's
# post-install re-check finds the named command on PATH. The exit code
# controls whether the simulated install succeeds.
seed_apt_install_stub() {
    local rc="$1"
    cat >"${STUBS}/apt-get" <<APT
#!${BASH_BIN}
sub="\$1"
shift
if [[ "\$sub" == "install" ]]; then
    while [[ "\$#" -gt 0 && "\$1" == -* ]]; do shift; done
    for pkg in "\$@"; do
        printf '#!%s\nexit 0\n' "${BASH_BIN}" >"${STUBS}/\$pkg"
        chmod +x "${STUBS}/\$pkg"
    done
fi
exit ${rc}
APT
    chmod +x "${STUBS}/apt-get"

    cat >"${STUBS}/sudo" <<SUDO
#!${BASH_BIN}
exec "\$@"
SUDO
    chmod +x "${STUBS}/sudo"
}

# run_ensure <cmd> <pkg> [pkg...] - source the helper inside a
# scrubbed-PATH subshell and call ensure_apt_command. Subshell so the
# helper's `exit 1` does not kill bats.
run_ensure() {
    run env "PATH=${STUBS}" "${BASH_BIN}" -c \
        "source '${HELPER}'; ensure_apt_command \"\$@\"" _ "$@"
}

@test "no-op when the command is already on PATH" {
    seed_stub python3
    run_ensure python3 python3 python3-venv
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "exits 1 with the apt-get hint when sudo is absent" {
    # Neither cmd nor sudo on PATH; helper cannot attempt the install.
    run_ensure python3 python3 python3-venv
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"python3 not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y python3 python3-venv"* ]]
}

@test "exits 1 with the apt-get hint when apt-get is absent" {
    # sudo present but apt-get is not (e.g. a non-Debian distro).
    seed_stub sudo
    run_ensure jq jq
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"jq not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y jq"* ]]
}

@test "installs and returns 0 when the apt-get install succeeds" {
    # apt-get install drops a stub for the requested cmd onto PATH; the
    # helper's post-install re-check should find it and return.
    seed_apt_install_stub 0
    run_ensure python3 python3 python3-venv
    [ "${status}" -eq 0 ]
}

@test "exits 1 with the apt-get hint when the install itself fails" {
    # apt-get present but exits non-zero (apt lock, offline, etc).
    seed_apt_install_stub 1
    run_ensure python3 python3 python3-venv
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"python3 not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y python3 python3-venv"* ]]
}

@test "hint lists every requested package when multiple are passed" {
    # Regression guard for the array-expansion in the hint message; a
    # single-package call must not be the only shape exercised.
    run_ensure mything pkg-a pkg-b pkg-c
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"sudo apt-get install -y pkg-a pkg-b pkg-c"* ]]
}
