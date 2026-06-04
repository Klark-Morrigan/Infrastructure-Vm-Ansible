#!/usr/bin/env bash
# Bash bridge between operator entry scripts and ansible-playbook.
# Thin orchestrator: validates args, sets up the per-invocation tmpdir
# (chmod 700 + EXIT trap), activates the venv, drives the three
# underscored sibling helpers under ops/, then dispatches
# ansible-playbook. Each helper has its own bats coverage; this
# script's tests focus on orchestration only.
#
# The split keeps the bridge readable and each piece independently
# testable against just its own external boundary - read-vault-config
# needs a stubbed pwsh.exe; the two pure transforms need no stubs at
# all.

set -euo pipefail

# ---------------------------------------------------------------------------
# Vault contract. Hardcoded to match Infrastructure-Secrets convention.
# Pinning both ends to constants makes a mismatch a code-review issue
# rather than a silent runtime failure.
# ---------------------------------------------------------------------------
readonly VM_PROVISIONER_VAULT="VmProvisioner"
readonly VM_USERS_VAULT="VmUsers"
readonly GITHUB_RUNNERS_VAULT="GitHubRunners"

# Required: SECRET_SUFFIX selects the lifecycle/environment whose
# secrets this run will read. Operator invocations pass `Production`;
# ephemeral fixtures (test harnesses, parallel workflows, multi-tenant
# deployments) pass their own label. Mandatory so a caller cannot
# silently fall through to a default name and collide with another
# lifecycle's data.
if [[ -z "${SECRET_SUFFIX:-}" ]]; then
    echo "_run-playbook.sh: SECRET_SUFFIX must be set (e.g. Production or the caller's lifecycle label)" >&2
    exit 2
fi
readonly VM_PROVISIONER_SECRET="VmProvisionerConfig-${SECRET_SUFFIX}"
readonly VM_USERS_SECRET="VmUsersConfig-${SECRET_SUFFIX}"
readonly GITHUB_RUNNERS_SECRET="GitHubRunnersConfig-${SECRET_SUFFIX}"

# Anchor every relative path to the repo root so the script works
# regardless of the caller's working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# ---------------------------------------------------------------------------
# 1. Argument validation. One positional arg required (the playbook
#    path); anything after it is forwarded verbatim to ansible-playbook
#    so operators can pass --tags / --limit / --check without
#    modifying the bridge.
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "usage: _run-playbook.sh <playbook-path> [ansible-playbook args...]" >&2
    exit 2
fi

playbook_path="$1"
shift

if [[ ! -f "${repo_root}/${playbook_path}" && ! -f "${playbook_path}" ]]; then
    echo "_run-playbook.sh: playbook not found: ${playbook_path}" >&2
    exit 2
fi

# Validate the GitHubRunners opt-in inputs before any vault read so a
# misconfigured caller (NEEDS_GITHUB_RUNNERS=1 without GH_TOKEN) fails
# before two pwsh.exe round-trips it would never be able to consume.
needs_github_runners=0
if [[ "${NEEDS_GITHUB_RUNNERS:-0}" == "1" ]]; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
        echo "_run-playbook.sh: NEEDS_GITHUB_RUNNERS=1 requires GH_TOKEN env var" >&2
        exit 2
    fi
    needs_github_runners=1
fi

# ---------------------------------------------------------------------------
# 2. Per-invocation tmpdir. mktemp -d under $TMPDIR (tmpfs on most
#    distros, so secrets never reach the disk-backed FS). chmod 700
#    is belt-and-braces against a misconfigured /tmp; the EXIT trap
#    guarantees cleanup on every exit path including signal-induced.
# ---------------------------------------------------------------------------
tmpdir="$(mktemp -d -t vm-ansible.XXXXXX)"
chmod 700 "${tmpdir}"
# shellcheck disable=SC2064  # expand $tmpdir at trap-install time on purpose
trap "rm -rf '${tmpdir}'" EXIT

