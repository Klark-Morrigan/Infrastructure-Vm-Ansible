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
             "${TEST_REPO}/ops/virtual-machines" \
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
    # The consumer-contract parser is a pure env -> stdout transform whose
    # only dependency is the stubbed logger, so copy the genuine file
    # rather than stub it: that exercises the real bridge -> parser wiring
    # (which CA_* the bridge forwards, how it parses the KEY=value lines
    # back) end to end. Its own internals are covered by
    # _parse-consumer-contract.bats.
    cp "${REPO_ROOT}/ops/_parse-consumer-contract.sh" "${TEST_REPO}/ops/"
    # The bridge sources the router-resolution module from
    # ops/virtual-machines/; copy the real one (a pure resolver whose only
    # externals - pwsh.exe, nc, the reachability helper - are stubbed
    # below) so the router tests exercise the genuine resolution and the
    # bridge -> module wiring. The inventory / staging / reachability
    # helpers it neighbours are stubbed into the same virtual-machines/
    # dir further down.
    cp "${REPO_ROOT}/ops/virtual-machines/_resolve-router.sh" \
        "${TEST_REPO}/ops/virtual-machines/"
    # ops/imports/ holds the cross-repo adapter shims the orchestrator
    # sources (_log.sh for log_info/log_err, _to-windows-path.sh for
    # cleanup's pwsh path) plus their shared root resolver - copy the whole
    # folder so the transplanted script's `source ${script_dir}/imports/*`
    # lookups resolve. The adapters load scripts/log.sh and
    # scripts/_to-windows-path.sh from the COMMON_AUTOMATION_ROOT stub
    # _bats_init_temp / this setup stand up.
    cp -r "${REPO_ROOT}/ops/imports"            "${TEST_REPO}/ops/"
    cp "${REPO_ROOT}/Tests/playbooks/_noop.yml" "${TEST_REPO}/playbooks/"
    chmod +x "${TEST_REPO}/ops/_run-playbook.sh"

    # _to_windows_path now lives in Common-Automation, an external
    # abstraction to this orchestrator, so it is mocked here (its real
    # behavior is unit-tested in Common-Automation/scripts/_to-windows-path.bats).
    # The stub goes in a fake COMMON_AUTOMATION_ROOT so the orchestrator's
    # sibling-source wiring is still exercised end to end - CI has no real
    # ../Common-Automation checkout for this repo, so the env override is
    # what keeps the source resolvable. The pwsh.exe stub ignores the path
    # it receives, so a passthrough is all cleanup() needs.
    export COMMON_AUTOMATION_ROOT="${TEST_TMP}/Common-Automation"
    mkdir -p "${COMMON_AUTOMATION_ROOT}/scripts"
    cat >"${COMMON_AUTOMATION_ROOT}/scripts/_to-windows-path.sh" <<'STUB'
#!/usr/bin/env bash
_to_windows_path() { printf '%s' "$1"; }
STUB

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

    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
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
    cat >"${TEST_REPO}/ops/virtual-machines/_stage-host-fileserver.sh" <<'STUB'
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

    # Router reachability probe (step 4c) stubbed at the orchestrator
    # boundary - its nc/ssh internals have their own bats file
    # (_assert-router-reachable.bats). Records the IP/port it was handed
    # so the dispatch contract can be asserted; ASSERT_REACHABLE_STUB_EXIT
    # drives the abort-on-unreachable path. Defaults to reachable so the
    # router-row tests below proceed to dispatch.
    cat >"${TEST_REPO}/ops/virtual-machines/_assert-router-reachable.sh" <<'STUB'
