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
            echo "_build-extra-vars-inventory.sh: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "${provisioner_path}" ]]; then
    usage
    exit 2
fi

if [[ ! -f "${provisioner_path}" ]]; then
    echo "_build-extra-vars-inventory.sh: --provisioner-config file not found: ${provisioner_path}" >&2
    exit 1
fi

if ! jq empty "${provisioner_path}" >/dev/null 2>&1; then
    echo "_build-extra-vars-inventory.sh: --provisioner-config is not valid JSON: ${provisioner_path}" >&2
    exit 1
fi

# --slurpfile loads the document as a one-element array; `$p[0]`
# extracts the document so it nests directly under the canonical key.
jq -n --slurpfile p "${provisioner_path}" '{vm_provisioner_config: $p[0]}'
