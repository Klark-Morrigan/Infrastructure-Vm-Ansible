#!/usr/bin/env bash
# Operator wrapper for the remove-users flow. Mirror of create-users.sh:
# every concern (tmpdir, venv activation, vault reads, inventory,
# extra-vars, dispatch) already lives in _run-playbook.sh, so this only
# declares its contract and dispatches. Forwarded args follow the
# playbook path so operators can pass --tags, --limit, --check, -v, etc.
# unchanged.
#
# Same CA_* contract as the create side - the down direction reads the
# same VmProvisioner inventory and VmUsers vault, just composing the roles
# in reverse - so the declaration is identical.
#
# No confirmation prompt: the destructive intent lives in the script
# name and in the operator's choice to invoke it (decision in problem.md
# / Open Questions).
set -euo pipefail

export CA_INVENTORY_VAULT=VmProvisioner
export CA_EXTRA_VAULTS=VmUsers

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/remove-users.yml "$@"
