#!/usr/bin/env bats
# Tests for ops/virtual-machines/_stage-host-fileserver.sh - the host
# file server branch of the bridge. Serve-only: the consumer always
# supplies --staging-dir / --runner-version (it pre-staged the directory
# and resolved the version), so the helper just starts the listener over
# the given directory and echoes the version back - it resolves nothing
# and downloads nothing. It emits three KEY=value lines (RUNNER_VERSION /
# BASE_URL / PID) on stdout for the bridge to parse.
#
# Scope here is the helper's orchestration only: argument validation,
# pwsh.exe dispatch (bind path + listener start), BASE_URL/PID polling,
# and stdout shape. Each PowerShell helper has its own Pester coverage;
# the pwsh.exe stub on PATH discriminates by `-File <basename>` /
# `-Command` to mimic each helper's contract output.
# Run with: bats Tests/ops/_stage-host-fileserver.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops/virtual-machines" && pwd)/_stage-host-fileserver.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp stageHostFs
    PROV="${TEST_TMP}/provisioner.json"
    LISTENER_LOG="${TEST_TMP}/fileserver.out"
    # The consumer-staged directory and its version, supplied on every call.
    STAGING_DIR='C:\Users\Test\runner-cache'
    STAGING_VERSION="3.1.4"

    # Minimal valid provisioner config: one VM with an ipAddress so
    # the bind-IP derivation step finds something to use. Tests that
    # need a different shape overwrite this.
    printf '%s' '[{"vmName":"a","ipAddress":"10.10.0.50"}]' > "${PROV}"

    # pwsh.exe stub on PATH. The serve-only helper dispatches only the
    # listener start (-File _start-host-file-server.ps1) and, on the NAT
    # topology, Get-VmSwitchHostIp (-Command).
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
# The bridge hands pwsh.exe a Windows path (wslpath -w), so strip the
# last path component on either separator rather than using basename, which
# keys on '/' alone and would leave a backslash path intact.
case "${file##*[\\/]}" in
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

    # _to_windows_path now lives in Common-Automation, an external
    # abstraction to this helper, so it is mocked (real behavior is
    # unit-tested in Common-Automation/scripts/_to-windows-path.bats). The
    # stub goes in a fake COMMON_AUTOMATION_ROOT so the helper's
    # sibling-source wiring is still exercised; CI has no real
    # ../Common-Automation checkout for this repo. The pwsh.exe stub keys
    # off the file basename on either separator, so passthrough suffices.
    export COMMON_AUTOMATION_ROOT="${TEST_TMP}/Common-Automation"
    mkdir -p "${COMMON_AUTOMATION_ROOT}/scripts"
    cat >"${COMMON_AUTOMATION_ROOT}/scripts/_to-windows-path.sh" <<'STUB'
#!/usr/bin/env bash
_to_windows_path() { printf '%s' "$1"; }
STUB
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when any required flag is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    # provisioner only - listener-log / staging-dir / runner-version absent.
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 2 ]

    # --runner-version missing (the staged directory has no declared version).
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}"
    [ "${status}" -eq 2 ]

    # --staging-dir missing (no directory to serve).
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --listener-log "${LISTENER_LOG}" \
        --runner-version "${STAGING_VERSION}"
    [ "${status}" -eq 2 ]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "serves the given directory and echoes the supplied version without resolving" {
    # With the directory and version supplied, the helper only starts the
    # listener over the staged directory and echoes the supplied version.
    # It must not resolve a version or download a tarball - the consumer
    # already did both - and needs no token.
    export PWSH_STUB_BASE_URL="http://10.10.0.1:8745"
    export PWSH_STUB_FS_PID="55501"

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "3.1.4"
    [ "${status}" -eq 0 ]

    [[ "${output}" == *"RUNNER_VERSION=3.1.4"* ]]
    [[ "${output}" == *"BASE_URL=http://10.10.0.1:8745"* ]]
    [[ "${output}" == *"PID=55501"* ]]

    # Only the listener start was dispatched - no resolver / tarball helper.
    grep -q '_start-host-file-server.ps1' "${PWSH_INVOCATIONS_LOG}"
    ! grep -q '_resolve-runner-version.ps1' "${PWSH_INVOCATIONS_LOG}"
    ! grep -q '_ensure-runner-tarball.ps1'   "${PWSH_INVOCATIONS_LOG}"
}

@test "fails when provisioner config file is missing" {
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${TEST_TMP}/does-not-exist.json" \
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "${STAGING_VERSION}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner config not found"* ]]
}

@test "fails when provisioner config has no VMs with ipAddress" {
    # The bind-IP step needs at least one VM to anchor the /24 match;
    # an empty array or a VM missing ipAddress fails fast.
    printf '%s' '[]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "${STAGING_VERSION}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no VMs with ipAddress"* ]]
}

@test "ROUTER_IP unset: passes -TargetVmIp anchored on the first workload" {
    # Legacy single-switch topology. The bridge picks up the first
    # workload's ipAddress and lets _start-host-file-server.ps1's
    # Get-VmSwitchHostIp lookup resolve the host adapter from there.
    printf '%s' '[{"vmName":"a","ipAddress":"10.10.0.50"}]' > "${PROV}"
    unset ROUTER_IP

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "${STAGING_VERSION}"
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
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "${STAGING_VERSION}"
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
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "${STAGING_VERSION}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Get-VmSwitchHostIp returned empty"* ]]
}

@test "host file server failure aborts the helper with the listener log on stderr" {
    export PWSH_STUB_START_EXIT=7

    run "${BASH_BIN}" "${SCRIPT}" \
        --provisioner-config "${PROV}" \
        --listener-log "${LISTENER_LOG}" \
        --staging-dir "${STAGING_DIR}" \
        --runner-version "${STAGING_VERSION}"
    [ "${status}" -ne 0 ]
    # The helper appends the captured listener log to stderr so the
    # bridge surfaces actionable detail rather than a bare exit code.
    [[ "${output}" == *"exited before reporting PID"* || "${output}" == *"did not report BASE_URL"* ]]
}
