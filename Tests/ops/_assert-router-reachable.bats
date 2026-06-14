#!/usr/bin/env bats
# Tests for ops/_assert-router-reachable.sh - the router reachability
# pre-flight probe. Scope: the helper's nc/ssh boundary. nc and ssh are
# replaced with stubs whose exit code (nc) and stdout banner (ssh) are
# driven per test, so the segment classification (TCP vs banner vs OK)
# is asserted without a real router.
# Run with: bats Tests/ops/_assert-router-reachable.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
PROBE="${REPO_ROOT}/ops/_assert-router-reachable.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp assertRouterReachable
    mkdir -p "${TEST_TMP}/stubs"

    # nc stub: exit code is the only signal the probe reads (-z scan).
    # Default reachable; override per test with NC_STUB_EXIT.
    cat >"${TEST_TMP}/stubs/nc" <<'STUB'
#!/usr/bin/env bash
exit "${NC_STUB_EXIT:-0}"
STUB

    # ssh stub: prints the banner the probe classifies. Default is a
    # healthy "Permission denied" (auth stage reached); override with
    # SSH_STUB_BANNER to simulate a banner-exchange failure.
    cat >"${TEST_TMP}/stubs/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${SSH_STUB_BANNER:-sshprobe@router: Permission denied (publickey,password).}"
exit 0
STUB

    chmod +x "${TEST_TMP}/stubs/nc" "${TEST_TMP}/stubs/ssh"
    export PATH="${TEST_TMP}/stubs:${PATH}"
}

teardown() {
    _bats_cleanup_temp
}

@test "exits non-zero when the router IP argument is missing" {
    run "${BASH_BIN}" "${PROBE}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"router IP required"* ]]
}

@test "reachable: TCP open and a healthy banner exits 0" {
    run "${BASH_BIN}" "${PROBE}" 192.168.1.5 2222
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"router reachable"* ]]
    [[ "${output}" == *"192.168.1.5:2222"* ]]
}

@test "a Permission-denied banner counts as reachable (auth is not exercised)" {
    SSH_STUB_BANNER="sshprobe@router: Permission denied (publickey)." \
        run "${BASH_BIN}" "${PROBE}" 192.168.1.5 2222
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"router reachable"* ]]
}

@test "TCP connect failure is reported as ROUTER UNREACHABLE and exits 1" {
    NC_STUB_EXIT=1 run "${BASH_BIN}" "${PROBE}" 192.168.1.5 2222
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"ROUTER UNREACHABLE"* ]]
}

@test "TCP open but a banner-exchange timeout is reported as SSH BANNER FAILED and exits 1" {
    SSH_STUB_BANNER="ssh: connect to host 192.168.1.5 port 2222: Connection timed out during banner exchange" \
        run "${BASH_BIN}" "${PROBE}" 192.168.1.5 2222
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"SSH BANNER FAILED"* ]]
}

@test "defaults to port 22 when no port argument is given" {
    run "${BASH_BIN}" "${PROBE}" 192.168.1.5
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"192.168.1.5:22"* ]]
}
