#!/usr/bin/env bats
# Tests for ops/_build-extra-vars.sh - the composer that takes the
# contract-declared vaults (passed by the bridge as generic
# --vault-config Name=path pairs), dispatches each to the per-domain
# helper that owns its fragment, and merges the fragments. Per-helper
# internals (file-not-found, invalid JSON, token empty, etc.) are
# covered by each helper's own bats file:
#
#   Tests/ops/_build-extra-vars-inventory.bats
#   Tests/ops/_build-extra-vars-runners.bats
#
# This file covers what only the composer can: which vault maps to
# which helper, which cross-flag combinations are rejected, and how
# the fragments merge into the canonical extra-vars JSON the bridge
# consumes.
#
# The substrate no longer ships its own runners fragment - the
# GitHubRunners arm resolves _build-extra-vars-runners.sh from
# <consumer-root>/ops - so every test that dispatches through that arm
# supplies --consumer-root pointing at a stub fragment (CONSUMER below).
# The stub emits the same key shape the real fragment would, derived from
# the flags the composer forwards, so what is tested here is the
# composer's dispatch + merge, not the fragment's internals (those live
# in the consumer repo).
# Run with: bats Tests/ops/_build-extra-vars.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-extra-vars.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp buildExtraVars
    PROV="${TEST_TMP}/provisioner.json"
    RUNNERS="${TEST_TMP}/runners.json"

    # Minimal valid documents so the helpers always succeed when
    # called. Tests that need richer documents overwrite these.
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    printf '%s' '[{"vmName":"a","runnerName":"r1"}]'      > "${RUNNERS}"

    # Consumer-owned runners fragment. The GitHubRunners arm resolves it
    # from <consumer-root>/ops; this stub mirrors the real fragment's
    # output (github_runners_config + github_token always, plus the
    # file-server pair when present) from the flags the composer forwards,
    # so the dispatch + merge is what gets exercised.
    CONSUMER="${TEST_TMP}/runner-consumer"
    mkdir -p "${CONSUMER}/ops"
    cat >"${CONSUMER}/ops/_build-extra-vars-runners.sh" <<'STUB'
#!/usr/bin/env bash
cfg=""; token=""; base_url=""; version=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runners-config) cfg="$2";      shift 2 ;;
        --github-token)   token="$2";    shift 2 ;;
        --host-base-url)  base_url="$2"; shift 2 ;;
        --runner-version) version="$2";  shift 2 ;;
        *) shift ;;
    esac
done
jq -n \
   --argjson cfg "$(cat "${cfg}")" \
   --arg token "${token}" \
   --arg base_url "${base_url}" \
   --arg version "${version}" \
   '{github_runners_config: $cfg, github_token: $token}
    + (if $base_url != "" then {host_file_server_base_url: $base_url, runner_version: $version} else {} end)'
STUB
    chmod +x "${CONSUMER}/ops/_build-extra-vars-runners.sh"
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when the provisioner config is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    # A declared extra vault without the always-on provisioner is still
    # a usage error: the inventory fragment has no source.
    run "${BASH_BIN}" "${SCRIPT}" --vault-config "GitHubRunners=${RUNNERS}"
    [ "${status}" -eq 2 ]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "rejects a --vault-config value with no Name=path shape" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--vault-config expects <Name>=<path>"* ]]
}

@test "provisioner only -> emits just the inventory key" {
    # A consumer that declares no extra vaults (empty CA_EXTRA_VAULTS)
    # still gets the always-on inventory fragment and nothing else.
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
}

@test "GitHubRunners vault -> emits the inventory and runners keys" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}" \
        --github-token "ghp_example" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "github_runners_config,github_token,vm_provisioner_config" ]

    # Spot-check the merge actually pulled values from each helper.
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_runners_config[0].runnerName')" = "r1" ]
}