# ---------------------------------------------------------------------------
# 3. Venv activation. Step 2's bootstrap creates .venv with the pinned
#    ansible-core; a missing venv is an operator error, not something
#    to silently work around.
# ---------------------------------------------------------------------------
venv_activate="${repo_root}/.venv/bin/activate"
if [[ ! -f "${venv_activate}" ]]; then
    echo "_run-playbook.sh: .venv missing - run ops/bootstrap-controller.{ps1,sh} first" >&2
    exit 1
fi
# shellcheck disable=SC1090  # path is computed at runtime
source "${venv_activate}"

# shellcheck source=ops/_ansible-env.sh
source "${script_dir}/_ansible-env.sh"

# ---------------------------------------------------------------------------
# 4. Vault reads. Each call validates its payload via jq empty before
#    returning, so a malformed secret fails here with the vault name
#    in the message - not later inside ansible-playbook. chmod 600 on
#    each file mirrors the tmpdir restriction. The GitHubRunners read
#    is gated by NEEDS_GITHUB_RUNNERS so the create-users / remove-users
#    entry points do not pay for a pwsh.exe round-trip they cannot
#    consume.
# ---------------------------------------------------------------------------
provisioner_file="${tmpdir}/provisioner.json"
users_file="${tmpdir}/users.json"

"${script_dir}/_read-vault-config.sh" "${VM_PROVISIONER_VAULT}" "${VM_PROVISIONER_SECRET}" \
    > "${provisioner_file}"
chmod 600 "${provisioner_file}"

"${script_dir}/_read-vault-config.sh" "${VM_USERS_VAULT}" "${VM_USERS_SECRET}" \
    > "${users_file}"
chmod 600 "${users_file}"

# Entry scripts opt in to the runners pipeline by exporting
# NEEDS_GITHUB_RUNNERS=1 (and GH_TOKEN). The bridge itself never
# prompts - the operator edge (ops/register-runners.sh) owns that.
runners_file=""
github_token=""
if [[ "${needs_github_runners}" -eq 1 ]]; then
    runners_file="${tmpdir}/runners.json"
    "${script_dir}/_read-vault-config.sh" "${GITHUB_RUNNERS_VAULT}" "${GITHUB_RUNNERS_SECRET}" \
        > "${runners_file}"
    chmod 600 "${runners_file}"

    # Lift the token into a local so we can clear GH_TOKEN from the
    # bridge's environment before invoking ansible-playbook. The
    # downstream play receives the token via the chmod-600 extra-vars
    # file only; nothing else in this process tree needs it in env.
    github_token="${GH_TOKEN}"
    unset GH_TOKEN
fi

# ---------------------------------------------------------------------------
# 5. Inventory generation. Pure stdin -> stdout transform; redirected
#    file picks up the chmod immediately.
# ---------------------------------------------------------------------------
hosts_file="${tmpdir}/hosts.json"
"${script_dir}/_build-inventory.sh" < "${provisioner_file}" > "${hosts_file}"
chmod 600 "${hosts_file}"

# ---------------------------------------------------------------------------
# 6. Extra-vars composition. Pure transform; takes file paths so the
#    payloads never appear on argv where `ps` could see them.
# ---------------------------------------------------------------------------
extra_vars_file="${tmpdir}/extra-vars.json"
extra_vars_args=(
    --provisioner-config "${provisioner_file}"
    --users-config       "${users_file}"
)
if [[ -n "${runners_file}" ]]; then
    extra_vars_args+=(
        --runners-config "${runners_file}"
        --github-token   "${github_token}"
    )
fi

"${script_dir}/_build-extra-vars.sh" "${extra_vars_args[@]}" \
    > "${extra_vars_file}"
chmod 600 "${extra_vars_file}"

# ---------------------------------------------------------------------------
# 7. Dispatch. cd to repo root so role/playbook paths resolve naturally
#    and ansible.cfg is picked up. Forwarded args follow the playbook
#    path so operator flags reach ansible-playbook unmodified.
# ---------------------------------------------------------------------------
cd "${repo_root}"
ansible-playbook \
    -i "${hosts_file}" \
    --extra-vars "@${extra_vars_file}" \
    "${playbook_path}" \
    "$@"
