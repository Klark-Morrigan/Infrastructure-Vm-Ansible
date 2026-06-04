#!/usr/bin/env bats
# Tests for ops/_build-extra-vars-runners.sh - per-domain helper
# emitting github_runners_config + github_token. Owns the token-non-
# empty fast-fail and the shell-special-chars-verbatim contract since
# token hygiene is part of this domain.
# Run with: bats Tests/ops/_build-extra-vars-runners.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-extra-vars-runners.sh"

setup() {
    BASH_BIN="$(command -v bash)"
    TEST_TMP="$(mktemp -d -t buildExtraVarsRunners.XXXXXX)"
    RUNNERS="${TEST_TMP}/runners.json"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

@test "fails with usage when either required flag is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" --runners-config "${RUNNERS}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" --github-token "ghp_example"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "fails fast when --github-token is the empty string" {
    # Defensive: the orchestrator never passes one, but if a future
    # caller did, the silent-drop would be worse than a hard fail.
    printf '%s' '[]' > "${RUNNERS}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --runners-config "${RUNNERS}" \
        --github-token ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"github-token"* ]]
    [[ "${output}" == *"non-empty"* ]]
}

@test "fails with file path when the runners config is missing" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --runners-config "${TEST_TMP}/does-not-exist.json" \
        --github-token "ghp_example"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"runners-config"* ]]
    [[ "${output}" == *"not found"* ]]
}

@test "fails when the runners config is not valid JSON" {
    printf '%s' 'not-json' > "${RUNNERS}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --runners-config "${RUNNERS}" \
        --github-token "ghp_example"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"runners-config"* ]]
    [[ "${output}" == *"not valid JSON"* ]]
}

@test "valid inputs emit a two-key object with the runners-domain keys" {
    printf '%s' '[{"vmName":"a","runnerName":"r1"}]' > "${RUNNERS}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --runners-config "${RUNNERS}" \
        --github-token "ghp_example"
    [ "${status}" -eq 0 ]

    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "github_runners_config,github_token" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_runners_config[0].runnerName')" = "r1" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_token')" = "ghp_example" ]
}

@test "github-token with shell-special characters is emitted verbatim" {
    # Token rides as jq --arg so $VAR / backticks / quotes / pipes
    # land in JSON literally, not after a re-expansion pass.
    printf '%s' '[]' > "${RUNNERS}"
    weird_token='ghp_$VAR `cmd` "quoted" '"'"'apostrophe'"'"' & |'
    run "${BASH_BIN}" "${SCRIPT}" \
        --runners-config "${RUNNERS}" \
        --github-token "${weird_token}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.github_token')" = "${weird_token}" ]
}
