#!/usr/bin/env bash
# Shared input gate for the per-domain extra-vars helpers
# (_build-extra-vars-{inventory,users,runners}.sh). Two checks
# - file exists, file parses as JSON via `jq empty` - share the same
# fail-fast contract (exit 1, "<script>: <flag> ...: <path>" on stderr)
# across every domain helper, so they live in one place and cannot
# drift.
#
# Sourced (not exec'd) so the function exits the calling script on
# failure - matching the inline behaviour it replaces.
#
# Caller pattern:
#   source "${BASH_SOURCE[0]%/*}/_validate-extra-vars-input.sh"
#   _validate_extra_vars_input --provisioner-config "${provisioner_path}"
#
# The script name in the message is supplied by the shared logger
# (BASH_SOURCE[-1]), so callers pass only the flag and the path.
# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"

_validate_extra_vars_input() {
    local flag_name="$1"
    local path="$2"

    if [[ ! -f "${path}" ]]; then
        log_err "${flag_name} file not found: ${path}"
        exit 1
    fi

    if ! jq empty "${path}" >/dev/null 2>&1; then
        log_err "${flag_name} is not valid JSON: ${path}"
        exit 1
    fi
}
