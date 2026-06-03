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

setup() {
    BASH_BIN="$(command -v bash)"

    TEST_TMP="$(mktemp -d -t runPlaybook.XXXXXX)"
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

    cat >"${TEST_REPO}/ops/_read-vault-config.sh" <<'STUB'
#!/usr/bin/env bash
echo "read-vault-config:$1:$2" >> "${TRACE_FILE}"
printf '%s' '{"stub":"vault"}'
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

    chmod +x "${TEST_REPO}/ops/"_*.sh

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
    rm -rf "${TEST_TMP}"
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
