#!/usr/bin/env bats
# Tests for ops/virtual-machines/_build-extra-vars-inventory.sh - per-domain helper
# emitting vm_provisioner_config. Pure transform; jq is the only
# external dep, run for real.
# Run with: bats Tests/ops/_build-extra-vars-inventory.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops/virtual-machines" && pwd)/_build-extra-vars-inventory.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp buildExtraVarsInv
    PROV="${TEST_TMP}/provisioner.json"
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when --provisioner-config is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "fails with file path when the provisioner config is missing" {
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${TEST_TMP}/does-not-exist.json"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not found"* ]]
}

@test "fails when the provisioner config is not valid JSON" {
    printf '%s' 'not-json' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not valid JSON"* ]]
}

@test "valid input emits a single-key object with vm_provisioner_config" {
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 0 ]

    # Helper output is one object with exactly one key; the
    # orchestrator's job is to merge multiple such fragments.
    [ "$(printf '%s' "${output}" | jq -r 'keys | join(",")')" = "vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].ipAddress')" = "10.0.0.1" ]
}
