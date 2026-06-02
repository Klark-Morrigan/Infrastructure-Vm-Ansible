#!/usr/bin/env bash
# Composes the Ansible --extra-vars document by wrapping the two
# vault payloads under their canonical top-level keys. Pure transform;
# no pwsh.exe, no filesystem writes beyond stdout, no environment deps
# beyond jq.
#
# Output shape (problem.md contract):
#
#   {
#     "vm_provisioner_config": <provisioner JSON>,
#     "vm_users_config":       <users JSON>
#   }
#
# Inputs are file paths (not values) so secrets stay out of argv,
# which is visible to `ps` and a common accident vector.

set -euo pipefail

provisioner_path=""
users_path=""

# ---------------------------------------------------------------------------
# 1. Flag parsing. Both flags are required; either missing or any
#    unknown flag fails with the usage line so the operator sees the
#    contract immediately. Long flags only - this is a private bridge
#    helper, not an operator-facing CLI worth a short-form too.
# ---------------------------------------------------------------------------
usage() {
    echo "usage: _build-extra-vars.sh --provisioner-config <path> --users-config <path>" >&2
}

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

# ---------------------------------------------------------------------------
# 2. File presence + JSON validity per file. Validate each independently
#    so the error message names the offending file, not a generic
#    "input invalid".
# ---------------------------------------------------------------------------
for label_path in "provisioner-config:${provisioner_path}" "users-config:${users_path}"; do
    label="${label_path%%:*}"
    path="${label_path#*:}"

    if [[ ! -f "${path}" ]]; then
        echo "_build-extra-vars.sh: --${label} file not found: ${path}" >&2
        exit 1
    fi

    if ! jq empty "${path}" >/dev/null 2>&1; then
        echo "_build-extra-vars.sh: --${label} is not valid JSON: ${path}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 3. Compose. --slurpfile loads each document into a one-element array;
#    indexing `$p[0]` / `$u[0]` extracts the document so the output
#    nests it directly under the canonical key.
# ---------------------------------------------------------------------------
jq -n \
    --slurpfile p "${provisioner_path}" \
    --slurpfile u "${users_path}" \
    '{vm_provisioner_config: $p[0], vm_users_config: $u[0]}'
