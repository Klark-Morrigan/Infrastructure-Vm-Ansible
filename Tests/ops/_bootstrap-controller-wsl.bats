#!/usr/bin/env bats
# Tests for ops/_bootstrap-controller-wsl.sh - the WSL-side controller
# bootstrap. The script is mostly a procedural install sequence; only
# the fail-fast presence checks have branching logic worth unit-testing
# in isolation (the install steps themselves are covered end-to-end by
# the step-13 smoke test, not here).
#
# Strategy: run the real script with a curated PATH that contains only
# per-test stubs. The script anchors paths via bash parameter expansion
# and uses only builtins (command, cd, pwd, source) before its presence
# gates fire, so no external bin dir needs to be on the script's PATH.
# Crucially, /usr/bin and /bin are NOT on that PATH, because on
# ubuntu-latest CI runners /usr/bin/python3 and /usr/bin/jq exist and
# would let the gates fall through. The test harness itself keeps its
# own PATH (for find / stat / date used in assertions); only the
# script's subprocess gets the scrubbed PATH, applied via `env` on
# each `run`.
#
# The script's gate order is python3 -> jq -> (venv create -> pip ->
# ansible-galaxy) -> pwsh.exe; the first two gates fail fast before
# any heavy work and are unit-testable here. The pwsh.exe gate sits
# behind real venv/pip/galaxy operations that cannot be cheaply
# stubbed - that path stays covered by step-13 smoke.
# Run with: bats Tests/ops/_bootstrap-controller-wsl.bats

# `run -<status>` flags require bats >= 1.5; declaring the floor here
# converts the BW02 warning into a hard requirement check at load time.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/ops/_bootstrap-controller-wsl.sh"

