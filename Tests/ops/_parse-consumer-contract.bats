#!/usr/bin/env bats
# Tests for ops/_parse-consumer-contract.sh - the consumer contract
# parser. Boundary under test: the CA_* / GH_TOKEN environment in, the
# normalised KEY=value lines (and the exit status) out. The parser
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
    unset CA_INVENTORY_VAULT CA_EXTRA_VAULTS CA_NEEDS_HOST_FILE_SERVER \
          CA_REQUIRES_TOKEN CA_CONSUMER_ROOT GH_TOKEN

    # The inventory vault is the one required field; tests that are not
    # specifically about its absence set it so the rest of the contract is
    # exercised against a valid baseline.
    export CA_INVENTORY_VAULT="VmProvisioner"
}

teardown() {
    _bats_cleanup_temp
}

@test "applies the documented defaults when only the required inventory vault is set" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    # Inventory vault echoed back; no extra vaults (empty value), both
    # toggles off - the "none" default - and no consumer root (the
    # substrate's own root is used downstream).
    [[ "$(grep '^INVENTORY_VAULT=' <<<"${output}")" == "INVENTORY_VAULT=VmProvisioner" ]]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=" ]]
    [[ "$(grep '^NEEDS_HOST_FILE_SERVER=' <<<"${output}")" == "NEEDS_HOST_FILE_SERVER=0" ]]
    [[ "$(grep '^REQUIRES_TOKEN=' <<<"${output}")" == "REQUIRES_TOKEN=0" ]]
    [[ "$(grep '^CONSUMER_ROOT=' <<<"${output}")" == "CONSUMER_ROOT=" ]]
}

@test "passes CA_CONSUMER_ROOT through verbatim when set" {
    # A consumer that owns its playbook/roles/fragment declares where they
    # live; the parser forwards the path unchanged (the bridge, not this
    # pure parser, checks the directory exists).
    export CA_CONSUMER_ROOT="/mnt/c/a_Code/Infrastructure-Vm-Users"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^CONSUMER_ROOT=' <<<"${output}")" == "CONSUMER_ROOT=/mnt/c/a_Code/Infrastructure-Vm-Users" ]]
}

@test "rejects a contract with no inventory vault declared" {
    # CA_INVENTORY_VAULT is the one required field: the bridge always
    # reads an inventory and must name no vault itself, so an absent
    # declaration is rejected before any vault read.
    unset CA_INVENTORY_VAULT
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CA_INVENTORY_VAULT"* ]]
}

@test "echoes a non-default inventory vault name verbatim" {
    # The bridge reads whatever vault the consumer names - the substrate
    # is not pinned to VmProvisioner.
    export CA_INVENTORY_VAULT="FleetVaultX"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^INVENTORY_VAULT=' <<<"${output}")" == "INVENTORY_VAULT=FleetVaultX" ]]
}

@test "parses a single extra vault" {
    export CA_EXTRA_VAULTS="GitHubRunners"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=GitHubRunners" ]]
}

@test "normalises a comma-separated extra-vault list to space-separated" {
    export CA_EXTRA_VAULTS="GitHubRunners,Toolchains"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=GitHubRunners Toolchains" ]]
}

@test "accepts a whitespace-separated extra-vault list" {
    export CA_EXTRA_VAULTS="GitHubRunners Toolchains"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=GitHubRunners Toolchains" ]]
}

@test "drops empty fields from a sloppy separator list" {
    # Repeated and trailing separators must not produce empty vault names.
    export CA_EXTRA_VAULTS="GitHubRunners,,Toolchains,"
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "$(grep '^EXTRA_VAULTS=' <<<"${output}")" == "EXTRA_VAULTS=GitHubRunners Toolchains" ]]
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
