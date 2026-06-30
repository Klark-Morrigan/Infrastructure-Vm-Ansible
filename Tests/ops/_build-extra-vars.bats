#!/usr/bin/env bats
# Tests for ops/_build-extra-vars.sh - the composer that takes the
# contract-declared vaults (passed by the bridge as generic
# --vault-config Name=path pairs), derives each one's per-domain helper
# by the _build-extra-vars-<Name>.sh convention, dispatches the vault's
# config to it through the generic --config flag, and merges the
# fragments. Per-helper internals (file-not-found, invalid JSON, token
# empty, etc.) are covered by each helper's own bats file:
#
#   Tests/ops/_build-extra-vars-inventory.bats
#   the consumer's own _build-extra-vars-<Name>.bats
#
# This file covers what only the composer can: the <Name> -> helper
# derivation, which cross-flag combinations are rejected, that an
# optional cross-cutting input (token, file-server pair) is forwarded to
# a declared vault's helper, and how the fragments merge into the
# canonical extra-vars JSON the bridge consumes.
#
# The substrate ships no per-domain fragment of its own (only the always-on
# inventory fragment), so every test that dispatches a declared vault supplies
# --consumer-root pointing at a stub fragment (CONSUMER below) named by the
# <Name> convention. The stub emits a generic domain key shape derived from
# the flags the composer forwards, so what is tested here is the composer's
# derivation + dispatch + merge, not any one domain's fragment internals
# (those live with the consumer that owns the domain).
# Run with: bats Tests/ops/_build-extra-vars.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-extra-vars.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp buildExtraVars
    PROV="${TEST_TMP}/provisioner.json"
    DOMAIN_CFG="${TEST_TMP}/domain.json"

    # Minimal valid documents so the helpers always succeed when
    # called. Tests that need richer documents overwrite these.
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    printf '%s' '[{"name":"a","item":"x1"}]'              > "${DOMAIN_CFG}"

    # Consumer-owned per-domain fragment, named by the <Name> convention the
    # composer derives (here the example vault Name is "Toolchains"). The
    # composer resolves it from <consumer-root>/ops; this stub mirrors a real
    # fragment's contract - it consumes the config via the generic --config
    # flag and echoes back the optional cross-cutting inputs the composer
    # forwards - so the derivation + dispatch + merge is what gets exercised.
    CONSUMER="${TEST_TMP}/domain-consumer"
    mkdir -p "${CONSUMER}/ops"
    cat >"${CONSUMER}/ops/_build-extra-vars-Toolchains.sh" <<'STUB'
#!/usr/bin/env bash
cfg=""; token=""; base_url=""; version=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)         cfg="$2";      shift 2 ;;
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
   '{toolchains_config: $cfg, toolchains_token: $token}
    + (if $base_url != "" then {host_file_server_base_url: $base_url, runner_version: $version} else {} end)'
STUB
    chmod +x "${CONSUMER}/ops/_build-extra-vars-Toolchains.sh"
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
    run "${BASH_BIN}" "${SCRIPT}" --vault-config "Toolchains=${DOMAIN_CFG}"
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
        --vault-config "Toolchains"
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

@test "a declared vault -> emits the inventory and the domain keys" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "Toolchains=${DOMAIN_CFG}" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "toolchains_config,toolchains_token,vm_provisioner_config" ]

    # Spot-check the merge actually pulled values from each helper.
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
    [ "$(printf '%s' "${output}" | jq -r '.toolchains_config[0].item')" = "x1" ]
}

@test "--consumer-root resolves the per-domain fragment from the consumer ops dir" {
    # A consumer owns its per-domain fragment once extracted. Stub one under
    # <consumer>/ops named by the <Name> convention that emits a marker value
    # and prove the composer dispatched to it rather than to the substrate's
    # own ops/; the inventory fragment stays substrate and is unaffected.
    consumer_ops="${TEST_TMP}/consumer/ops"
    mkdir -p "${consumer_ops}"
    cat > "${consumer_ops}/_build-extra-vars-Toolchains.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"toolchains_config":"from-consumer-fragment"}'
EOF
    chmod +x "${consumer_ops}/_build-extra-vars-Toolchains.sh"

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "Toolchains=${DOMAIN_CFG}" \
        --consumer-root "${TEST_TMP}/consumer"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.toolchains_config')" = "from-consumer-fragment" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
}

@test "a declared vault whose fragment is absent is rejected before merge" {
    # The vault Name derives its helper by convention; a vault with no
    # matching _build-extra-vars-<Name>.sh is a contract typo or a domain
    # not yet wired - fail loud rather than silently drop it.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "MysteryVault=${DOMAIN_CFG}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no extra-vars helper for declared vault 'MysteryVault'"* ]]
}

@test "a declared vault + token + file-server pair forwards all of them to the helper" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "Toolchains=${DOMAIN_CFG}" \
        --github-token "ghp_example" \
        --host-base-url "http://10.10.0.1:8745" \
        --runner-version "2.999.0" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "host_file_server_base_url,runner_version,toolchains_config,toolchains_token,vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.toolchains_config[0].item')" = "x1" ]
    [ "$(printf '%s' "${output}" | jq -r '.toolchains_token')" = "ghp_example" ]
    [ "$(printf '%s' "${output}" | jq -r '.host_file_server_base_url')" = "http://10.10.0.1:8745" ]
    [ "$(printf '%s' "${output}" | jq -r '.runner_version')" = "2.999.0" ]
}

@test "a declared vault + token but no file-server pair omits the file-server keys" {
    # A down-direction flow lands here: the vault declared with a token but
    # the host file server off. The composer forwards only the token, so the
    # merged doc has the domain config + token plus the inventory key only.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "Toolchains=${DOMAIN_CFG}" \
        --github-token "ghp_example" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "toolchains_config,toolchains_token,vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.toolchains_token')" = "ghp_example" ]
    [ "$(printf '%s' "${output}" | jq -r 'has("host_file_server_base_url")')" = "false" ]
    [ "$(printf '%s' "${output}" | jq -r 'has("runner_version")')" = "false" ]
}

@test "a token with no declared extra vault is rejected" {
    # A token with no declared vault has no helper to consume it: the
    # composer rejects it rather than emit an extra-vars doc carrying an
    # unconsumable token.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_example"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--github-token requires at least one declared extra vault"* ]]
}

@test "partial file-server pair is rejected before dispatch" {
    # The file-server pair (--host-base-url + --runner-version) is
    # optional but must arrive as a pair: one without the other silently
    # drops half a download URL the consuming helper would build.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "Toolchains=${DOMAIN_CFG}" \
        --host-base-url "http://10.10.0.1:8745" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--host-base-url and --runner-version"* ]]
    [[ "${output}" == *"must be supplied together"* ]]

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --vault-config "Toolchains=${DOMAIN_CFG}" \
        --runner-version "2.999.0" \
        --consumer-root "${CONSUMER}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--host-base-url and --runner-version"* ]]
}

@test "file-server pair with no declared extra vault is rejected" {
    # The file-server URL has no consumer without a declared vault to
    # forward it to. Reject so a misconfigured caller does not produce
    # extra-vars carrying an unreachable URL.
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --host-base-url "http://10.10.0.1:8745" \
        --runner-version "2.999.0"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"require at least one declared extra vault"* ]]
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
