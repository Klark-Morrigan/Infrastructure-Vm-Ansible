#!/usr/bin/env bash
# Operator wrapper for the create-users flow. Delegates the heavy
# lifting (tmpdir, venv activation, vault reads, inventory, extra-vars,
# dispatch) to the underscored sibling orchestrator. Forwarded args
# follow the playbook path so operators can pass --tags, --limit,
# --check, -v, etc. unchanged.
#
# The wrapper's only job beyond dispatch is to DECLARE its needs to the
# consumer-agnostic bridge through the CA_* contract: the fleet inventory
# lives in the VmProvisioner vault, and the user roles' extra-vars come
# from the VmUsers vault on top of it. The bridge names no vault itself,
# so naming them here is what couples this flow - not the substrate - to
# its own vault layout. No token and no host file server: the user flow
# needs neither.
set -euo pipefail

export CA_INVENTORY_VAULT=VmProvisioner
export CA_EXTRA_VAULTS=VmUsers

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/create-users.yml "$@"
