#!/usr/bin/env bash
# Per-domain extra-vars helper: runners.
#
# Emits the two top-level keys consumed by the runner_binary /
# runner_registration / runner_service roles. Opt-in: dispatched by
# the orchestrator only when the caller exports NEEDS_GITHUB_RUNNERS=1
# and supplies GH_TOKEN, so the create-users / remove-users flows
# never pay for it.
#
# Output (stdout):
#   {"github_runners_config": <document>, "github_token": "<value>"}
#
# Token-by-value rationale: configs ride as file paths to keep secrets
# off argv, but the token is passed by value because the entry script
# holds it in a shell variable already and mktemp-ing it just to read
# it back has no security upside (argv on Linux is private to the
# owning user's process tree, same trust boundary as env vars and
# stdin args). The token is threaded into jq via --arg so any shell-
# special characters in it land in JSON literally.

set -euo pipefail

runners_path=""
token=""
token_set=0

usage() {
    echo "usage: _build-extra-vars-runners.sh --runners-config <path> --github-token <value>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runners-config)
            runners_path="${2:-}"
            shift 2 || true
            ;;
        --github-token)
            # ${2-} (no colon) so a literal empty value reaches the
            # non-empty check below rather than being silently dropped
            # by parameter expansion's default branch.
            token="${2-}"
            token_set=1
            shift 2 || true
            ;;
        *)
            echo "_build-extra-vars-runners.sh: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "${runners_path}" || "${token_set}" -ne 1 ]]; then
    usage
    exit 2
fi

if [[ -z "${token}" ]]; then
    echo "_build-extra-vars-runners.sh: --github-token requires a non-empty value" >&2
    exit 2
fi

if [[ ! -f "${runners_path}" ]]; then
    echo "_build-extra-vars-runners.sh: --runners-config file not found: ${runners_path}" >&2
    exit 1
fi

if ! jq empty "${runners_path}" >/dev/null 2>&1; then
    echo "_build-extra-vars-runners.sh: --runners-config is not valid JSON: ${runners_path}" >&2
    exit 1
fi

jq -n \
    --slurpfile r "${runners_path}" \
    --arg       t "${token}" \
    '{github_runners_config: $r[0], github_token: $t}'
