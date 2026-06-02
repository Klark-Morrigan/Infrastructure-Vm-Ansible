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
readonly VM_PROVISIONER_SECRET="VmProvisionerConfig"
readonly VM_USERS_VAULT="VmUsers"
readonly VM_USERS_SECRET="VmUsersConfig"

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

# ---------------------------------------------------------------------------
# 4. Vault reads. Each call validates its payload via jq empty before
#    returning, so a malformed secret fails here with the vault name
#    in the message - not later inside ansible-playbook. chmod 600 on
#    each file mirrors the tmpdir restriction.
# ---------------------------------------------------------------------------
provisioner_file="${tmpdir}/provisioner.json"
users_file="${tmpdir}/users.json"

"${script_dir}/_read-vault-config.sh" "${VM_PROVISIONER_VAULT}" "${VM_PROVISIONER_SECRET}" \
    > "${provisioner_file}"
chmod 600 "${provisioner_file}"

"${script_dir}/_read-vault-config.sh" "${VM_USERS_VAULT}" "${VM_USERS_SECRET}" \
    > "${users_file}"
chmod 600 "${users_file}"

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
"${script_dir}/_build-extra-vars.sh" \
    --provisioner-config "${provisioner_file}" \
    --users-config       "${users_file}" \
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
