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
#   _validate_extra_vars_input \
#       _build-extra-vars-inventory.sh \
#       --provisioner-config \
#       "${provisioner_path}"
_validate_extra_vars_input() {
    local script_name="$1"
    local flag_name="$2"
    local path="$3"

    if [[ ! -f "${path}" ]]; then
        echo "${script_name}: ${flag_name} file not found: ${path}" >&2
        exit 1
    fi

    if ! jq empty "${path}" >/dev/null 2>&1; then
        echo "${script_name}: ${flag_name} is not valid JSON: ${path}" >&2
        exit 1
    fi
}
