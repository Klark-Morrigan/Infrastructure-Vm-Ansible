#!/usr/bin/env bash
# Per-domain extra-vars helper: users.
#
# Emits the single top-level key `vm_users_config` consumed by the
# groups / users / sudoers roles. Always-on today; could become
# opt-in if a future flow does not need users (the orchestrator
# would just stop dispatching to this helper for that flow).
#
# Output (stdout): {"vm_users_config": <document>}

set -euo pipefail

# shellcheck source=ops/_validate-extra-vars-input.sh
source "${BASH_SOURCE[0]%/*}/_validate-extra-vars-input.sh"
# shellcheck source=ops/_die-on-unknown-flag.sh
source "${BASH_SOURCE[0]%/*}/_die-on-unknown-flag.sh"

users_path=""

usage() {
    echo "usage: _build-extra-vars-users.sh --users-config <path>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --users-config)
            users_path="${2:-}"
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${users_path}" ]]; then
    usage
    exit 2
fi

_validate_extra_vars_input --users-config "${users_path}"

jq -n --slurpfile u "${users_path}" '{vm_users_config: $u[0]}'
