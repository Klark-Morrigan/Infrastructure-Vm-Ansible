#!/usr/bin/env bats
# Tests for ops/_run-playbook.sh - the thin orchestrator. Scope here
# is wiring only: argument validation, tmpdir lifecycle, sibling
# invocation order, dispatch contract. Each sibling
# (_read-vault-config.sh, _build-inventory.sh, _build-extra-vars.sh)
# has its own bats file covering its internals, so here they are
# replaced with no-op stubs that record their invocation and emit a
# placeholder JSON blob.
#
# The orchestrator anchors sibling lookups to its own BASH_SOURCE
# directory, so this suite transplants _run-playbook.sh and the stub
# siblings into a throwaway "repo" tree per test - same ops/ layout
# as the real repo so script_dir resolves to ops/.
# Run with: bats Tests/ops/_run-playbook.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp runPlaybook
    TEST_REPO="${TEST_TMP}/repo"
    mkdir -p "${TEST_REPO}/ops" \
             "${TEST_REPO}/playbooks" \
             "${TEST_REPO}/.venv/bin" \
             "${TEST_TMP}/stubs"

    # Real orchestrator lives in TEST_REPO/ops/ so its repo_root
    # anchor (script_dir/..) points at TEST_REPO. Stub siblings live
    # next to it so the orchestrator's `${script_dir}/_<sibling>.sh`
    # lookup finds them. _ansible-env.sh is a real (non-stubbed)
    # helper that the orchestrator sources for ANSIBLE_CONFIG export -
    # copying the genuine file rather than stubbing because its only
    # side effect is `export ANSIBLE_CONFIG=...`, which is harmless
    # in this test context (no ansible-playbook actually reads it).
    cp "${REPO_ROOT}/ops/_run-playbook.sh"      "${TEST_REPO}/ops/"
    cp "${REPO_ROOT}/ops/_ansible-env.sh"       "${TEST_REPO}/ops/"
    cp "${REPO_ROOT}/Tests/playbooks/_noop.yml" "${TEST_REPO}/playbooks/"
    chmod +x "${TEST_REPO}/ops/_run-playbook.sh"

    # No-op activate. The stubbed ansible-playbook on PATH is what
    # actually runs; activating a real venv would defeat the stub.
    : > "${TEST_REPO}/.venv/bin/activate"

    # Sibling stubs. Each records its invocation in TRACE_FILE so
    # call order can be asserted, then prints a placeholder JSON
    # blob. _read-vault-config writes to stdout (the orchestrator
    # redirects); the two transforms read stdin or args and write
    # stdout too.
    export TRACE_FILE="${TEST_TMP}/trace"
    : > "${TRACE_FILE}"

    # The provisioner branch returns a one-VM array because the new
    # host-file-server staging step reads the first ipAddress out of
    # it; other vaults still get the placeholder object - their
    # downstream consumers are stubbed too and never inspect the
    # payload.
    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
echo "read-vault-config:$1:$2" >> "${TRACE_FILE}"
case "$1" in
    VmProvisioner)
        printf '%s' '[{"vmName":"a","ipAddress":"10.10.0.50","username":"u","password":"p"}]'
        ;;
    *)
        printf '%s' '{"stub":"vault"}'
        ;;
esac
STUB

    cat >"${TEST_REPO}/ops/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
echo "build-inventory" >> "${TRACE_FILE}"
cat >/dev/null  # consume stdin so the orchestrator's pipe completes cleanly
printf '%s' '{"stub":"inventory"}'
STUB

    cat >"${TEST_REPO}/ops/_build-extra-vars.sh" <<'STUB'
#!/usr/bin/env bash
echo "build-extra-vars:$*" >> "${TRACE_FILE}"
printf '%s' '{"stub":"extra-vars"}'
STUB

    # _stage-host-fileserver.sh is stubbed at the orchestrator
    # boundary - the bridge's only contract with it is the three
    # KEY=value lines on stdout. The staging helper's own bats file
    # covers its pwsh.exe round-trips and polling logic. Override
    # the per-test outputs via STAGE_STUB_* env vars.
    cat >"${TEST_REPO}/ops/_stage-host-fileserver.sh" <<'STUB'
