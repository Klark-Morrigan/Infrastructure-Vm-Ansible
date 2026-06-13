#!/usr/bin/env bats
# Tests for ops/_stage-host-fileserver.sh - the GitHubRunners opt-in
# branch of the bridge. The helper drives three pwsh.exe round-trips
# (resolve version, ensure tarball, start listener) and emits three
# KEY=value lines on stdout for the bridge to parse.
#
# Scope here is the helper's orchestration only: argument validation,
# pwsh.exe dispatch order, BASE_URL/PID polling, and stdout shape.
# Each PowerShell helper has its own Pester coverage; the pwsh.exe
# stub on PATH discriminates by `-File <basename>` to mimic each
# helper's contract output.
# Run with: bats Tests/ops/_stage-host-fileserver.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_stage-host-fileserver.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp stageHostFs
    PROV="${TEST_TMP}/provisioner.json"
    LISTENER_LOG="${TEST_TMP}/fileserver.out"

    # Minimal valid provisioner config: one VM with an ipAddress so
    # the bind-IP derivation step finds something to use. Tests that
    # need a different shape overwrite this.
    printf '%s' '[{"vmName":"a","ipAddress":"10.10.0.50"}]' > "${PROV}"

    # pwsh.exe stub on PATH. Each helper's -File argument selects the
    # branch and produces the contract output.
    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"
    # Per-run log capturing every pwsh.exe argv. Lets tests assert
    # which bind path (-TargetVmIp vs -HostIp) the bridge chose for
    # _start-host-file-server.ps1 without changing the stub's contract
    # output. Cleared per setup so each test starts fresh.
    export PWSH_INVOCATIONS_LOG="${TEST_TMP}/pwsh-invocations.log"
    : > "${PWSH_INVOCATIONS_LOG}"

    cat >"${STUBS}/pwsh.exe" <<'STUB'
#!/usr/bin/env bash
# Log every invocation argv so tests can introspect which bind path
# the bridge picked. One line per call, tab-separated.
printf '%s\n' "$*" >>"${PWSH_INVOCATIONS_LOG}"

file=""
cmd=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -File)    file="$2"; shift 2 ;;
        -Command) cmd="$2";  shift 2 ;;
        *)        shift ;;
    esac
done
# -Command path: only Get-VmSwitchHostIp is dispatched from this
# helper. PWSH_STUB_HOST_IP overrides the returned host IP per test.
if [[ -n "${cmd}" ]]; then
    case "${cmd}" in
        *Get-VmSwitchHostIp*)
            # Use ${VAR-default} (no colon) so an explicitly empty
            # PWSH_STUB_HOST_IP stays empty - that is the "lookup
            # silently failed" path the bridge must catch.
            echo "${PWSH_STUB_HOST_IP-192.168.1.10}"
            exit 0
            ;;
        *)
            echo "pwsh-stub: unhandled -Command payload" >&2
            exit 99
            ;;
    esac
fi
case "$(basename "${file}")" in
    _resolve-runner-version.ps1)
        echo "${PWSH_STUB_VERSION:-2.999.0}"
        ;;
    _ensure-runner-tarball.ps1)
        echo "${PWSH_STUB_TAR:-C:\\Users\\Test\\AppData\\Local\\Temp\\runner-cache\\actions-runner-linux-x64-2.999.0.tar.gz}"
        ;;
    _start-host-file-server.ps1)
        if [[ -n "${PWSH_STUB_START_EXIT:-}" && "${PWSH_STUB_START_EXIT}" != "0" ]]; then
            echo "stub-start-failure" >&2
            exit "${PWSH_STUB_START_EXIT}"
        fi
        echo "BASE_URL=${PWSH_STUB_BASE_URL:-http://10.10.0.1:8745}"
        echo "PID=${PWSH_STUB_FS_PID:-12345}"
        sleep 5
        ;;
    *)
        echo "pwsh-stub: unhandled file=${file}" >&2
        exit 99
        ;;
esac
STUB
    chmod +x "${STUBS}/pwsh.exe"
    export PATH="${STUBS}:${PATH}"
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when any required flag is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 2 ]

    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}" --github-token "x"
    [ "${status}" -eq 2 ]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "fails fast when --github-token is the empty string" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"github-token"* ]]
    [[ "${output}" == *"non-empty"* ]]
}

