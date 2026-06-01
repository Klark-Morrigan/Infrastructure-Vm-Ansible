#!/usr/bin/env bats
# Tests for ops/bootstrap-controller.sh - the WSL-side controller
# bootstrap. The script is mostly a procedural install sequence; only
# the fail-fast presence checks have branching logic worth unit-testing
# in isolation (the install steps themselves are covered end-to-end by
# the step-12 smoke test, not here).
#
# Strategy: run the real script with a synthetic PATH that contains
# only the stubs we want present, so the absent-tool branches fire.
# python3 is stubbed as present so the test reaches the jq gate without
# erroring on the earlier python3 gate.
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

    # python3 stub - present so the python3 gate passes and execution
    # advances to the jq gate. No behaviour needed beyond a clean exit
    # since the test stops at the jq check.
    cat >"${STUBS}/python3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${STUBS}/python3"

    # Synthetic PATH with only the stubs. coreutils (cd, dirname, echo)
    # live in /usr/bin and /bin so the script's own machinery still
    # works; everything else - jq included - is deliberately absent.
    export PATH="${STUBS}:/usr/bin:/bin"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

@test "exits 1 with the apt-get hint when jq is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"jq not found in WSL"* ]]
    [[ "${output}" == *"sudo apt-get install -y jq"* ]]
}

@test "the jq gate fires before any venv work" {
    # If the gate did not fail-fast the script would try to create
    # .venv/ under repo root. Asserting the directory was not created
    # by this run is a clean proxy for "execution stopped at the gate".
    # Use a sentinel marker to distinguish from a pre-existing .venv:
    # check mtime delta rather than presence, since a real .venv lives
    # in the repo root.
    before="$(date +%s)"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 1 ]

    if [[ -d "${REPO_ROOT}/.venv" ]]; then
        mtime="$(stat -c %Y "${REPO_ROOT}/.venv" 2>/dev/null || stat -f %m "${REPO_ROOT}/.venv")"
        [ "${mtime}" -lt "${before}" ]
    fi
}