#!/usr/bin/env bash
echo "stage-host-fileserver:$*" >> "${TRACE_FILE}"
if [[ "${STAGE_STUB_EXIT:-0}" != "0" ]]; then
    echo "stub-stage-failure" >&2
    exit "${STAGE_STUB_EXIT}"
fi
printf 'RUNNER_VERSION=%s\n' "${STAGE_STUB_VERSION:-2.999.0}"
printf 'BASE_URL=%s\n'        "${STAGE_STUB_BASE_URL:-http://10.10.0.1:8745}"
printf 'PID=%s\n'             "${STAGE_STUB_FS_PID:-12345}"
STUB

    chmod +x "${TEST_REPO}/ops/"_*.sh

    # pwsh.exe stub - the bridge still invokes pwsh.exe directly for
    # the EXIT-trap stop call (the staging helper does not own the
    # lifecycle of the listener it backgrounds; the bridge has to
    # outlive ansible-playbook). The stub records the -ProcessId arg
    # so a test can verify the captured value flows through cleanup.
    cat >"${TEST_TMP}/stubs/pwsh.exe" <<'STUB'
#!/usr/bin/env bash
file=""
cmd=""
process_id=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -File)      file="$2";       shift 2 ;;
        -Command)   cmd="$2";        shift 2 ;;
        -ProcessId) process_id="$2"; shift 2 ;;
        *)          shift ;;
    esac
done
# -Command path: the router-resolution block dispatches
# Get-VmKvpIpAddress when ROUTER_IP is not statically set. Override
# the echoed IP per test via PWSH_STUB_ROUTER_IP.
if [[ -n "${cmd}" ]]; then
    case "${cmd}" in
        *Get-VmKvpIpAddress*)
            echo "${PWSH_STUB_ROUTER_IP-192.168.1.99}"
            exit 0
            ;;
        *)
            echo "pwsh-stub: unhandled -Command payload" >&2
            exit 99
            ;;
    esac
fi
case "$(basename "${file}")" in
    _stop-host-file-server.ps1)
        echo "stop-host-file-server:${process_id}" >> "${TRACE_FILE}"
        ;;
    *)
        echo "pwsh-stub: unhandled file=${file}" >&2
        exit 99
        ;;
esac
STUB
    chmod +x "${TEST_TMP}/stubs/pwsh.exe"

    # ansible-playbook stub - records argv to a log so the dispatch
    # contract can be asserted without an Ansible install.
    cat >"${TEST_TMP}/stubs/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${ANSIBLE_PLAYBOOK_STUB_LOG:-/dev/null}"
exit "${ANSIBLE_PLAYBOOK_STUB_EXIT:-0}"
STUB
    chmod +x "${TEST_TMP}/stubs/ansible-playbook"

    export ANSIBLE_PLAYBOOK_STUB_LOG="${TEST_TMP}/ansible-playbook.argv"
    export ANSIBLE_PLAYBOOK_STUB_EXIT=0
    export PATH="${TEST_TMP}/stubs:${PATH}"

    # The orchestrator requires SECRET_SUFFIX up-front to select the
    # vault entry per lifecycle; the stubbed vault read ignores it, but
    # the gate runs before arg validation so every test must set it.
    export SECRET_SUFFIX=Test
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when invoked without a playbook arg" {
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    # Tmpdir creation comes after argument validation, so nothing
    # should have leaked.
    leftovers="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'vm-ansible.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "fails with explicit message when the requested playbook is missing" {
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/does-not-exist.yml
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"playbook not found"* ]]
}

@test "happy path invokes the three siblings in order then dispatches ansible-playbook" {
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml --check
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:VmProvisioner:VmProvisionerConfig"* ]]
    [[ "${trace}" == *"read-vault-config:VmUsers:VmUsersConfig"* ]]
    [[ "${trace}" == *"build-inventory"* ]]
    [[ "${trace}" == *"build-extra-vars:"*"--provisioner-config"*"--users-config"* ]]

    # Order check via line numbers - awk for clarity. The pipeline is
    # provisioner read -> users read -> inventory build -> extra-vars
    # compose; any reorder would break downstream expectations.
    [ "$(awk '/^read-vault-config:VmProvisioner:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^read-vault-config:VmUsers:/{print NR; exit}' "${TRACE_FILE}")" ]
    [ "$(awk '/^read-vault-config:VmUsers:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^build-inventory/{print NR; exit}' "${TRACE_FILE}")" ]
    [ "$(awk '/^build-inventory/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^build-extra-vars:/{print NR; exit}' "${TRACE_FILE}")" ]
}

