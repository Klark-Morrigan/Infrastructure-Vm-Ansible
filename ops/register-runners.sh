#!/usr/bin/env bash
# Operator wrapper for the register-runners flow. Unlike create-users
# and remove-users this entry owns two concerns the bridge intentionally
# does not:
#
# - Prompting for the GitHub PAT when GH_TOKEN is unset. The token
#   never enters a vault; it is supplied per-invocation. The bridge
#   stays playbook-agnostic and refuses to prompt itself - that belongs
#   at the operator edge.
# - Opting the bridge into the third vault read (GitHubRunners) via
#   NEEDS_GITHUB_RUNNERS=1. The create-users / remove-users entries
#   stay free of the extra pwsh.exe round-trip and the staging
#   pipeline they do not need.
#
# GH_TOKEN as an environment variable is the escape hatch for
# unattended callers (the E2E agent). When the variable is set the
# prompt is skipped entirely, so the same script serves both interactive
# operators and CI without branching on a flag.
#
# Forwarded args follow the playbook path so operators can pass
# --tags, --limit, --check, -v, etc. unchanged - same convention as
# create-users.sh / remove-users.sh.

set -euo pipefail

if [[ -z "${GH_TOKEN:-}" ]]; then
    # -s suppresses echo so the token never appears in the terminal
    # scrollback. -r keeps backslashes literal; some PATs contain
    # characters the line editor would otherwise re-interpret.
    read -rsp 'GitHub token: ' GH_TOKEN
    echo
    if [[ -z "${GH_TOKEN}" ]]; then
        echo 'GitHub token required' >&2
        exit 2
    fi
fi
export GH_TOKEN
export NEEDS_GITHUB_RUNNERS=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/register-runners.yml "$@"
