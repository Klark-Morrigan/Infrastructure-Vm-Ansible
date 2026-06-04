#!/usr/bin/env bash
# Composes the Ansible --extra-vars document by dispatching to one
# per-payload-domain helper per domain present, then merging their
# JSON fragments. This script owns no domain itself - it only knows
# the union of helper flags and the dispatch rules.
#
# Output shape (consumer contract; same as the pre-split version):
#
#   {
#     "vm_provisioner_config":  <provisioner JSON>,     // always
#     "vm_users_config":        <users JSON>,           // always
#     "github_runners_config":  <runners JSON>,         // when runners opt-in
#     "github_token":           "<value>"               // when runners opt-in
#   }
#
# Per-domain helpers (siblings in this directory) own their own
# validation, jq composition, and bats coverage. Adding a future
# domain (toolchain: JDK / .NET SDK / file delivery) means landing a
# new _build-extra-vars-<domain>.sh + its bats, and adding the
# dispatch arm here - no other call site changes.

set -euo pipefail

provisioner_path=""
users_path=""
runners_path=""
token=""
token_set=0

usage() {
    echo "usage: _build-extra-vars.sh --provisioner-config <path> --users-config <path>" \
         "[--runners-config <path> --github-token <value>]" >&2
}

# ---------------------------------------------------------------------------
# 1. Flag parsing. The orchestrator accepts the union of all helper
#    flags and routes them at dispatch time; helpers validate their
#    own inputs once they receive them.
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provisioner-config)
            provisioner_path="${2:-}"
            shift 2 || true
            ;;
        --users-config)
            users_path="${2:-}"
            shift 2 || true
            ;;
        --runners-config)
            runners_path="${2:-}"
            shift 2 || true
            ;;
        --github-token)
            token="${2-}"
            token_set=1
            shift 2 || true
            ;;
        *)
            echo "_build-extra-vars.sh: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "${provisioner_path}" || -z "${users_path}" ]]; then
    usage
    exit 2
fi

# Runners flags must arrive paired. Either both or neither: a config
# without a token would fail at the helper anyway, and a token alone
# would silently never reach the play. Fail loud here so the bridge
# call site, not the helper, gets the blame.
if [[ -n "${runners_path}" && "${token_set}" -ne 1 ]]; then
    echo "_build-extra-vars.sh: --runners-config requires --github-token" >&2
    exit 2
fi
if [[ "${token_set}" -eq 1 && -z "${runners_path}" ]]; then
    echo "_build-extra-vars.sh: --github-token requires --runners-config" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Dispatch. Each helper prints a one-or-more-key JSON object on
#    stdout containing only its domain's keys. Capture each fragment
#    and let jq merge them.
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fragments=()
fragments+=( "$("${script_dir}/_build-extra-vars-inventory.sh" \
                --provisioner-config "${provisioner_path}")" )
fragments+=( "$("${script_dir}/_build-extra-vars-users.sh" \
                --users-config       "${users_path}")" )
if [[ -n "${runners_path}" ]]; then
    fragments+=( "$("${script_dir}/_build-extra-vars-runners.sh" \
                    --runners-config "${runners_path}" \
                    --github-token   "${token}")" )
fi

# ---------------------------------------------------------------------------
# 3. Merge. `jq -s 'add'` reduces the stream of objects with the
#    builtin object union; later objects can override earlier keys
#    but our helpers emit disjoint key sets by design, so the merge
#    is a pure concatenation of fields.
# ---------------------------------------------------------------------------
printf '%s\n' "${fragments[@]}" | jq -s 'add'
