#!/usr/bin/env bash
# Operator wrapper for the register-runners flow. Unlike create-users and
# remove-users this entry owns two concerns the bridge intentionally does
# not:
#
# - GitHub PAT acquisition (require_gh_token, from _require-gh-token.sh).
#   The token never enters a vault; it is supplied per-invocation. The
#   bridge stays playbook-agnostic and leaves the prompt at the operator
#   edge.
# - Opting the bridge into the third vault read (GitHubRunners) via
#   NEEDS_GITHUB_RUNNERS=1, plus the host file server (NEEDS_HOST_FILE_SERVER=1)
#   the runner-binary fetch needs. create-users / remove-users stay free of
#   both.
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
export NEEDS_GITHUB_RUNNERS=1
# Register-only opt-in: VMs fetch the actions/runner tarball from a
# Windows-side HttpListener the bridge spins up. The deregister entry leaves
# this unset because the down path fetches nothing.
export NEEDS_HOST_FILE_SERVER=1

exec "${script_dir}/_run-playbook.sh" playbooks/register-runners.yml "$@"
