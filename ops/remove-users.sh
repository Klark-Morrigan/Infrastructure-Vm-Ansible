#!/usr/bin/env bash
# Operator wrapper for the remove-users flow. Mirror of create-users.sh:
# every concern (tmpdir, venv activation, vault reads, inventory,
# extra-vars, dispatch) already lives in _run-playbook.sh, so this stays
# a one-liner. Forwarded args follow the playbook path so operators can
# pass --tags, --limit, --check, -v, etc. unchanged.
#
# No confirmation prompt: the destructive intent lives in the script
# name and in the operator's choice to invoke it (decision in problem.md
# / Open Questions).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/remove-users.yml "$@"
