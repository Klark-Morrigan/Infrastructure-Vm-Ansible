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
    # Refuse to prompt when stdin is not a terminal. Unattended callers
    # (the E2E agent driving this via `wsl -- ...`) must supply GH_TOKEN
    # in the environment; if the variable failed to cross into WSL (e.g.
    # the name was omitted from WSLENV) the `read` below would otherwise
    # block forever on a prompt no one can answer. Failing fast turns
    # that silent hang into an immediate, actionable error.
    if [[ ! -t 0 ]]; then
        echo 'register-runners.sh: GH_TOKEN must be set for unattended use (no TTY to prompt on).' >&2
        echo '  When invoked via wsl, ensure GH_TOKEN is forwarded through WSLENV.' >&2
        exit 2
    fi
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
# Register-only opt-in: VMs fetch the actions/runner tarball from a
# Windows-side HttpListener the bridge spins up. The deregister entry
# leaves this unset because the down path fetches nothing.
export NEEDS_HOST_FILE_SERVER=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/register-runners.yml "$@"
