#!/usr/bin/env bats
# Tests for ops/bootstrap-controller.sh - the WSL-side controller
# bootstrap. The script is mostly a procedural install sequence; only
# the fail-fast presence checks have branching logic worth unit-testing
# in isolation (the install steps themselves are covered end-to-end by
# the step-12 smoke test, not here).
#
# Strategy: run the real script with a synthetic PATH that contains
# only the stubs each test wants present, so the absent-tool branches
# fire deterministically. The script's gate order is python3 -> jq ->
# (venv create -> pip -> ansible-galaxy) -> pwsh.exe; the first two
# gates fail fast before any heavy work and are unit-testable here.
# The pwsh.exe gate sits behind real venv/pip/galaxy operations that
# cannot be cheaply stubbed - that path stays covered by step-12 smoke.
# Run with: bats Tests/ops/bootstrap-controller.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/ops/bootstrap-controller.sh"

setup() {
    # Capture bash before overriding PATH - some bats images (Alpine)
    # do not have bash under /bin or /usr/bin, so the absolute path is
    # the only portable way to invoke the script later.
    BASH_BIN="$(command -v bash)"

    TEST_TMP="$(mktemp -d -t bootstrapCtl.XXXXXX)"
    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"

    # Synthetic PATH with only the per-test stubs. coreutils (cd,
    # dirname, etc.) live in /usr/bin and /bin so the script's own
    # machinery still works; everything else is deliberately absent
    # until a test seeds it via seed_stub.
    export PATH="${STUBS}:/usr/bin:/bin"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

# seed_stub <command> - drops a trivial executable shim onto the
# synthetic PATH so the named command appears present to the script
# under test. Used per-test to advance execution past earlier gates
# and isolate the gate the test actually targets.
seed_stub() {
    local name="$1"
    cat >"${STUBS}/${name}" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${STUBS}/${name}"
}

@test "exits 1 with the apt-get hint when python3 is missing" {
    # No stubs seeded - python3 is the first gate, fires immediately.
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"python3 not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y python3 python3-venv"* ]]
}

@test "exits 1 with the apt-get hint when jq is missing" {
    # python3 present so execution reaches the jq gate.
    seed_stub python3
    run "${BASH_BIN}" "${SCRIPT}"
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
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 1 ]

    if [[ -d "${REPO_ROOT}/.venv" ]]; then
        mtime="$(stat -c %Y "${REPO_ROOT}/.venv" 2>/dev/null || stat -f %m "${REPO_ROOT}/.venv")"
        [ "${mtime}" -lt "${before}" ]
    fi
}

@test "the jq gate fires before any venv work" {
    seed_stub python3
    before="$(date +%s)"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 1 ]

    if [[ -d "${REPO_ROOT}/.venv" ]]; then
        mtime="$(stat -c %Y "${REPO_ROOT}/.venv" 2>/dev/null || stat -f %m "${REPO_ROOT}/.venv")"
        [ "${mtime}" -lt "${before}" ]
    fi
}
