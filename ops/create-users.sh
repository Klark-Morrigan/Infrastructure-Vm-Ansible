#!/usr/bin/env bash
# Operator wrapper for the create-users flow. Delegates the heavy
# lifting (tmpdir, venv activation, vault reads, inventory, extra-vars,
# dispatch) to the underscored sibling orchestrator. Forwarded args
# follow the playbook path so operators can pass --tags, --limit,
# --check, -v, etc. unchanged.
#
# Kept as a one-liner on purpose - every concern this script could
# carry already lives in _run-playbook.sh. Adding logic here would
# split the bridge across two layers for no readability gain.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/create-users.yml "$@"
