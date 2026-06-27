#!/usr/bin/env bats
# Tests for ops/deregister-runners.sh - the operator entry for the
# deregister flow. Scope mirrors register-runners.bats: prompt/flag
# wiring only, plus the --force translation this entry owns. Bridge
# orchestration is owned by _run-playbook.bats, which stubs this
# entry's downstream calls the same way this suite stubs
# _run-playbook.sh.
#
# Two differences from register-runners.bats worth pinning explicitly
# (each has its own test below):
#   - CA_NEEDS_HOST_FILE_SERVER must stay unset (the down path fetches
#     nothing; spawning the HttpListener would be a port and a failure
#     surface for no consumer).
#   - --force is consumed by the wrapper and translated to
#     --extra-vars runners_force_remove=true. ansible-playbook has no
#     --force flag, so forwarding it verbatim would just produce a
#     confusing parse error.
# Run with: bats Tests/ops/deregister-runners.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp deregisterRunners
    TEST_REPO="${TEST_TMP}/repo"
    mkdir -p "${TEST_REPO}/ops" "${TEST_REPO}/playbooks"

    cp "${REPO_ROOT}/ops/deregister-runners.sh" "${TEST_REPO}/ops/"
    chmod +x "${TEST_REPO}/ops/deregister-runners.sh"
    # The entry sources ops/imports/_log.sh (cross-repo logger adapter) for
    # its log_err helper; copy the imports/ folder so the transplanted
    # script's source resolves. The adapter loads scripts/log.sh from the
    # COMMON_AUTOMATION_ROOT stub _bats_init_temp stands up.
    cp -r "${REPO_ROOT}/ops/imports" "${TEST_REPO}/ops/"
    # Shared GH_TOKEN-acquisition helper the entry sources; copy it next to
    # the transplanted script so its source resolves.
    cp "${REPO_ROOT}/ops/_require-gh-token.sh" "${TEST_REPO}/ops/"

    # Stub _run-playbook.sh records the env and argv it was invoked
    # with so the entry's prompt/export/translation contract can be
    # asserted without running the real bridge.
    export TRACE_FILE="${TEST_TMP}/trace"
    : > "${TRACE_FILE}"

    cat >"${TEST_REPO}/ops/_run-playbook.sh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'CA_INVENTORY_VAULT=%s\n'        "${CA_INVENTORY_VAULT:-}"
    printf 'CA_EXTRA_VAULTS=%s\n'           "${CA_EXTRA_VAULTS:-}"
    printf 'CA_REQUIRES_TOKEN=%s\n'         "${CA_REQUIRES_TOKEN:-}"
    printf 'CA_NEEDS_HOST_FILE_SERVER=%s\n' "${CA_NEEDS_HOST_FILE_SERVER:-}"
    printf 'GH_TOKEN=%s\n'                  "${GH_TOKEN:-}"
    printf 'ARGV=%s\n'                      "$*"
} >> "${TRACE_FILE}"
STUB
    chmod +x "${TEST_REPO}/ops/_run-playbook.sh"
}

teardown() {
    _bats_cleanup_temp
}

@test "GH_TOKEN already set: no prompt, contract correct, no force" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"GitHub token:"* ]]

    trace="$(cat "${TRACE_FILE}")"
    # Same runner contract as register, minus the host file server.
    [[ "${trace}" == *"CA_INVENTORY_VAULT=VmProvisioner"* ]]
    [[ "${trace}" == *"CA_EXTRA_VAULTS=GitHubRunners"* ]]
    [[ "${trace}" == *"CA_REQUIRES_TOKEN=1"* ]]
    # File-server gate must be empty on the down path - the down
    # roles fetch nothing and the listener would be pure overhead.
    [[ "${trace}" == *"CA_NEEDS_HOST_FILE_SERVER="$'\n'* ]]
    [[ "${trace}" == *"GH_TOKEN=ghp_preset"* ]]
    # No --force on this invocation -> no runners_force_remove
    # extra-var in the forwarded argv.
    [[ "${trace}" != *"runners_force_remove"* ]]
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml"* ]]
}

@test "GH_TOKEN unset and stdin not a TTY: fast-fails with exit 2, bridge never invoked" {
    # Shares require_gh_token with register-runners, so the same
    # unattended-hang guard applies: no GH_TOKEN + non-interactive stdin
    # must fail immediately rather than block on a `read` prompt no
    # automated caller can answer. bats stdin is never a TTY, so piping
    # exercises the `! -t 0` branch; the interactive prompt branch is not
    # reachable headlessly and is verified manually.
    run env -u GH_TOKEN "${BASH_BIN}" -c \
        "printf '' | '${TEST_REPO}/ops/deregister-runners.sh'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"GH_TOKEN must be set for unattended use"* ]]

    # Stub never ran -> trace stays empty.
    [ ! -s "${TRACE_FILE}" ]
}

@test "--force is consumed and translated to runners_force_remove=true" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh" --force
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    # ansible-playbook does not own a --force flag; the wrapper must
    # convert it. The literal --force should NOT appear in the
    # forwarded argv.
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml --extra-vars runners_force_remove=true"* ]]
    [[ "${trace}" != *"--force"* ]]
}

@test "Other args (--tags, --check, -v) are forwarded verbatim" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh" \
            --tags runner_binary --check -v
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml --tags runner_binary --check -v"* ]]
}

@test "--force plus extra args: translation and forwarding compose" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh" \
            --force --tags runner_binary --check
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    # Forwarded args land before the wrapper's appended extra-vars
    # pair (the wrapper appends --force translation last), so the
    # combined argv keeps the operator's verbatim flags first.
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml --tags runner_binary --check --extra-vars runners_force_remove=true"* ]]
}
