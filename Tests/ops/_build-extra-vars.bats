#!/usr/bin/env bats
# Tests for ops/_build-extra-vars.sh - the pure transform that
# wraps the two vault payloads under their canonical top-level keys.
# No stubs needed; the script's only external dep is jq, run for
# real. Inputs are file paths (not stdin) so secrets stay off argv.
# Run with: bats Tests/ops/_build-extra-vars.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-extra-vars.sh"

setup() {
    BASH_BIN="$(command -v bash)"
    TEST_TMP="$(mktemp -d -t buildExtraVars.XXXXXX)"
    PROV="${TEST_TMP}/provisioner.json"
    USERS="${TEST_TMP}/users.json"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

@test "fails with usage when either flag is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" --users-config "${USERS}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "fails with provisioner-config file path when that file is missing" {
    printf '%s' '[]' > "${USERS}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${TEST_TMP}/does-not-exist.json" \
        --users-config "${USERS}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not found"* ]]
}

@test "fails with users-config file path when that file is missing" {
    printf '%s' '[]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${TEST_TMP}/does-not-exist.json"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"users-config"* ]]
    [[ "${output}" == *"not found"* ]]
}

@test "fails with the offending file labelled when it is not valid JSON" {
    printf '%s' 'not-json' > "${PROV}"
    printf '%s' '[]'       > "${USERS}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${USERS}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not valid JSON"* ]]
}

@test "valid inputs produce the canonical extra-vars shape" {
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    printf '%s' '[{"vmName":"a","users":[]}]'              > "${USERS}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${USERS}"
    [ "${status}" -eq 0 ]

    # Top-level keys are the documented contract.
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "vm_provisioner_config,vm_users_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].ipAddress')" = "10.0.0.1" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_users_config[0].vmName')" = "a" ]
}