@test "dispatch passes the expected ansible-playbook arguments" {
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml --check --limit somehost
    [ "${status}" -eq 0 ]

    argv="$(cat "${ANSIBLE_PLAYBOOK_STUB_LOG}")"
    [[ "${argv}" == *"-i"* ]]
    [[ "${argv}" == *"hosts.json"* ]]
    [[ "${argv}" == *"--extra-vars"* ]]
    [[ "${argv}" == *"extra-vars.json"* ]]
    [[ "${argv}" == *"playbooks/_noop.yml"* ]]
    [[ "${argv}" == *"--check"* ]]
    [[ "${argv}" == *"--limit"* ]]
    [[ "${argv}" == *"somehost"* ]]
}

@test "tmpdir is removed after a successful run" {
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    leftovers="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'vm-ansible.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "NEEDS_GITHUB_RUNNERS unset keeps the bridge on the two-vault path" {
    # Default entry points (create-users, remove-users) must not pay
    # for the GitHubRunners vault read or surface the new keys.
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:VmProvisioner:VmProvisionerConfig"* ]]
    [[ "${trace}" == *"read-vault-config:VmUsers:VmUsersConfig"* ]]
    [[ "${trace}" != *"read-vault-config:GitHubRunners:"* ]]
    [[ "${trace}" != *"--runners-config"* ]]
    [[ "${trace}" != *"--github-token"* ]]
}

@test "NEEDS_GITHUB_RUNNERS=1 with GH_TOKEN drives the third vault read and threads both keys" {
    export NEEDS_GITHUB_RUNNERS=1
    export GH_TOKEN="ghp_example"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:VmProvisioner:VmProvisionerConfig"* ]]
    [[ "${trace}" == *"read-vault-config:VmUsers:VmUsersConfig"* ]]
    [[ "${trace}" == *"read-vault-config:GitHubRunners:GitHubRunnersConfig"* ]]
    [[ "${trace}" == *"--runners-config"* ]]
    [[ "${trace}" == *"--github-token"*"ghp_example"* ]]

    # The third read must come after the first two so a partial
    # failure of the runners vault leaves the existing two-vault
    # path's diagnostics intact for create-users / remove-users.
    [ "$(awk '/^read-vault-config:VmUsers:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^read-vault-config:GitHubRunners:/{print NR; exit}' "${TRACE_FILE}")" ]
}

@test "NEEDS_GITHUB_RUNNERS=1 alone skips the host file server (deregister flow shape)" {
    # The deregister entry sets NEEDS_GITHUB_RUNNERS=1 but not
    # NEEDS_HOST_FILE_SERVER, because nothing is fetched on the down
    # path. The third vault read still fires, the staging helper does
    # not, and the extra-vars helper does not receive the file-server
    # pair (so the merged document genuinely lacks the two keys).
    export NEEDS_GITHUB_RUNNERS=1
    export GH_TOKEN="ghp_example"
    unset NEEDS_HOST_FILE_SERVER

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:GitHubRunners:"* ]]
    [[ "${trace}" != *"stage-host-fileserver:"* ]]
    [[ "${trace}" != *"--host-base-url"* ]]
    [[ "${trace}" != *"--runner-version"* ]]
    [[ "${trace}" != *"stop-host-file-server"* ]]
}

@test "NEEDS_HOST_FILE_SERVER=1 without NEEDS_GITHUB_RUNNERS fails fast" {
    # The file-server flag is meaningless on its own: the listener it
    # would spawn serves the runner tarball, and the runner_binary role
    # is only loaded under NEEDS_GITHUB_RUNNERS=1. Reject before any
    # vault read.
    export NEEDS_HOST_FILE_SERVER=1
    unset NEEDS_GITHUB_RUNNERS
    unset GH_TOKEN

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"NEEDS_HOST_FILE_SERVER"* ]]
    [[ "${output}" == *"NEEDS_GITHUB_RUNNERS"* ]]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" != *"read-vault-config"* ]]
}