setup() {
    # Capture bash before scrubbing PATH - some bats images (Alpine)
    # do not have bash under /bin or /usr/bin, so the absolute path
    # is the only portable way to invoke the script later.
    BASH_BIN="$(command -v bash)"
    # Capture chmod the same way: the apt-get stub runs with the
    # script's scrubbed PATH (only STUBS), so it cannot resolve
    # `chmod` from the harness PATH. Without the absolute path the
    # post-install package stubs would end up non-executable - and
    # on Linux that turns the expected exit 127 into a 126
    # (Permission denied), which broke this test in CI when only
    # Windows git-bash had been used locally.
    CHMOD_BIN="$(command -v chmod)"

    TEST_TMP="$(mktemp -d -t bootstrapCtl.XXXXXX)"
    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"

    # SCRIPT_PATH is the PATH passed to the script's subprocess (via
    # env on each `run`). The script itself anchors paths via bash
    # parameter expansion and uses only builtins (command, cd, pwd,
    # source) before its presence gates fire, so no external bin dir
    # needs to be on this PATH for the gates to be reached; stubs are
    # the only thing here.
    SCRIPT_PATH="${STUBS}"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

# seed_stub <command> - drops a trivial executable shim into STUBS
# so the named command appears present to the script under test.
# Used per-test to advance execution past earlier gates and isolate
# the gate the test actually targets.
seed_stub() {
    local name="$1"
    cat >"${STUBS}/${name}" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${STUBS}/${name}"
}

# seed_apt_install_stub <exit_code> - drops sudo + apt-get stubs that
# simulate a `sudo apt-get install -y <pkgs...>` call. On the install
# subcommand each named package is dropped as an executable stub into
# STUBS, so the script's post-install presence re-check finds it on
# PATH. The exit code argument controls whether the simulated install
# itself succeeds, exercising the install-or-hint fallback shape.
seed_apt_install_stub() {
    local rc="$1"
    # Stubs hard-code the absolute path to bash captured during setup
    # so they do not depend on `env` or `bash` being on the scrubbed
    # PATH the script under test runs with. On Windows git-bash the
    # bash binary cannot be symlinked into a tmp dir (it would lose
    # access to its msys2 shared libraries), so the only portable
    # option is an absolute-path shebang.
    cat >"${STUBS}/apt-get" <<APT
#!${BASH_BIN}
# subcommand is the first positional arg (sudo strips its own flags
# before exec). 'update' is a no-op with the configured rc; 'install'
# additionally materialises the requested package stubs so the script
# under test's post-install presence re-check finds them on PATH.
sub="\$1"
shift
if [[ "\$sub" == "install" ]]; then
    while [[ "\$#" -gt 0 && "\$1" == -* ]]; do shift; done
    for pkg in "\$@"; do
        printf '#!%s\nexit 0\n' "${BASH_BIN}" >"${STUBS}/\$pkg"
        "${CHMOD_BIN}" +x "${STUBS}/\$pkg"
    done
fi
exit ${rc}
APT
    chmod +x "${STUBS}/apt-get"

    cat >"${STUBS}/sudo" <<SUDO
#!${BASH_BIN}
# Pass-through: drop the sudo invocation and exec the rest so the
# apt-get stub above is what actually runs.
exec "\$@"
SUDO
    chmod +x "${STUBS}/sudo"
}

# run_script - invoke the script under test with the scrubbed PATH.
# `env -i` would strip too much (PATH would survive only because we
# re-pass it, but other vars like HOME, USER may matter to bash); use
# `env PATH=...` which preserves the rest of the environment but
# overrides PATH for the child process only.
run_script() {
    run env "PATH=${SCRIPT_PATH}" "${BASH_BIN}" "${SCRIPT}"
}

@test "passes python3 + python3-venv to ensure_apt_command and reaches the next gate" {
    # The helper internals are covered by _ensure-apt-command.bats; this
    # is a wiring check - simulate a successful python3 install and
    # assert execution carries on past the python3 gate. With jq also on
    # the install-or-hint path, a single seed_apt_install_stub 0 carries
    # both python3 and jq past their gates, so the next failure point is
    # whatever lies past the jq gate (venv work; not asserted here). The
    # python3 hint must NOT appear (it would mean the script swapped the
    # helper out or passed wrong args).
    seed_apt_install_stub 0
    run -127 env "PATH=${SCRIPT_PATH}" "${BASH_BIN}" "${SCRIPT}"
    # Status 127 is the expected downstream failure once both gates pass:
    # the apt stub drops a `python3` shim that exits 0, so venv "creation"
    # produces no .venv, and the script then tries to run a non-existent
    # `$venv_dir/bin/pip`. That is past the gates this test cares about.
    [[ "${output}" != *"python3 not found in WSL"* ]]
    [[ "${output}" != *"jq not found in WSL"* ]]
}

@test "passes jq to ensure_apt_command and the jq install branch succeeds" {
    # Wiring check for the jq gate: python3 is pre-seeded so execution
    # reaches jq, then the apt stub materialises jq on PATH. Neither the
    # python3 nor the jq hint should appear. See the python3-gate test
    # above for why status 127 is the expected post-gate failure mode.
    seed_stub python3
    seed_apt_install_stub 0
    run -127 env "PATH=${SCRIPT_PATH}" "${BASH_BIN}" "${SCRIPT}"
    [[ "${output}" != *"jq not found in WSL"* ]]
}

@test "exits 1 with the apt-get hint when jq is missing and apt install fails" {
    # python3 pre-seeded so the python3 gate passes; sudo + apt-get are
    # absent from PATH, so the jq install branch cannot run and the
    # helper falls through to the fix-it hint.
    seed_stub python3
    run_script
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"jq not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y jq"* ]]
}

@test "the python3 gate fires before any venv work" {
    # If a gate did not fail-fast the script would try to create .venv/
    # under repo root. Asserting the directory mtime did not advance
    # past the run start is a clean proxy for "execution stopped at
    # the gate"; a pre-existing .venv from a real bootstrap still
    # passes the check because its mtime predates the test.
    before="$(date +%s)"
    run_script
    [ "${status}" -eq 1 ]

    if [[ -d "${REPO_ROOT}/.venv" ]]; then
        mtime="$(stat -c %Y "${REPO_ROOT}/.venv" 2>/dev/null || stat -f %m "${REPO_ROOT}/.venv")"
        [ "${mtime}" -lt "${before}" ]
    fi
}

@test "the jq gate fires before any venv work" {
    seed_stub python3
    before="$(date +%s)"
    run_script
    [ "${status}" -eq 1 ]

    if [[ -d "${REPO_ROOT}/.venv" ]]; then
        mtime="$(stat -c %Y "${REPO_ROOT}/.venv" 2>/dev/null || stat -f %m "${REPO_ROOT}/.venv")"
        [ "${mtime}" -lt "${before}" ]
    fi
}
