#!/usr/bin/env bash
# Composes the Ansible --extra-vars document from the vaults the
# consumer contract declared. The dispatch bridge (_run-playbook.sh)
# reads VmProvisioner unconditionally, then reads whatever extra vaults
# the contract named and hands each one here as a generic
# --vault-config <VaultName>=<path> pair. This composer owns the single
# piece of domain knowledge the orchestrator must not: which vault feeds
# which per-payload-domain fragment helper. Concentrating that map here
# - the layer that already dispatches per domain - is what lets the
# orchestrator stay ignorant of any specific consumer's identity, the
# dependency-inversion seam the Common- prefix depends on.
#
# Inputs:
#   --provisioner-config <path>   Always present: the shared inventory
#                                 vault every consumer needs. Named here
#                                 because the substrate genuinely owns it
#                                 (it drives the inventory for every flow).
#   --vault-config <Name>=<path>  Repeatable: one per extra vault the
#                                 contract declared (e.g.
#                                 GitHubRunners=...). The Name selects the
#                                 per-domain helper below; an unrecognised
#                                 name is a contract typo or a domain with
#                                 no helper yet and is rejected.
#   --github-token <value>        GitHub PAT, routed to the runners helper
#                                 (pairs with the GitHubRunners vault).
#   --host-base-url <url>         Host file server URL + runner version,
#   --runner-version <ver>        bridge-resolved, routed to the runners
#                                 helper (register path only).
#   --consumer-root <path>        Optional. When a consumer owns the
#                                 per-domain fragment helper, resolve it from
#                                 <path>/ops instead of this composer's own
#                                 directory. The inventory fragment is always
#                                 substrate, so it is unaffected. Empty/unset
#                                 keeps every fragment on this composer's ops/
#                                 - the unchanged path the substrate's own
#                                 flows take.
#
# Output shape:
#
#   {
#     "vm_provisioner_config":     <provisioner JSON>,  // always
#     "github_runners_config":     <runners JSON>,      // GitHubRunners declared
#     "github_token":              "<value>",           // with GitHubRunners
#     "host_file_server_base_url": "<url>",             // file-server opt-in
#     "runner_version":            "<x.y.z>"            // file-server opt-in
#   }
#
# Per-domain helpers (siblings in this directory) own their own
# validation, jq composition, and bats coverage. Adding a future
# consumer domain (toolchain: JDK / .NET SDK / file delivery) means
# landing a new _build-extra-vars-<domain>.sh + its bats and adding one
# dispatch arm below - no orchestrator change, since the bridge already
# forwards every contract-declared vault here verbatim.

set -euo pipefail

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"
# shellcheck source=ops/_die-on-unknown-flag.sh
source "${BASH_SOURCE[0]%/*}/_die-on-unknown-flag.sh"

provisioner_path=""
declare -A vault_paths=()
token=""
token_set=0
host_base_url=""
host_base_url_set=0
runner_version=""
runner_version_set=0
consumer_root=""

usage() {
    echo "usage: _build-extra-vars.sh --provisioner-config <path>" \
         "[--vault-config <Name>=<path> ...]" \
         "[--github-token <value> [--host-base-url <url> --runner-version <ver>]]" \
         "[--consumer-root <path>]" >&2
}