@test "fails when provisioner config file is missing" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${TEST_TMP}/does-not-exist.json" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner config not found"* ]]
}

@test "fails when provisioner config has no VMs with ipAddress" {
    # The bind-IP step needs at least one VM to anchor the /24 match;
    # an empty array or a VM missing ipAddress fails fast.
    printf '%s' '[]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no VMs with ipAddress"* ]]
}

@test "happy path emits the three contract lines on stdout" {
    export PWSH_STUB_VERSION="2.999.0"
    export PWSH_STUB_BASE_URL="http://10.10.0.1:8745"
    export PWSH_STUB_FS_PID="78901"

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -eq 0 ]

    [[ "${output}" == *"RUNNER_VERSION=2.999.0"* ]]
    [[ "${output}" == *"BASE_URL=http://10.10.0.1:8745"* ]]
    [[ "${output}" == *"PID=78901"* ]]
}

@test "ROUTER_IP unset: passes -TargetVmIp anchored on the first workload" {
    # Legacy single-switch topology. The bridge picks up the first
    # workload's ipAddress and lets _start-host-file-server.ps1's
    # Get-VmSwitchHostIp lookup resolve the host adapter from there.
    printf '%s' '[{"vmName":"a","ipAddress":"10.10.0.50"}]' > "${PROV}"
    unset ROUTER_IP

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -eq 0 ]

    start_args="$(grep -- '-File' "${PWSH_INVOCATIONS_LOG}" | grep _start-host-file-server.ps1)"
    [[ "${start_args}" == *"-TargetVmIp 10.10.0.50"* ]]
    [[ "${start_args}" != *"-HostIp"* ]]
}

@test "ROUTER_IP set: resolves Get-VmSwitchHostIp on the router IP and passes -HostIp" {
    # Feature-53 NAT topology. The host has no /24 match for the
    # workload (10.99.0.10 here is on a private switch); the bridge
    # must instead resolve a host adapter on the router's upstream
    # LAN via Get-VmSwitchHostIp on ROUTER_IP, then pass -HostIp to
    # _start-host-file-server.ps1.
    printf '%s' '[{"vmName":"wl","ipAddress":"10.99.0.10"}]' > "${PROV}"
    export ROUTER_IP=192.168.1.42
    export PWSH_STUB_HOST_IP=192.168.1.7

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -eq 0 ]

    # Get-VmSwitchHostIp was invoked with the router IP.
    grep -q "Get-VmSwitchHostIp" "${PWSH_INVOCATIONS_LOG}"
    grep -q "192.168.1.42" "${PWSH_INVOCATIONS_LOG}"

    # Listener was started with -HostIp (the resolved host adapter)
    # and NOT with -TargetVmIp (which would have re-driven the
    # broken /24 lookup for the workload's private-switch IP).
    start_args="$(grep -- '-File' "${PWSH_INVOCATIONS_LOG}" | grep _start-host-file-server.ps1)"
    [[ "${start_args}" == *"-HostIp 192.168.1.7"* ]]
    [[ "${start_args}" != *"-TargetVmIp"* ]]
}

@test "ROUTER_IP set but Get-VmSwitchHostIp returns empty: aborts fast" {
    # Regression guard: if the router upstream resolution silently
    # fails, the bridge must not fall back to the broken -TargetVmIp
    # path. Surface the empty result up front.
    printf '%s' '[{"vmName":"wl","ipAddress":"10.99.0.10"}]' > "${PROV}"
    export ROUTER_IP=192.168.1.42
    export PWSH_STUB_HOST_IP=""

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Get-VmSwitchHostIp returned empty"* ]]
}

@test "host file server failure aborts the helper with the listener log on stderr" {
    export PWSH_STUB_START_EXIT=7

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --github-token "ghp_x" \
        --listener-log "${LISTENER_LOG}"
    [ "${status}" -ne 0 ]
    # The helper appends the captured listener log to stderr so the
    # bridge surfaces actionable detail rather than a bare exit code.
    [[ "${output}" == *"exited before reporting PID"* || "${output}" == *"did not report BASE_URL"* ]]
}
