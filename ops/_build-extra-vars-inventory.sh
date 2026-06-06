#!/usr/bin/env bash
# Per-domain extra-vars helper: inventory.
#
# Emits the single top-level key `vm_provisioner_config` consumed by
# the playbooks and by _build-inventory.sh upstream. The inventory
# source is cross-cutting - every payload domain (users, runners,
# future toolchain) needs it - so it lives in its own helper rather
# than being folded into any one domain.
#
# Output (stdout): {"vm_provisioner_config": <document>}

set -euo pipefail

# shellcheck source=ops/_validate-extra-vars-input.sh
source "${BASH_SOURCE[0]%/*}/_validate-extra-vars-input.sh"
# shellcheck source=ops/_die-on-unknown-flag.sh
source "${BASH_SOURCE[0]%/*}/_die-on-unknown-flag.sh"

provisioner_path=""

usage() {
    echo "usage: _build-extra-vars-inventory.sh --provisioner-config <path>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provisioner-config)
            provisioner_path="${2:-}"
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag _build-extra-vars-inventory.sh "$1"
            ;;
    esac
done

if [[ -z "${provisioner_path}" ]]; then
    usage
    exit 2
fi

_validate_extra_vars_input \
    _build-extra-vars-inventory.sh \
    --provisioner-config \
    "${provisioner_path}"

# --slurpfile loads the document as a one-element array; `$p[0]`
# extracts the document so it nests directly under the canonical key.
jq -n --slurpfile p "${provisioner_path}" '{vm_provisioner_config: $p[0]}'
