#!/usr/bin/env bats
# Tests for ops/_build-extra-vars-users.sh - per-domain helper
# emitting vm_users_config. Same shape as the inventory helper's
# bats; documents the contract independently so the file reads on
# its own.
# Run with: bats Tests/ops/_build-extra-vars-users.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-extra-vars-users.sh"

setup() {
    BASH_BIN="$(command -v bash)"
    TEST_TMP="$(mktemp -d -t buildExtraVarsUsers.XXXXXX)"
    USERS="${TEST_TMP}/users.json"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

@test "fails with usage when --users-config is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "fails with file path when the users config is missing" {
    run "${BASH_BIN}" "${SCRIPT}" --users-config "${TEST_TMP}/does-not-exist.json"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"users-config"* ]]
    [[ "${output}" == *"not found"* ]]
}

@test "fails when the users config is not valid JSON" {
    printf '%s' 'not-json' > "${USERS}"
    run "${BASH_BIN}" "${SCRIPT}" --users-config "${USERS}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"users-config"* ]]
    [[ "${output}" == *"not valid JSON"* ]]
}

@test "valid input emits a single-key object with vm_users_config" {
    printf '%s' '[{"vmName":"a","users":[]}]' > "${USERS}"
    run "${BASH_BIN}" "${SCRIPT}" --users-config "${USERS}"
    [ "${status}" -eq 0 ]

    [ "$(printf '%s' "${output}" | jq -r 'keys | join(",")')" = "vm_users_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_users_config[0].vmName')" = "a" ]
}
