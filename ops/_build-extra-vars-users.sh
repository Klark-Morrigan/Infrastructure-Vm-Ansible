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
            echo "_build-extra-vars-users.sh: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "${users_path}" ]]; then
    usage
    exit 2
fi

if [[ ! -f "${users_path}" ]]; then
    echo "_build-extra-vars-users.sh: --users-config file not found: ${users_path}" >&2
    exit 1
fi

if ! jq empty "${users_path}" >/dev/null 2>&1; then
    echo "_build-extra-vars-users.sh: --users-config is not valid JSON: ${users_path}" >&2
    exit 1
fi

jq -n --slurpfile u "${users_path}" '{vm_users_config: $u[0]}'
