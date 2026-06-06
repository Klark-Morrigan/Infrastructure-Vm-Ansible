#!/usr/bin/env bash
# Operator wrapper for the deregister-runners flow. Mirrors
# register-runners.sh: same GH_TOKEN prompt, same NEEDS_GITHUB_RUNNERS=1
# opt-in for the third vault read, same forward-all-other-args
# convention. Two deliberate differences from the register entry:
#
# - NEEDS_HOST_FILE_SERVER stays unset. The down path fetches nothing
#   from the Windows side, so spawning the HttpListener would be a
#   port and a failure surface (port-in-use, switch IP absent) for no
#   consumer.
# - The wrapper owns one flag of its own, --force, which is consumed
#   here and translated to --extra-vars runners_force_remove=true for
#   ansible-playbook. The translation lives here (not at the playbook
#   default) so the operator-facing surface stays a single switch
#   regardless of how the playbook expresses it. Mirrors today's
#   PowerShell -Force one-for-one.

set -euo pipefail

force=0
forwarded=()
while (( $# )); do
    case "$1" in
        --force) force=1 ;;
        *)       forwarded+=( "$1" ) ;;
    esac
    shift
done

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

if (( force )); then
    forwarded+=( --extra-vars 'runners_force_remove=true' )
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${script_dir}/_run-playbook.sh" playbooks/deregister-runners.yml "${forwarded[@]}"
