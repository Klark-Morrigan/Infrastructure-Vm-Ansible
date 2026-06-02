#!/usr/bin/env bats
# Tests for ops/bootstrap-controller.sh - the WSL-side controller
# bootstrap. The script is mostly a procedural install sequence; only
# the fail-fast presence checks have branching logic worth unit-testing
# in isolation (the install steps themselves are covered end-to-end by
# the step-13 smoke test, not here).
#
# Strategy: run the real script with a curated PATH that contains
# only per-test stubs plus a minimal-bin dir holding the few external
# commands the script needs before its gates fire (just `dirname` at
# present; cd / pwd / command / echo / exit are bash builtins).
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
# Run with: bats Tests/ops/bootstrap-controller.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/ops/bootstrap-controller.sh"

setup() {
    # Capture bash before scrubbing PATH - some bats images (Alpine)
    # do not have bash under /bin or /usr/bin, so the absolute path
    # is the only portable way to invoke the script later.
    BASH_BIN="$(command -v bash)"

    TEST_TMP="$(mktemp -d -t bootstrapCtl.XXXXXX)"
    STUBS="${TEST_TMP}/stubs"
    MINIMAL_BIN="${TEST_TMP}/minimal-bin"
    mkdir -p "${STUBS}" "${MINIMAL_BIN}"

    # Symlink the small set of external commands the script invokes
    # before its presence gates fire. Anything not symlinked here is
    # invisible to the script under test, which is what makes the
    # absent-tool branches fire on CI runners that ship python3/jq
    # pre-installed.
    for cmd in dirname; do
        src="$(command -v "${cmd}")"
        [[ -n "${src}" ]] && ln -sf "${src}" "${MINIMAL_BIN}/${cmd}"
    done

    # SCRIPT_PATH is the PATH passed to the script's subprocess (via
    # env on each `run`). Stubs first so seed_stub overrides win.
    SCRIPT_PATH="${STUBS}:${MINIMAL_BIN}"
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

# run_script - invoke the script under test with the scrubbed PATH.
# `env -i` would strip too much (PATH would survive only because we
# re-pass it, but other vars like HOME, USER may matter to bash); use
# `env PATH=...` which preserves the rest of the environment but
# overrides PATH for the child process only.
run_script() {
    run env "PATH=${SCRIPT_PATH}" "${BASH_BIN}" "${SCRIPT}"
}

@test "exits 1 with the apt-get hint when python3 is missing" {
    # No stubs seeded - python3 is the first gate, fires immediately.
    run_script
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"python3 not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y python3 python3-venv"* ]]
}

@test "exits 1 with the apt-get hint when jq is missing" {
    # python3 present so execution reaches the jq gate.
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
