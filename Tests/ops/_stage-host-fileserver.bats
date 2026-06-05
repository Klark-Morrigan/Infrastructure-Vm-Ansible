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

setup() {
    BASH_BIN="$(command -v bash)"
    TEST_TMP="$(mktemp -d -t stageHostFs.XXXXXX)"
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
    cat >"${STUBS}/pwsh.exe" <<'STUB'
#!/usr/bin/env bash
file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -File) file="$2"; shift 2 ;;
        *)     shift ;;
    esac
done
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
        # Stay alive long enough for the polling loop to see PID;
        # the staging helper does not kill us, but bats teardown
        # tears down the whole tmpdir, and the stub exits with
        # the test process anyway.
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
    rm -rf "${TEST_TMP}"
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