@test "NEEDS_GITHUB_RUNNERS=1 without GH_TOKEN fails fast with a clear message" {
    # The bridge itself never prompts - that is the operator entry's
    # job. Refusing the call here is louder than silently emitting
    # an empty token downstream.
    export NEEDS_GITHUB_RUNNERS=1
    unset GH_TOKEN

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GH_TOKEN"* ]]

    # Bail before any vault read so a misconfigured caller does not
    # spawn pwsh.exe just to discover it has no token.
    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" != *"read-vault-config"* ]]
}

@test "GH_TOKEN is cleared from the bridge env before ansible-playbook runs" {
    # Threading the token through extra-vars only (not env) keeps it
    # out of any child process other than ansible-playbook itself,
    # and out of the ansible-playbook env at that.
    export NEEDS_GITHUB_RUNNERS=1
    export GH_TOKEN="ghp_example"

    # Replace the ansible-playbook stub with one that records env.
    cat >"${TEST_TMP}/stubs/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
printenv GH_TOKEN > "${ANSIBLE_PLAYBOOK_STUB_LOG}.env" || true
exit 0
STUB
    chmod +x "${TEST_TMP}/stubs/ansible-playbook"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    [ ! -s "${ANSIBLE_PLAYBOOK_STUB_LOG}.env" ]
}

@test "NEEDS_HOST_FILE_SERVER=1 calls the staging helper with the provisioner config and token" {
    export NEEDS_GITHUB_RUNNERS=1
    export NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"stage-host-fileserver:"*"--provisioner-config"*"--github-token"*"ghp_example"* ]]
    [[ "${trace}" == *"stage-host-fileserver:"*"--listener-log"* ]]

    # Staging fires between the third vault read and extra-vars
    # compose; any reorder would corrupt the extra-vars payload.
    [ "$(awk '/^read-vault-config:GitHubRunners:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^stage-host-fileserver:/{print NR; exit}'           "${TRACE_FILE}")" ]
    [ "$(awk '/^stage-host-fileserver:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^build-extra-vars:/{print NR; exit}'      "${TRACE_FILE}")" ]
}

@test "NEEDS_HOST_FILE_SERVER=1 threads BASE_URL + runner_version into extra-vars" {
    export NEEDS_GITHUB_RUNNERS=1
    export NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"
    export STAGE_STUB_VERSION="2.999.0"
    export STAGE_STUB_BASE_URL="http://10.10.0.1:8745"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"--host-base-url"*"http://10.10.0.1:8745"* ]]
    [[ "${trace}" == *"--runner-version"*"2.999.0"* ]]
}

@test "EXIT trap stops the host file server with the captured PID even on a clean exit" {
    export NEEDS_GITHUB_RUNNERS=1
    export NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"
    export STAGE_STUB_FS_PID="78901"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"stop-host-file-server:78901"* ]]
}

@test "EXIT trap stops the host file server when ansible-playbook itself fails" {
    # The failure path the clean-exit case does not exercise: staging
    # succeeded so a PID is captured, but ansible-playbook returns
    # non-zero. The trap must still kill the listener, otherwise an
    # operator who hits a play-side error has a stranded HttpListener
    # holding the port until they reboot.
    export NEEDS_GITHUB_RUNNERS=1
    export NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"
    export STAGE_STUB_FS_PID="65432"
    export ANSIBLE_PLAYBOOK_STUB_EXIT=2

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"stop-host-file-server:65432"* ]]

    # And the tmpdir still gets cleaned - both legs of cleanup() run
    # regardless of which exit path triggered the trap.
    leftovers="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'vm-ansible.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "staging helper failure aborts the bridge before ansible-playbook runs" {
    export NEEDS_GITHUB_RUNNERS=1
    export NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"
    export STAGE_STUB_EXIT=7

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]

    # ansible-playbook stub records argv to this file when invoked;
    # the file must be absent because the bridge bailed before the
    # dispatch step.
    [ ! -s "${ANSIBLE_PLAYBOOK_STUB_LOG}" ]
}

@test "tmpdir is removed when a sibling fails mid-pipeline" {
    # Replace the inventory stub with a failing one to exercise the
    # EXIT trap on the unhappy path.
    cat >"${TEST_REPO}/ops/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "boom" >&2
exit 1
STUB
    chmod +x "${TEST_REPO}/ops/_build-inventory.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]
    leftovers="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'vm-ansible.*' -print 2>/dev/null || true)"
    [ -z "${leftovers}" ]
}

