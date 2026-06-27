#!/usr/bin/env bats
# Tests for ops/_parse-consumer-contract.sh - the consumer contract
# parser. Boundary under test: the CA_* / GH_TOKEN environment in, the
# three normalised KEY=value lines (and the exit status) out. The parser
# has no external process dependency - it only sources the shared logger -
# so the suite drives it purely through the environment, with no PATH
# stubbing beyond the COMMON_AUTOMATION_ROOT logger stub _bats_init_temp
# stands up.
# Run with: bats Tests/ops/_parse-consumer-contract.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_parse-consumer-contract.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp parseContract

    # Start every test from a clean contract environment so a value the
    # harness happens to export (e.g. a real GH_TOKEN) cannot mask a
    # default-or-reject assertion.
    unset CA_EXTRA_VAULTS CA_NEEDS_HOST_FILE_SERVER CA_REQUIRES_TOKEN GH_TOKEN
}

teardown() {
    _bats_cleanup_temp
}

@test "applies the documented defaults when no contract variable is set" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    # No extra vaults (empty value), both toggles off - the "none" default.
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=" ]]
    [[ "$(grep '^NEEDS_HOST_FILE_SERVER=' <<<"${output}")" == "NEEDS_HOST_FILE_SERVER=0" ]]
    [[ "$(grep '^REQUIRES_TOKEN=' <<<"${output}")" == "REQUIRES_TOKEN=0" ]]
}

@test "parses a single extra vault" {
    export CA_EXTRA_VAULTS="VmUsers"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=VmUsers" ]]
}

@test "normalises a comma-separated extra-vault list to space-separated" {
    export CA_EXTRA_VAULTS="VmUsers,GitHubRunners"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=VmUsers GitHubRunners" ]]
}

@test "accepts a whitespace-separated extra-vault list" {
    export CA_EXTRA_VAULTS="VmUsers GitHubRunners"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=VmUsers GitHubRunners" ]]
}

@test "drops empty fields from a sloppy separator list" {
    # Repeated and trailing separators must not produce empty vault names.
    export CA_EXTRA_VAULTS="VmUsers,,GitHubRunners,"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=VmUsers GitHubRunners" ]]
}

@test "parses CA_NEEDS_HOST_FILE_SERVER=1 as on" {
    export CA_NEEDS_HOST_FILE_SERVER=1
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^NEEDS_HOST_FILE_SERVER=' <<<"${output}")" == "NEEDS_HOST_FILE_SERVER=1" ]]
}

@test "treats any non-1 CA_NEEDS_HOST_FILE_SERVER value as off" {
    # A typo or a truthy-looking string must fail safe to the default.
    export CA_NEEDS_HOST_FILE_SERVER=true
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^NEEDS_HOST_FILE_SERVER=' <<<"${output}")" == "NEEDS_HOST_FILE_SERVER=0" ]]
}

@test "parses CA_REQUIRES_TOKEN=1 as on when GH_TOKEN is present" {
    export CA_REQUIRES_TOKEN=1
    export GH_TOKEN="ghp_example"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^REQUIRES_TOKEN=' <<<"${output}")" == "REQUIRES_TOKEN=1" ]]
}

@test "rejects the inconsistent combination of a required token with none supplied" {
    # The one inconsistency the contract can express: declared-but-absent
    # token. Must fail (exit 2) with a message naming GH_TOKEN, before any
    # downstream consumer is handed an empty token.
    export CA_REQUIRES_TOKEN=1
    unset GH_TOKEN
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"GH_TOKEN"* ]]
}

@test "does not require a token when CA_REQUIRES_TOKEN is unset even with no GH_TOKEN" {
    # The token check is gated entirely by the declared requirement: a
    # consumer that never asks for a token must parse cleanly without one.
    unset CA_REQUIRES_TOKEN GH_TOKEN
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^REQUIRES_TOKEN=' <<<"${output}")" == "REQUIRES_TOKEN=0" ]]
}
