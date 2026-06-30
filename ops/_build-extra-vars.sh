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
#                                 contract declared. The Name derives the
#                                 per-domain helper dispatched below
#                                 (_build-extra-vars-<Name>.sh); a Name with
#                                 no such helper is a contract typo or a
#                                 domain not yet wired and is rejected.
#   --github-token <value>        Optional cross-cutting input forwarded to
#                                 every declared vault's helper when supplied;
#                                 a helper that does not consume it never
#                                 receives it. Requires at least one declared
#                                 extra vault (nothing consumes it otherwise).
#   --host-base-url <url>         Optional cross-cutting inputs, forwarded the
#   --runner-version <ver>        same way; bridge-resolved, paired (both or
#                                 neither), and requiring a declared extra
#                                 vault to have a consumer.
#   --consumer-root <path>        Optional. When a consumer owns the
#                                 per-domain fragment helper, resolve it from
#                                 <path>/ops instead of this composer's own
#                                 directory. The inventory fragment is always
#                                 substrate, so it is unaffected. Empty/unset
#                                 keeps every fragment on this composer's ops/
#                                 - the unchanged path the substrate's own
#                                 flows take.
#
# Output shape (the inventory key is always present; every other key is
# contributed by whichever per-domain helper a declared vault dispatched to):
#
#   {
#     "vm_provisioner_config": <provisioner JSON>,  // always
#     ...                                           // per-domain helper keys
#   }
#
# Per-domain helpers (siblings in this directory, or under <consumer-root>/ops
# when a consumer owns one) each own their own validation, jq composition, and
# bats coverage. They emit disjoint key sets that jq merges. Adding a future
# consumer domain (toolchain: JDK / .NET SDK / file delivery) means landing a
# new _build-extra-vars-<Name>.sh + its bats - no change here and no
# orchestrator change, since dispatch is by the <Name> derivation and the
# bridge already forwards every contract-declared vault here verbatim.

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
# 2. Cross-flag consistency. The optional cross-cutting inputs (token +
#    the file-server pair) are forwarded to the declared vaults' helpers,
#    so they only have a possible consumer when at least one extra vault
#    is declared. Reject any of them arriving with no declared extra vault
#    - a misconfigured caller fails here rather than emitting an extra-vars
#    document carrying an unconsumable token or an unreachable URL. Whether
#    a given helper actually requires the token is the helper's own
#    contract (asserted in its fragment), not this composer's: keeping the
#    composer ignorant of which domain needs what is what lets it stay
#    consumer-agnostic.
# ---------------------------------------------------------------------------
extras_declared=0
[[ "${#vault_paths[@]}" -gt 0 ]] && extras_declared=1

if [[ "${token_set}" -eq 1 && "${extras_declared}" -ne 1 ]]; then
    log_err "--github-token requires at least one declared extra vault (--vault-config <Name>=...)"
    exit 2
fi

# The file-server pair must arrive whole: a URL without a version (or
# vice versa) silently drops half a download contract for the helper that
# consumes it.
fileserver_pair_set=0
[[ "${host_base_url_set}" -eq 1 ]]  && fileserver_pair_set=$(( fileserver_pair_set + 1 ))
[[ "${runner_version_set}" -eq 1 ]] && fileserver_pair_set=$(( fileserver_pair_set + 1 ))

if [[ "${fileserver_pair_set}" -eq 1 ]]; then
    log_err "--host-base-url and --runner-version must be supplied together"
    exit 2
fi
if [[ "${fileserver_pair_set}" -eq 2 && "${extras_declared}" -ne 1 ]]; then
    log_err "--host-base-url / --runner-version require at least one declared extra vault"
    exit 2
fi

# ---------------------------------------------------------------------------
# 3. Dispatch. The inventory fragment is always emitted; each declared
#    vault is routed to the helper that owns its fragment's shape. Each
#    helper prints a disjoint-key JSON object on stdout; jq merges them.
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The inventory fragment is always substrate, so it stays on this composer's
# own tree. The per-domain fragments are consumer-owned, so they resolve from
# <consumer-root>/ops when a consumer root was declared; empty keeps them on
# this composer's own ops/ (where only the always-on inventory fragment lives,
# so the substrate's own flows resolve unchanged).
fragment_dir="${script_dir}"
if [[ -n "${consumer_root}" ]]; then
    fragment_dir="${consumer_root}/ops"
fi

fragments=()
fragments+=( "$("${script_dir}/virtual-machines/_build-extra-vars-inventory.sh" \
                --provisioner-config "${provisioner_path}")" )

if [[ "${#vault_paths[@]}" -gt 0 ]]; then
    for vault_name in "${!vault_paths[@]}"; do
        # The vault Name derives its helper by convention:
        # _build-extra-vars-<Name>.sh under the fragment dir. A declared
        # vault with no matching helper is a contract typo or a domain not
        # yet wired - fail loud rather than silently drop it from the doc.
        helper="${fragment_dir}/_build-extra-vars-${vault_name}.sh"
        if [[ ! -f "${helper}" ]]; then
            log_err "no extra-vars helper for declared vault '${vault_name}' (expected ${helper})"
            exit 2
        fi

        # The vault's config path rides a generic --config flag. The optional
        # cross-cutting inputs are forwarded only when the contract supplied
        # them, so a helper that does not consume them never receives them
        # (and one that requires them asserts so itself).
        helper_args=( --config "${vault_paths[${vault_name}]}" )
        if [[ "${token_set}" -eq 1 ]]; then
            helper_args+=( --github-token "${token}" )
        fi
        if [[ "${fileserver_pair_set}" -eq 2 ]]; then
            helper_args+=(
                --host-base-url  "${host_base_url}"
                --runner-version "${runner_version}"
            )
        fi
        fragments+=( "$("${helper}" "${helper_args[@]}")" )
    done
fi

# ---------------------------------------------------------------------------
# 4. Merge. `jq -s 'add'` reduces the stream of objects with the builtin
#    object union; our helpers emit disjoint key sets by design, so the
#    merge is a pure concatenation of fields regardless of dispatch order.
# ---------------------------------------------------------------------------
printf '%s\n' "${fragments[@]}" | jq -s 'add'