@test "router row absent: ROUTER_IP env stays unset and inventory build sees no router context" {
    # Regression guard for the legacy single-switch topology. With no
    # router in VmProvisionerConfig, the resolution block must be a
    # complete no-op - no pwsh.exe -Command dispatch, no exported
    # ROUTER_* envs.
    cat >"${TEST_REPO}/ops/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/_build-inventory.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    grep -q '^build-inventory:ROUTER_IP=EMPTY$' "${TRACE_FILE}"
    # pwsh.exe must NOT have been invoked for KVP discovery
    # (Get-VmKvpIpAddress) because there is no router to discover for.
    ! grep -q 'Get-VmKvpIpAddress' "${TRACE_FILE}" 2>/dev/null
}

@test "router row with static ipAddress: exports ROUTER_IP from the vault, no KVP call" {
    # Static-mode router (externalDhcp=false equivalent): ipAddress is
    # already in the vault. The bridge must skip the KVP call and use
    # the static value directly.
    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    VmProvisioner)
        printf '%s' '[
            {"vmName":"router","kind":"router","ipAddress":"192.168.1.5","username":"routeradmin","password":"rp","externalSwitchName":"Ext"},
            {"vmName":"a","ipAddress":"10.99.0.10","username":"u","password":"p"}
        ]'
        ;;
    *) printf '%s' '{"stub":"vault"}' ;;
esac
STUB
    chmod +x "${TEST_REPO}/ops/_read-vault-config.sh"

    cat >"${TEST_REPO}/ops/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}:ROUTER_USERNAME=${ROUTER_USERNAME:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/_build-inventory.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    grep -q '^build-inventory:ROUTER_IP=192.168.1.5:ROUTER_USERNAME=routeradmin$' "${TRACE_FILE}"
    ! grep -q 'Get-VmKvpIpAddress' "${TRACE_FILE}" 2>/dev/null
}

@test "router row with no ipAddress (DHCP mode): discovers via Get-VmKvpIpAddress" {
    # DHCP-mode router: ipAddress absent from the vault. The bridge
    # must call Get-VmKvpIpAddress and export the discovered IP.
    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    VmProvisioner)
        printf '%s' '[
            {"vmName":"router","kind":"router","username":"routeradmin","password":"rp","externalSwitchName":"Ext"},
            {"vmName":"a","ipAddress":"10.99.0.10","username":"u","password":"p"}
        ]'
        ;;
    *) printf '%s' '{"stub":"vault"}' ;;
esac
STUB
    chmod +x "${TEST_REPO}/ops/_read-vault-config.sh"

    cat >"${TEST_REPO}/ops/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/_build-inventory.sh"

    # Force the KVP stub to a known value so we can pin the export.
    export PWSH_STUB_ROUTER_IP="192.168.1.123"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    grep -q '^build-inventory:ROUTER_IP=192.168.1.123$' "${TRACE_FILE}"
}

@test "router row exports SSHPASS for the inventory ProxyCommand, NOT ROUTER_PASSWORD" {
    # Security guard: the router password must travel to sshpass via
    # $SSHPASS at -e time, not as a ROUTER_PASSWORD env var any
    # process could log. The unset after assignment is what the
    # bridge owes the rest of the script.
    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    VmProvisioner)
        printf '%s' '[
            {"vmName":"router","kind":"router","ipAddress":"192.168.1.5","username":"routeradmin","password":"secret-rp","externalSwitchName":"Ext"},
            {"vmName":"a","ipAddress":"10.99.0.10","username":"u","password":"p"}
        ]'
        ;;
    *) printf '%s' '{"stub":"vault"}' ;;
esac
STUB
    chmod +x "${TEST_REPO}/ops/_read-vault-config.sh"

    cat >"${TEST_REPO}/ops/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:SSHPASS=${SSHPASS:-EMPTY}:ROUTER_PASSWORD=${ROUTER_PASSWORD:-UNSET}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/_build-inventory.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    grep -q '^build-inventory:SSHPASS=secret-rp:ROUTER_PASSWORD=UNSET$' "${TRACE_FILE}"
}