#!/usr/bin/env bash
echo "assert-router-reachable:$*" >> "${TRACE_FILE}"
exit "${ASSERT_REACHABLE_STUB_EXIT:-0}"
STUB

    chmod +x "${TEST_REPO}/ops/"_*.sh
    chmod +x "${TEST_REPO}/ops/virtual-machines/"_*.sh

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
        *portproxy*)
            # WSL-detection block's portproxy auto-discovery. Only
            # reached when bats itself runs under WSL (the wrapper's
            # native path), where /proc/version matches 'microsoft' and
            # the bridge probes netsh for a listen port. There is no real
            # portproxy on the test host, so emit nothing: portproxy_port
            # stays empty, the bridge keeps the vault ROUTER_IP without a
            # rewrite, and the router path stays identical to the Linux/CI
            # run where this block is skipped entirely.
            exit 0
            ;;
        *)
            echo "pwsh-stub: unhandled -Command payload" >&2
            exit 99
            ;;
    esac
fi
# The bridge now hands pwsh.exe a Windows path (wslpath -w), so strip the
# last path component on either separator rather than using basename, which
# keys on '/' alone and would leave a backslash path intact.
case "${file##*[\\/]}" in
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

    # Start every test from a clean consumer contract so a value the
    # harness happens to export (e.g. a real GH_TOKEN, or a CA_* left by
    # the operator shell) cannot mask a default-path assertion. Tests
    # that exercise a contract set the CA_* vars they need explicitly.
    unset CA_INVENTORY_VAULT CA_EXTRA_VAULTS CA_NEEDS_HOST_FILE_SERVER \
          CA_REQUIRES_TOKEN CA_HOST_FILE_SERVER_DIR CA_HOST_FILE_SERVER_VERSION \
          GH_TOKEN

    # CA_INVENTORY_VAULT is the one required contract field (the bridge
    # always reads an inventory and names no vault itself). Default it to
    # VmProvisioner so every test exercises a valid baseline; the stubbed
    # _read-vault-config keys its inventory payload on this name. Tests
    # about its absence or a non-default name override it explicitly.
    export CA_INVENTORY_VAULT=VmProvisioner
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

@test "CA_CONSUMER_ROOT runs the consumer's own playbook and tells the composer where its fragment lives" {
    # A consumer that owns its playbook/roles/fragment declares its root. The
    # playbook lives ONLY under the consumer root (the substrate has no copy),
    # so a successful dispatch of it proves the bridge resolved from there;
    # the composer is handed --consumer-root so the per-domain fragment
    # resolves from the consumer too.
    consumer="${TEST_TMP}/consumer"
    mkdir -p "${consumer}/playbooks" "${consumer}/roles"
    cp "${TEST_REPO}/playbooks/_noop.yml" "${consumer}/playbooks/own.yml"
    export CA_EXTRA_VAULTS=Toolchains
    export CA_CONSUMER_ROOT="${consumer}"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/own.yml
    [ "${status}" -eq 0 ]

    # Composer told where the consumer-owned fragment lives.
    [[ "$(cat "${TRACE_FILE}")" == *"build-extra-vars:"*"--consumer-root ${consumer}"* ]]
    # Dispatch ran the consumer's own playbook, resolved under its root.
    [[ "$(cat "${ANSIBLE_PLAYBOOK_STUB_LOG}")" == *"${consumer}/playbooks/own.yml"* ]]
}

@test "CA_CONSUMER_ROOT set to a non-existent directory aborts before any vault read" {
    export CA_CONSUMER_ROOT="${TEST_TMP}/nope"
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CA_CONSUMER_ROOT is set but not a directory"* ]]
    # Aborted before the pipeline ran - no sibling fired, no tmpdir leaked.
    [ ! -s "${TRACE_FILE}" ]
}

