#!/usr/bin/env bash
# Operator wrapper for the deregister-runners flow. Mirrors
# register-runners.sh: same GH_TOKEN acquisition (require_gh_token), same
# NEEDS_GITHUB_RUNNERS=1 opt-in for the third vault read, same
# forward-all-other-args convention. Two deliberate differences from the
# register entry:
#
# - NEEDS_HOST_FILE_SERVER stays unset. The down path fetches nothing from
#   the Windows side, so spawning the HttpListener would be a port and a
#   failure surface (port-in-use, switch IP absent) for no consumer.
# - The wrapper owns one flag of its own, --force, consumed here and
#   translated to --extra-vars runners_force_remove=true for
#   ansible-playbook. The translation lives here (not at the playbook
#   default) so the operator-facing surface stays a single switch
#   regardless of how the playbook expresses it. Mirrors today's PowerShell
#   -Force one-for-one.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=ops/_require-gh-token.sh
source "${script_dir}/_require-gh-token.sh"

force=0
forwarded=()
while (( $# )); do
    case "$1" in
        --force) force=1 ;;
        *)       forwarded+=( "$1" ) ;;
    esac
    shift
done

require_gh_token
export NEEDS_GITHUB_RUNNERS=1

if (( force )); then
    forwarded+=( --extra-vars 'runners_force_remove=true' )
fi

exec "${script_dir}/_run-playbook.sh" playbooks/deregister-runners.yml "${forwarded[@]}"