# ---------------------------------------------------------------------------
# 1. Flag parsing. The provisioner config is named (the always-on
#    inventory vault); every other vault arrives as a generic
#    Name=path pair so this composer, not the orchestrator, owns the
#    vault-name -> domain dispatch.
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provisioner-config)
            provisioner_path="${2:-}"
            shift 2 || true
            ;;
        --vault-config)
            pair="${2:-}"
            shift 2 || true
            # Split on the first '=' so the value (a tmpdir path) stays
            # intact even in the unlikely event it contains '='. A pair
            # with no '=' leaves name == pair, which the guard rejects.
            vault_name="${pair%%=*}"
            vault_path="${pair#*=}"
            if [[ -z "${vault_name}" || "${vault_name}" == "${pair}" || -z "${vault_path}" ]]; then
                log_err "--vault-config expects <Name>=<path>, got '${pair}'"
                exit 2
            fi
            vault_paths["${vault_name}"]="${vault_path}"
            ;;
        --github-token)
            # ${2-} (no colon) so a literal empty value reaches the
            # checks below rather than being dropped by the default branch.
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
        --consumer-root)
            consumer_root="${2:-}"
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${provisioner_path}" ]]; then
    usage
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Cross-flag consistency. The runner-domain inputs (token + the
#    file-server pair) only have a consumer when the GitHubRunners vault
#    is present, so reject any of them arriving without it - a
#    misconfigured caller fails here rather than emitting an extra-vars
#    document that carries an unconsumable token or an unreachable URL.
#    The token<->vault coupling lives here (not the orchestrator) because
#    it is exactly the consumer knowledge the bridge must not hold.
# ---------------------------------------------------------------------------
runners_declared=0
[[ -n "${vault_paths[GitHubRunners]:-}" ]] && runners_declared=1

if [[ "${token_set}" -eq 1 && "${runners_declared}" -ne 1 ]]; then
    log_err "--github-token requires the GitHubRunners vault (--vault-config GitHubRunners=...)"
    exit 2
fi
if [[ "${runners_declared}" -eq 1 && "${token_set}" -ne 1 ]]; then
    log_err "the GitHubRunners vault requires --github-token"
    exit 2
fi

# The file-server pair must arrive whole: a URL without a version (or
# vice versa) silently drops half the runner_binary download contract.
fileserver_pair_set=0
[[ "${host_base_url_set}" -eq 1 ]]  && fileserver_pair_set=$(( fileserver_pair_set + 1 ))
[[ "${runner_version_set}" -eq 1 ]] && fileserver_pair_set=$(( fileserver_pair_set + 1 ))

if [[ "${fileserver_pair_set}" -eq 1 ]]; then
    log_err "--host-base-url and --runner-version must be supplied together"
    exit 2
fi
if [[ "${fileserver_pair_set}" -eq 2 && "${runners_declared}" -ne 1 ]]; then
    log_err "--host-base-url / --runner-version require the GitHubRunners vault"
    exit 2
fi

# ---------------------------------------------------------------------------
# 3. Dispatch. The inventory fragment is always emitted; each declared
#    vault is routed to the helper that owns its fragment's shape. Each
#    helper prints a disjoint-key JSON object on stdout; jq merges them.
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The inventory fragment is always substrate, so it stays on this composer's
# own tree. The per-domain fragments (e.g. GitHubRunners) are
# consumer-owned once extracted, so they resolve from <consumer-root>/ops
# when a consumer root was declared; empty keeps them on this composer's ops/
# - the substrate's own flows and the retained forks.
fragment_dir="${script_dir}"
if [[ -n "${consumer_root}" ]]; then
    fragment_dir="${consumer_root}/ops"
fi

fragments=()
fragments+=( "$("${script_dir}/virtual-machines/_build-extra-vars-inventory.sh" \
                --provisioner-config "${provisioner_path}")" )

if [[ "${#vault_paths[@]}" -gt 0 ]]; then
    for vault_name in "${!vault_paths[@]}"; do
        case "${vault_name}" in
            GitHubRunners)
                runners_args=(
                    --runners-config "${vault_paths[GitHubRunners]}"
                    --github-token   "${token}"
                )
                if [[ "${fileserver_pair_set}" -eq 2 ]]; then
                    runners_args+=(
                        --host-base-url  "${host_base_url}"
                        --runner-version "${runner_version}"
                    )
                fi
                fragments+=( "$("${fragment_dir}/_build-extra-vars-runners.sh" "${runners_args[@]}")" )
                ;;
            *)
                # Fail loud: a vault the operator believed would be applied
                # but for which no fragment helper exists must not be
                # silently dropped from the extra-vars document.
                log_err "no extra-vars helper for declared vault '${vault_name}'"
                exit 2
                ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# 4. Merge. `jq -s 'add'` reduces the stream of objects with the builtin
#    object union; our helpers emit disjoint key sets by design, so the
#    merge is a pure concatenation of fields regardless of dispatch order.
# ---------------------------------------------------------------------------
printf '%s\n' "${fragments[@]}" | jq -s 'add'