@test "happy path invokes the siblings in order then dispatches ansible-playbook" {
    # A consumer that declares a single extra vault
    # (CA_EXTRA_VAULTS=Toolchains) reads the always-on provisioner vault
    # plus the declared extra vault, builds inventory, then composes
    # extra-vars with the provisioner config and a generic --vault-config
    # pair. The bridge is vault-agnostic, so the name is just a sample.
    export CA_EXTRA_VAULTS=Toolchains

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml --check
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:VmProvisioner:VmProvisionerConfig"* ]]
    [[ "${trace}" == *"read-vault-config:Toolchains:ToolchainsConfig"* ]]
    [[ "${trace}" == *"build-inventory"* ]]
    [[ "${trace}" == *"build-extra-vars:"*"--provisioner-config"*"--vault-config"*"Toolchains="* ]]

    # Order check via line numbers - awk for clarity. The pipeline is
    # provisioner read -> extra-vault read -> inventory build -> extra-vars
    # compose; any reorder would break downstream expectations.
    [ "$(awk '/^read-vault-config:VmProvisioner:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^read-vault-config:Toolchains:/{print NR; exit}' "${TRACE_FILE}")" ]
    [ "$(awk '/^read-vault-config:Toolchains:/{print NR; exit}' "${TRACE_FILE}")" -lt \
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

@test "empty contract reads only the declared inventory vault and surfaces no extra keys" {
    # Default entry points with no CA_EXTRA_VAULTS (and no toggles) must
    # not pay for any extra vault read or surface runner keys. Only the
    # contract-declared inventory vault is read.
    unset CA_EXTRA_VAULTS CA_NEEDS_HOST_FILE_SERVER CA_REQUIRES_TOKEN

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:VmProvisioner:VmProvisionerConfig"* ]]
    [[ "${trace}" != *"read-vault-config:Toolchains:"* ]]
    [[ "${trace}" != *"read-vault-config:GitHubRunners:"* ]]
    [[ "${trace}" != *"--vault-config"* ]]
    [[ "${trace}" != *"--github-token"* ]]
}

@test "the bridge reads whatever inventory vault the contract names, not a baked-in one" {
    # The substrate names no vault: CA_INVENTORY_VAULT selects which vault
    # holds the fleet, and the bridge derives <Name>Config-<suffix> from
    # it. A non-default name must flow straight through to the read.
    export CA_INVENTORY_VAULT=FleetVaultX
    unset CA_EXTRA_VAULTS CA_NEEDS_HOST_FILE_SERVER CA_REQUIRES_TOKEN

    # The inventory payload must be a VM array (router resolution and
    # _build-inventory both parse it), so key the stub's array on the
    # non-default inventory vault name this test uses.
    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
echo "read-vault-config:$1:$2" >> "${TRACE_FILE}"
case "$1" in
    FleetVaultX)
        printf '%s' '[{"vmName":"a","ipAddress":"10.10.0.50","username":"u","password":"p"}]'
        ;;
    *)
        printf '%s' '{"stub":"vault"}'
        ;;
esac
STUB
    chmod +x "${TEST_REPO}/ops/_read-vault-config.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:FleetVaultX:FleetVaultXConfig-Test"* ]]
    [[ "${trace}" != *"read-vault-config:VmProvisioner:"* ]]
}

@test "a missing inventory vault aborts before any vault read" {
    # CA_INVENTORY_VAULT is required; with it unset the contract parser
    # rejects and the bridge bails before standing up the tmpdir or
    # reading any vault.
    unset CA_INVENTORY_VAULT CA_EXTRA_VAULTS CA_NEEDS_HOST_FILE_SERVER CA_REQUIRES_TOKEN

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CA_INVENTORY_VAULT"* ]]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" != *"read-vault-config"* ]]
}

@test "CA_EXTRA_VAULTS=GitHubRunners with a token reads the vault and threads both keys" {
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export GH_TOKEN="ghp_example"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:VmProvisioner:VmProvisionerConfig"* ]]
    [[ "${trace}" == *"read-vault-config:GitHubRunners:GitHubRunnersConfig"* ]]
    [[ "${trace}" == *"--vault-config"*"GitHubRunners="* ]]
    [[ "${trace}" == *"--github-token"*"ghp_example"* ]]

    # The extra-vault read must come after the provisioner read so a
    # partial failure of the extra vault leaves the provisioner read's
    # diagnostics intact.
    [ "$(awk '/^read-vault-config:VmProvisioner:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^read-vault-config:GitHubRunners:/{print NR; exit}' "${TRACE_FILE}")" ]
}