@test "--consumer-root resolves the per-domain fragment from the consumer ops dir" {
    # A consumer owns its per-domain fragment once extracted. Stub one under
    # <consumer>/ops that emits a marker value and prove the composer
    # dispatched to it rather than to the substrate's own fragment; the
    # inventory fragment stays substrate and is unaffected.
    consumer_ops="${TEST_TMP}/consumer/ops"
    mkdir -p "${consumer_ops}"
    cat > "${consumer_ops}/_build-extra-vars-runners.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"github_runners_config":"from-consumer-fragment"}'
EOF
    chmod +x "${consumer_ops}/_build-extra-vars-runners.sh"

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}" \
        --github-token "ghp_example" \
        --consumer-root "${TEST_TMP}/consumer"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.github_runners_config')" = "from-consumer-fragment" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
}

@test "an unrecognised vault name is rejected before merge" {
    # A vault with no fragment helper is a contract typo or a domain
    # not yet wired; fail loud rather than silently drop it.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "MysteryVault=${RUNNERS}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no extra-vars helper for declared vault 'MysteryVault'"* ]]
}

@test "GitHubRunners + full runner flags -> merged output has all five keys" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}" \
        --github-token "ghp_example" \
        --host-base-url "http://10.10.0.1:8745" \
        --runner-version "2.999.0" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "github_runners_config,github_token,host_file_server_base_url,runner_version,vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_runners_config[0].runnerName')" = "r1" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_token')" = "ghp_example" ]
    [ "$(printf '%s' "${output}" | jq -r '.host_file_server_base_url')" = "http://10.10.0.1:8745" ]
    [ "$(printf '%s' "${output}" | jq -r '.runner_version')" = "2.999.0" ]
}

@test "GitHubRunners with token but no file-server pair emits three keys (down-direction shape)" {
    # The deregister flow lands here: GitHubRunners vault declared, host
    # file server off. The runners helper drops the two file-server
    # keys, so the merged doc has the runners config + token plus the
    # inventory key only.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}" \
        --github-token "ghp_example" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "github_runners_config,github_token,vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.github_token')" = "ghp_example" ]
    [ "$(printf '%s' "${output}" | jq -r 'has("host_file_server_base_url")')" = "false" ]
    [ "$(printf '%s' "${output}" | jq -r 'has("runner_version")')" = "false" ]
}

@test "GitHubRunners vault without a token is rejected" {
    # The runner registration the vault configures cannot run without a
    # token; reject before any helper runs.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"GitHubRunners vault requires --github-token"* ]]
}

@test "a token without the GitHubRunners vault is rejected" {
    # A token with no consumer is a misconfiguration: the only vault that
    # consumes it was not declared.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_example"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--github-token requires the GitHubRunners vault"* ]]
}

@test "partial file-server pair is rejected before dispatch" {
    # The file-server pair (--host-base-url + --runner-version) is
    # optional but must arrive as a pair: one without the other silently
    # drops half the runner_binary download URL.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}" \
        --github-token "ghp_example" \
        --host-base-url "http://10.10.0.1:8745"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--host-base-url and --runner-version"* ]]
    [[ "${output}" == *"must be supplied together"* ]]

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "GitHubRunners=${RUNNERS}" \
        --github-token "ghp_example" \
        --runner-version "2.999.0"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--host-base-url and --runner-version"* ]]
}

@test "file-server pair without the GitHubRunners vault is rejected" {
    # The file-server URL has no consumer without the runners config (the
    # runner_binary role is only loaded for that vault). Reject so a
    # misconfigured caller does not produce extra-vars carrying an
    # unreachable URL.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --host-base-url "http://10.10.0.1:8745" \
        --runner-version "2.999.0"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"require the GitHubRunners vault"* ]]
}

@test "helper failures surface to the composer's exit code" {
    # Point the inventory helper at a missing file; the composer must
    # propagate the failure rather than emit a partial document.
    # set -euo pipefail + the `$(...)` capture make this reliable
    # without explicit error handling in the composer.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${TEST_TMP}/does-not-exist.json"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not found"* ]]
}
