#!/usr/bin/env bats
# Tests for ops/_build-extra-vars.sh - the orchestrator that
# dispatches to per-payload-domain helpers and merges their JSON
# fragments. Per-helper internals (file-not-found, invalid JSON,
# token empty, etc.) are covered by each helper's own bats file:
#
#   Tests/ops/_build-extra-vars-inventory.bats
#   Tests/ops/_build-extra-vars-users.bats
#   Tests/ops/_build-extra-vars-runners.bats
#
# This file covers what only the orchestrator can: which helpers are
# dispatched, which are skipped, and how their fragments merge into
# the canonical extra-vars JSON the bridge consumes.
# Run with: bats Tests/ops/_build-extra-vars.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-extra-vars.sh"

setup() {
    BASH_BIN="$(command -v bash)"
    TEST_TMP="$(mktemp -d -t buildExtraVars.XXXXXX)"
    PROV="${TEST_TMP}/provisioner.json"
    USERS="${TEST_TMP}/users.json"
    RUNNERS="${TEST_TMP}/runners.json"

    # Minimal valid documents so the helpers always succeed when
    # called. Tests that need richer documents overwrite these.
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    printf '%s' '[{"vmName":"a","users":[]}]'             > "${USERS}"
    printf '%s' '[{"vmName":"a","runnerName":"r1"}]'      > "${RUNNERS}"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

@test "fails with usage when a required flag is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 2 ]

    run "${BASH_BIN}" "${SCRIPT}" --users-config "${USERS}"
    [ "${status}" -eq 2 ]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "two required flags only -> emits the two always-on keys, skips runners helper" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${USERS}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "vm_provisioner_config,vm_users_config" ]

    # Spot-check the merge actually pulled values from each helper.
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_users_config[0].vmName')" = "a" ]
}

@test "all four flags -> merged output has all four keys" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${USERS}" \
        --runners-config "${RUNNERS}" \
        --github-token "ghp_example"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "github_runners_config,github_token,vm_provisioner_config,vm_users_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_runners_config[0].runnerName')" = "r1" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_token')" = "ghp_example" ]
}

@test "--runners-config without --github-token is rejected before dispatch" {
    # Pairing rule lives in the orchestrator, not the runners helper:
    # the helper would also reject this, but failing here lets the
    # error name the orchestrator-level contract violation.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${USERS}" \
        --runners-config "${RUNNERS}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--runners-config requires --github-token"* ]]
}

@test "--github-token without --runners-config is rejected before dispatch" {
    # Symmetric pairing rule: a token alone would silently never
    # reach a play, so refuse the call instead of dropping it.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --users-config "${USERS}" \
        --github-token "ghp_example"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--github-token requires --runners-config"* ]]
}

@test "helper failures surface to the orchestrator's exit code" {
    # Point the inventory helper at a missing file; the orchestrator
    # must propagate the failure rather than emit a partial document.
    # set -euo pipefail + the `$(...)` capture make this reliable
    # without explicit error handling in the orchestrator.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${TEST_TMP}/does-not-exist.json" \
        --users-config "${USERS}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not found"* ]]
}