@test "CA_EXTRA_VAULTS=GitHubRunners with a token but no file server skips staging (deregister shape)" {
    # The deregister entry declares GitHubRunners + a token but not the
    # host file server, because nothing is fetched on the down path. The
    # extra vault read still fires, the staging helper does not, and the
    # composer does not receive the file-server pair.
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export GH_TOKEN="ghp_example"
    unset CA_NEEDS_HOST_FILE_SERVER

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"read-vault-config:GitHubRunners:"* ]]
    [[ "${trace}" != *"stage-host-fileserver:"* ]]
    [[ "${trace}" != *"--host-base-url"* ]]
    [[ "${trace}" != *"--runner-version"* ]]
    [[ "${trace}" != *"stop-host-file-server"* ]]
}

@test "CA_NEEDS_HOST_FILE_SERVER=1 without a token fails fast" {
    # Every flow that opts into the host file server also declares a token
    # (its downstream play consumes one). The bridge ties the two flags
    # together and rejects a file-server opt-in without a token before any
    # vault read or listener stand-up.
    export CA_NEEDS_HOST_FILE_SERVER=1
    unset CA_REQUIRES_TOKEN
    unset GH_TOKEN

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CA_NEEDS_HOST_FILE_SERVER"* ]]
    [[ "${output}" == *"CA_REQUIRES_TOKEN"* ]]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" != *"read-vault-config"* ]]
}

@test "CA_REQUIRES_TOKEN=1 without GH_TOKEN fails fast with a clear message" {
    # The bridge itself never prompts - that is the operator entry's
    # job. The contract parser refuses the call here, louder than
    # silently emitting an empty token downstream.
    export CA_REQUIRES_TOKEN=1
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
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
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

@test "CA_NEEDS_HOST_FILE_SERVER=1 hands the serve-only staging helper the consumer-staged directory and version, not a token" {
    # The consumer pre-stages the directory and resolves the version
    # (CA_HOST_FILE_SERVER_DIR / CA_HOST_FILE_SERVER_VERSION); the bridge
    # hands both to the serve-only helper. No token is forwarded to it - the
    # helper fetches nothing, so the token has no consumer there (it still
    # reaches the registration play via the composer).
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export CA_NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"
    export CA_HOST_FILE_SERVER_DIR='C:\Users\Test\runner-cache'
    export CA_HOST_FILE_SERVER_VERSION="3.1.4"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    stage_line="$(grep '^stage-host-fileserver:' "${TRACE_FILE}")"
    [[ "${stage_line}" == *"--provisioner-config"* ]]
    [[ "${stage_line}" == *"--listener-log"* ]]
    [[ "${stage_line}" == *'--staging-dir'*'C:\Users\Test\runner-cache'* ]]
    [[ "${stage_line}" == *"--runner-version"*"3.1.4"* ]]
    # The serve-only helper never receives the token.
    [[ "${stage_line}" != *"--github-token"* ]]

    # Staging fires between the extra-vault read and extra-vars compose;
    # any reorder would corrupt the extra-vars payload.
    [ "$(awk '/^read-vault-config:GitHubRunners:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^stage-host-fileserver:/{print NR; exit}'           "${TRACE_FILE}")" ]
    [ "$(awk '/^stage-host-fileserver:/{print NR; exit}' "${TRACE_FILE}")" -lt \
      "$(awk '/^build-extra-vars:/{print NR; exit}'      "${TRACE_FILE}")" ]
}

@test "CA_NEEDS_HOST_FILE_SERVER=1 threads BASE_URL + runner_version into extra-vars" {
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export CA_NEEDS_HOST_FILE_SERVER=1
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
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export CA_NEEDS_HOST_FILE_SERVER=1
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
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export CA_NEEDS_HOST_FILE_SERVER=1
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
    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export CA_NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"
    export STAGE_STUB_EXIT=7

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]

    # ansible-playbook stub records argv to this file when invoked;
    # the file must be absent because the bridge bailed before the
    # dispatch step.
    [ ! -s "${ANSIBLE_PLAYBOOK_STUB_LOG}" ]
}

