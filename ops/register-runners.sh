#!/usr/bin/env bash
# Operator wrapper for the register-runners flow. Unlike create-users and
# remove-users this entry owns one concern the bridge intentionally does
# not:
#
# - GitHub PAT acquisition (require_gh_token, from _require-gh-token.sh).
#   The token never enters a vault; it is supplied per-invocation. The
#   bridge stays playbook-agnostic and leaves the prompt at the operator
#   edge.
#
# Everything else it declares through the CA_* consumer contract: the
# VmProvisioner inventory vault, the GitHubRunners vault on top of it
# (CA_EXTRA_VAULTS), the GitHub token requirement (CA_REQUIRES_TOKEN=1, so
# the bridge fails fast if require_gh_token somehow left GH_TOKEN unset),
# and the host file server the runner-binary fetch needs
# (CA_NEEDS_HOST_FILE_SERVER=1). create-users / remove-users declare
# neither the token nor the file server.
#
# Forwarded args follow the playbook path so operators can pass --tags,
# --limit, --check, -v, etc. unchanged - same convention as create-users.sh
# / remove-users.sh.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=ops/_require-gh-token.sh
source "${script_dir}/_require-gh-token.sh"

require_gh_token

export CA_INVENTORY_VAULT=VmProvisioner
export CA_EXTRA_VAULTS=GitHubRunners
export CA_REQUIRES_TOKEN=1
# Register-only opt-in: VMs fetch the actions/runner tarball from a
# Windows-side HttpListener the bridge spins up. The deregister entry leaves
# this unset because the down path fetches nothing.
export CA_NEEDS_HOST_FILE_SERVER=1

exec "${script_dir}/_run-playbook.sh" playbooks/register-runners.yml "$@"
