#!/usr/bin/env bash
# Composes the Ansible --extra-vars document by dispatching to one
# per-payload-domain helper per domain present, then merging their
# JSON fragments. This script owns no domain itself - it only knows
# the union of helper flags and the dispatch rules.
#
# Output shape (consumer contract):
#
#   {
#     "vm_provisioner_config":     <provisioner JSON>,  // always
#     "vm_users_config":           <users JSON>,        // always
#     "github_runners_config":     <runners JSON>,      // when runners opt-in
#     "github_token":              "<value>",           // when runners opt-in
#     "host_file_server_base_url": "<url>",             // when runners opt-in
#     "runner_version":            "<x.y.z>"            // when runners opt-in
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
host_base_url=""
host_base_url_set=0
runner_version=""
runner_version_set=0

usage() {
    echo "usage: _build-extra-vars.sh --provisioner-config <path> --users-config <path>" \
         "[--runners-config <path> --github-token <value>" \
         "--host-base-url <url> --runner-version <ver>]" >&2
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
        --host-base-url)
            host_base_url="${2-}"
            host_base_url_set=1
            shift 2 || true
            ;;
        --runner-version)
            runner_version="${2-}"
            runner_version_set=1
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

# Runners flags must arrive as a complete set. Any one of the four
# implies all four: a config without a token would fail at the helper
# anyway; a token, URL, or version alone would silently never reach
# the play. Fail loud here so the bridge call site, not the helper,
# gets the blame.
runners_any=0
runners_all=1
for flag_set in "${token_set}" "${host_base_url_set}" "${runner_version_set}"; do
    if [[ "${flag_set}" -eq 1 ]]; then runners_any=1
    else                                runners_all=0
    fi
done
if [[ -n "${runners_path}" ]]; then runners_any=1
else                                runners_all=0
fi

if [[ "${runners_any}" -eq 1 && "${runners_all}" -ne 1 ]]; then
    echo "_build-extra-vars.sh: --runners-config, --github-token, --host-base-url," \
         "--runner-version must be supplied together" >&2
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
                    --github-token   "${token}" \
                    --host-base-url  "${host_base_url}" \
                    --runner-version "${runner_version}")" )
fi

# ---------------------------------------------------------------------------
# 3. Merge. `jq -s 'add'` reduces the stream of objects with the
#    builtin object union; later objects can override earlier keys
#    but our helpers emit disjoint key sets by design, so the merge
#    is a pure concatenation of fields.
# ---------------------------------------------------------------------------
printf '%s\n' "${fragments[@]}" | jq -s 'add'
