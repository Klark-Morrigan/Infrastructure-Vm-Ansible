#!/usr/bin/env bats
# Tests for ops/register-runners.sh - the operator entry that owns
# token-prompting and the NEEDS_GITHUB_RUNNERS=1 opt-in flag. Scope
# here is the prompt/flag wiring only: bridge orchestration is owned
# by _run-playbook.bats, which stubs this entry's downstream calls
# the same way this suite stubs _run-playbook.sh.
#
# The entry anchors its sibling lookup to its own BASH_SOURCE dir, so
# this suite transplants register-runners.sh into a throwaway ops/ tree
# and drops a stub _run-playbook.sh next to it; the stub records the
# invocation environment so the prompt branches can be asserted.
# Run with: bats Tests/ops/register-runners.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp registerRunners
    TEST_REPO="${TEST_TMP}/repo"
    mkdir -p "${TEST_REPO}/ops" "${TEST_REPO}/playbooks"

    cp "${REPO_ROOT}/ops/register-runners.sh" "${TEST_REPO}/ops/"
    chmod +x "${TEST_REPO}/ops/register-runners.sh"

    # Stub _run-playbook.sh records the env and argv it was invoked
    # with so the entry's prompt/export contract can be asserted
    # without running the real bridge.
    export TRACE_FILE="${TEST_TMP}/trace"
    : > "${TRACE_FILE}"

    cat >"${TEST_REPO}/ops/_run-playbook.sh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'NEEDS_GITHUB_RUNNERS=%s\n' "${NEEDS_GITHUB_RUNNERS:-}"
    printf 'GH_TOKEN=%s\n'             "${GH_TOKEN:-}"
    printf 'ARGV=%s\n'                 "$*"
} >> "${TRACE_FILE}"
STUB
    chmod +x "${TEST_REPO}/ops/_run-playbook.sh"
}

teardown() {
    _bats_cleanup_temp
}

@test "GH_TOKEN already set: no prompt, bridge sees opt-in and token" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/register-runners.sh"
    [ "${status}" -eq 0 ]
    # No prompt text leaked to stdout because the prompt branch was
    # skipped entirely.
    [[ "${output}" != *"GitHub token:"* ]]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"NEEDS_GITHUB_RUNNERS=1"* ]]
    [[ "${trace}" == *"GH_TOKEN=ghp_preset"* ]]
}

@test "GH_TOKEN unset: prompt accepts a value and the bridge receives it" {
    # Unset any inherited token so the prompt branch fires. `read -s`
    # reads from stdin; piping a value in simulates the operator typing
    # it. The trailing newline closes `read`'s line.
    run env -u GH_TOKEN "${BASH_BIN}" -c \
        "printf 'ghp_typed\n' | '${TEST_REPO}/ops/register-runners.sh'"
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"NEEDS_GITHUB_RUNNERS=1"* ]]
    [[ "${trace}" == *"GH_TOKEN=ghp_typed"* ]]
}

@test "GH_TOKEN unset and prompt rejected: exit 2, bridge never invoked" {
    # Empty prompt input -> the entry must hard-fail rather than
    # invoke the bridge with an empty token (the bridge's own gate
    # would catch it later, but failing at the operator edge keeps
    # the error message specific to the prompt).
    run env -u GH_TOKEN "${BASH_BIN}" -c \
        "printf '\n' | '${TEST_REPO}/ops/register-runners.sh'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"GitHub token required"* ]]

    # Stub never ran -> trace stays empty.
    [ ! -s "${TRACE_FILE}" ]
}

@test "extra args after the entry are forwarded verbatim to the bridge" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/register-runners.sh" \
            --tags runner_binary --check
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    # The first positional the entry hands to the bridge is the
    # playbook path; everything else follows in the same order the
    # operator supplied.
    [[ "${trace}" == *"ARGV=playbooks/register-runners.yml --tags runner_binary --check"* ]]
}