@test "Git Bash launch re-execs the bridge under the WSL controller" {
    # The menu (Invoke-BashScript) and register-runners.bat launch this under
    # Git Bash, where the venv / nc / relay-redirect toolchain does not
    # exist. A MINGW/MSYS uname must re-exec self under `wsl --` rather than
    # run here. Stub uname -> MINGW and wsl.exe -> a recorder so the re-exec
    # wiring is asserted without a real WSL. The re-exec sits before the
    # EXIT trap and tmpdir setup, so nothing local is touched.
    cat >"${TEST_TMP}/stubs/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo "MINGW64_NT-10.0-26200"; else exec /usr/bin/uname "$@"; fi
STUB
    cat >"${TEST_TMP}/stubs/wsl.exe" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${TEST_TMP}/wsl-args"
exit 0
STUB
    chmod +x "${TEST_TMP}/stubs/uname" "${TEST_TMP}/stubs/wsl.exe"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml --check

    [ "${status}" -eq 0 ]
    # Re-exec fired: the recorder captured the bridge plus the original args.
    [ -f "${TEST_TMP}/wsl-args" ]
    grep -q '_run-playbook.sh'    "${TEST_TMP}/wsl-args"
    grep -q 'playbooks/_noop.yml' "${TEST_TMP}/wsl-args"
    grep -q -- '--check'          "${TEST_TMP}/wsl-args"
    # And nothing ran in the Git Bash process - the siblings never fired.
    [ ! -s "${TRACE_FILE}" ]
}

@test "tmpdir is removed when a sibling fails mid-pipeline" {
    # Replace the inventory stub with a failing one to exercise the
    # EXIT trap on the unhappy path.
    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "boom" >&2
exit 1
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_build-inventory.sh"

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
    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_build-inventory.sh"

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

    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}:ROUTER_USERNAME=${ROUTER_USERNAME:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_build-inventory.sh"

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

    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_build-inventory.sh"

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

    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:SSHPASS=${SSHPASS:-EMPTY}:ROUTER_PASSWORD=${ROUTER_PASSWORD:-UNSET}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_build-inventory.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    grep -q '^build-inventory:SSHPASS=secret-rp:ROUTER_PASSWORD=UNSET$' "${TRACE_FILE}"
}

# A router row routes the bridge through step 4c's reachability probe.
_write_router_vault() {
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
}

@test "router row drives the reachability probe with the resolved IP and port" {
    _write_router_vault
    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]
    # ROUTER_PORT is unset on this path (no WSL portproxy rewrite), so the
    # orchestrator passes the static IP and the default 22.
    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"assert-router-reachable:192.168.1.5 22"* ]]
}

@test "router reachability failure aborts the bridge before ansible-playbook" {
    _write_router_vault
    export ASSERT_REACHABLE_STUB_EXIT=1   # probe reports the hop unreachable

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -ne 0 ]
    # Aborted before dispatch - the ansible-playbook stub never recorded argv.
    [ ! -s "${ANSIBLE_PLAYBOOK_STUB_LOG}" ]
}

@test "WSL portproxy rewrite redirects only the SSH endpoint, not the router's LAN IP" {
    # Regression guard for the overloaded-ROUTER_IP bug: ROUTER_IP is the
    # router's topological LAN IP and feeds Get-VmSwitchHostIp inside
    # _stage-host-fileserver.sh to bind the host file server on the
    # router's upstream adapter. The WSL portproxy redirect must rewrite
    # only the SSH endpoint (ROUTER_SSH_HOST); clobbering ROUTER_IP fed
    # the host's own WSL adapter to Get-VmSwitchHostIp and the staging
    # step failed with "returned empty".
    #
    # The redirect only runs when /proc/version reports a WSL kernel; on a
    # plain Linux CI runner the block is skipped entirely, so there is no
    # rewrite to assert and the test is skipped honestly rather than
    # validating a no-op.
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
        skip "WSL portproxy rewrite path is only reachable under a WSL kernel"
    fi

    export CA_EXTRA_VAULTS=GitHubRunners
    export CA_REQUIRES_TOKEN=1
    export CA_NEEDS_HOST_FILE_SERVER=1
    export GH_TOKEN="ghp_example"

    # Static-IP router so resolution takes the no-KVP branch and ROUTER_IP
    # starts as the LAN IP 192.168.1.5.
    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
echo "read-vault-config:$1:$2" >> "${TRACE_FILE}"
case "$1" in
    VmProvisioner)
        printf '%s' '[
            {"vmName":"router","kind":"router","ipAddress":"192.168.1.5","username":"routeradmin","password":"rp","externalSwitchName":"Ext"},
            {"vmName":"a","ipAddress":"10.10.0.50","username":"u","password":"p"}
        ]'
        ;;
    *) printf '%s' '{"stub":"vault"}' ;;
