#!/usr/bin/env bash
# Operator wrapper: report whether each declared GitHub Actions runner is
# "up" - its on-VM systemd unit is active AND GitHub shows it online.
#
# Read-only counterpart to register-runners.sh / deregister-runners.sh: same
# GH_TOKEN acquisition (require_gh_token) and the same
# CA_EXTRA_VAULTS=GitHubRunners + CA_REQUIRES_TOKEN=1 contract for the
# GitHubRunnersConfig vault read the status play needs. No --force / no host
# file server - nothing is changed or fetched. Every other arg is forwarded
# to ansible-playbook, so `--limit ubuntu-02-ci` narrows the check to one VM.
#
# Report-only: a DOWN runner is a normal result, so the exit code mirrors
# ansible-playbook's - 0 on a clean run even with runners down, non-zero only
# on an actual error (missing token, unreachable controller, malformed config).

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

# The play colours its UP/DOWN report with ANSI inside debug msgs, but
# Ansible's default callback JSON-encodes task results, so each ESC byte
# arrives here as a literal backslash-u-001b escape (so a red marker shows
# up as the visible text [31m). Translate it back to a real ESC so the
# green / red renders. The translation lives in the wrapper, not the play,
# because only this read-only report colours its output.
#
# Piping disables Ansible's own PLAY / TASK colour (its stdout is no longer a
# TTY), so force it back on and forward the flag across the WSL re-exec
# (_run-playbook.sh appends its own vars to WSLENV). pipefail keeps the
# playbook's exit code as this script's - sed never fails.
export ANSIBLE_FORCE_COLOR=1
export WSLENV="${WSLENV:+${WSLENV}:}ANSIBLE_FORCE_COLOR"

esc="$(printf '\033')"
"${script_dir}/_run-playbook.sh" playbooks/runner-status.yml "$@" \
    | sed "s/\\\\u001b/${esc}/g"