esac
STUB
    chmod +x "${TEST_REPO}/ops/_read-vault-config.sh"

    # pwsh.exe override: the portproxy discovery returns a listen port so
    # the WSL branch performs the rewrite. The stop-host-file-server -File
    # path (EXIT trap) is preserved so cleanup stays quiet.
    cat >"${TEST_TMP}/stubs/pwsh.exe" <<'STUB'
#!/usr/bin/env bash
cmd=""; file=""; process_id=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -File)      file="$2";       shift 2 ;;
        -Command)   cmd="$2";        shift 2 ;;
        -ProcessId) process_id="$2"; shift 2 ;;
        *)          shift ;;
    esac
done
if [[ -n "${cmd}" ]]; then
    case "${cmd}" in
        *portproxy*) echo "2222"; exit 0 ;;
        *) echo "pwsh-stub: unhandled -Command payload" >&2; exit 99 ;;
    esac
fi
case "${file##*[\\/]}" in
    _stop-host-file-server.ps1)
        echo "stop-host-file-server:${process_id}" >> "${TRACE_FILE}" ;;
    *) echo "pwsh-stub: unhandled file=${file}" >&2; exit 99 ;;
esac
STUB
    chmod +x "${TEST_TMP}/stubs/pwsh.exe"

    # nc stub succeeds on the 127.0.0.1 probe so target_ip stays
    # 127.0.0.1 (deterministic) instead of falling back to the host's WSL
    # gateway, whose address varies per machine.
    cat >"${TEST_TMP}/stubs/nc" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${TEST_TMP}/stubs/nc"

    # Both consumers record the addresses they were handed post-rewrite.
    cat >"${TEST_REPO}/ops/virtual-machines/_build-inventory.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "build-inventory:ROUTER_IP=${ROUTER_IP:-EMPTY}:ROUTER_SSH_HOST=${ROUTER_SSH_HOST:-EMPTY}:ROUTER_PORT=${ROUTER_PORT:-EMPTY}" >> "${TRACE_FILE}"
printf '%s' '{"stub":"inventory"}'
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_build-inventory.sh"

    cat >"${TEST_REPO}/ops/virtual-machines/_stage-host-fileserver.sh" <<'STUB'
#!/usr/bin/env bash
echo "stage-host-fileserver:ROUTER_IP=${ROUTER_IP:-EMPTY}" >> "${TRACE_FILE}"
printf 'RUNNER_VERSION=%s\n' "2.999.0"
printf 'BASE_URL=%s\n'        "http://10.10.0.1:8745"
printf 'PID=%s\n'             "12345"
STUB
    chmod +x "${TEST_REPO}/ops/virtual-machines/_stage-host-fileserver.sh"

    run "${BASH_BIN}" "${TEST_REPO}/ops/_run-playbook.sh" playbooks/_noop.yml
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    # The staging helper still sees the router's true LAN IP for the
    # Get-VmSwitchHostIp host-adapter lookup ...
    [[ "${trace}" == *"stage-host-fileserver:ROUTER_IP=192.168.1.5"* ]]
    # ... while the SSH consumers route through the portproxy endpoint.
    [[ "${trace}" == *"build-inventory:ROUTER_IP=192.168.1.5:ROUTER_SSH_HOST=127.0.0.1:ROUTER_PORT=2222"* ]]
    [[ "${trace}" == *"assert-router-reachable:127.0.0.1 2222"* ]]
}
