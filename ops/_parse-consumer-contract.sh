#!/usr/bin/env bash
# Consumer contract parser for the Ansible dispatch bridge.
#
# The bridge (_run-playbook.sh) has to serve consumers it must not know
# by name: the user-provisioning wrapper, the runner-provisioning
# wrapper, and future ones. Rather than bake each consumer's vaults and
# toggles into the bridge, a wrapper DECLARES its needs through a small
# set of CA_* environment variables - the consumer contract - and this
# helper normalises that declaration into a stable, parsed form. Keeping
# the parse here (a single-purpose sibling with its own boundary) is the
# seam that lets the substrate stay ignorant of any specific consumer's
# identity.
#
# Contract (consumer-facing input):
#   CA_INVENTORY_VAULT         REQUIRED. The vault holding the fleet
#                              inventory (the base VM list and addresses)
#                              the bridge reads on every run. Named by the
#                              consumer rather than the bridge, so no vault
#                              NAME is hardcoded in the substrate. This
#                              removes name-coupling only: the bridge still
#                              assumes the <Name>Config-<suffix> secret
#                              convention and the vm_provisioner_config
#                              inventory schema (and the Hyper-V router
#                              resolution keyed on it). Decoupling those
#                              shapes is separate, larger work. The wrapper
#                              passes e.g. "VmProvisioner".
#   CA_EXTRA_VAULTS            Optional, default "none". Vault names to
#                              read BEYOND the inventory vault. Whitespace-
#                              or comma-separated (e.g. "Toolchains" or
#                              "Toolchains,Secrets"). Unset/empty ->
#                              no extra vaults.
#   CA_NEEDS_HOST_FILE_SERVER  Optional. "1" to have the bridge stage the
#                              host file server; any other value (incl.
#                              unset) -> off.
#   CA_HOST_FILE_SERVER_DIR    The Windows-form directory the consumer has
#                              already staged for the host file server to
#                              serve. The consumer owns the "which artifact"
#                              knowledge: it pre-stages the directory and
#                              resolves the version, then declares both here,
#                              and the bridge serves what it was given (it
#                              stages nothing itself). Supply it together with
#                              CA_HOST_FILE_SERVER_VERSION whenever
#                              CA_NEEDS_HOST_FILE_SERVER=1; requires
#                              CA_NEEDS_HOST_FILE_SERVER=1.
#   CA_HOST_FILE_SERVER_VERSION  Optional, default empty. The artifact version
#                              the consumer resolved for the staged directory,
#                              threaded to the consumer's per-domain fragment
#                              so its roles can name the served file. Paired
#                              with CA_HOST_FILE_SERVER_DIR.
#   CA_REQUIRES_TOKEN          Optional. "1" if the run needs a GitHub
#                              token, supplied out-of-band via GH_TOKEN;
#                              any other value (incl. unset) -> off.
#   CA_CONSUMER_ROOT           Optional, default empty. Absolute path to a
#                              consumer repo that owns the playbook, roles,
#                              and per-domain extra-vars fragment this run
#                              dispatches. Set -> the bridge resolves those
#                              consumer-owned artifacts from this root (the
#                              location half of consumer-agnosticism).
#                              Empty/unset -> the bridge resolves them from
#                              its own substrate root, the unchanged
#                              behaviour the substrate's own flows rely on.
#                              Passed through verbatim; the bridge validates
#                              the directory exists (filesystem state is the
#                              bridge's concern, not this pure parser's).
#
# Output (stdout, one KEY=value per line - the normalised contract the
# bridge reads back):
#   INVENTORY_VAULT=<name>
#   EXTRA_VAULTS=<space-separated vault list, empty when none>
#   NEEDS_HOST_FILE_SERVER=<0|1>
#   REQUIRES_TOKEN=<0|1>
#   CONSUMER_ROOT=<path, empty when the run uses the substrate's own root>
#   HOST_FILE_SERVER_DIR=<windows-form dir, empty when the bridge self-stages>
#   HOST_FILE_SERVER_VERSION=<artifact version, empty when the bridge self-stages>
#
# Exit status:
#   0  contract parsed and internally consistent
#   2  invalid contract - a missing required inventory vault, or a
#      required token with none supplied. Rejected here so a misconfigured
#      caller fails before any vault read rather than emitting an empty
#      token or reading a nameless vault downstream.
#
# Run directly (exec'd, not sourced): the bridge captures the normalised
# lines on stdout, and under its `set -e` a rejection (exit 2) aborts the
# whole dispatch.

set -euo pipefail

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"

# ---------------------------------------------------------------------------
# Inventory vault. Required: the bridge always reads an inventory, and the
# whole point of the contract is that the substrate names no vault itself
# - so the consumer must declare which vault holds the fleet. A missing
# declaration is rejected here, before any vault read, rather than the
# bridge silently falling back to a baked-in name (which would re-couple
# the substrate to one repo's vault convention).
# ---------------------------------------------------------------------------
inventory_vault="${CA_INVENTORY_VAULT:-}"
if [[ -z "${inventory_vault}" ]]; then
    log_err "CA_INVENTORY_VAULT must be set to the vault holding the fleet inventory"
    exit 2
fi

# ---------------------------------------------------------------------------
# Toggles. Exactly "1" means on, matching the opt-in idiom already used
# across this ops/ tree; every other value (unset, "0", "true", a typo)
# means off, so a malformed toggle fails safe to the documented default
# rather than silently enabling a capability.
# ---------------------------------------------------------------------------
needs_host_file_server=0
if [[ "${CA_NEEDS_HOST_FILE_SERVER:-0}" == "1" ]]; then
    needs_host_file_server=1
fi

requires_token=0
if [[ "${CA_REQUIRES_TOKEN:-0}" == "1" ]]; then
    requires_token=1
fi

# ---------------------------------------------------------------------------
# Consistency gate. The one inconsistent combination the contract can
# express: a caller that declares it needs a token but supplies none.
# Reject it here, before the bridge spends a vault read it could never
# consume. GH_TOKEN is the out-of-band channel (never vaulted, supplied
# per invocation), so its presence - not any CA_* var - is what proves
# the declared requirement is satisfiable.
# ---------------------------------------------------------------------------
if [[ "${requires_token}" -eq 1 && -z "${GH_TOKEN:-}" ]]; then
    log_err "CA_REQUIRES_TOKEN=1 but GH_TOKEN is unset; a token-requiring consumer must supply GH_TOKEN"
    exit 2
fi

# ---------------------------------------------------------------------------
# Extra vaults. Normalise the caller's whitespace/comma-separated list
# into a single space-separated line: commas become spaces, then
# word-splitting via `read -a` drops empty fields (so "Toolchains,,X"
# or a trailing separator is harmless). An empty/unset input yields an
# empty EXTRA_VAULTS value - the "none" default. The default-substitution
# and comma-replacement are separate steps because bash cannot combine
# them in one parameter expansion.
# ---------------------------------------------------------------------------
extra_vaults_raw="${CA_EXTRA_VAULTS:-}"
read -r -a extra_vaults_arr <<<"${extra_vaults_raw//,/ }" || true

# ---------------------------------------------------------------------------
# Consumer root. Passed through verbatim (empty when unset): a consumer that
# owns its playbook/roles/fragment declares where they live; the substrate's
# own flows leave it empty and the bridge falls back to its own root. The
# directory-exists check is the bridge's, not this pure parser's.
# ---------------------------------------------------------------------------
consumer_root="${CA_CONSUMER_ROOT:-}"

# ---------------------------------------------------------------------------
# Host file server staging inputs. The consumer pre-stages the directory the
# file server serves and resolves its artifact version (the runner owner
# caches its tarball), then declares both here. Both or neither: a directory
# with no version would serve a file the roles cannot name, and a version with
# no directory has nothing to serve. They only make sense when the file server
# is enabled, so a stray pair without CA_NEEDS_HOST_FILE_SERVER=1 is a wiring
# error caught here; conversely the serve-only staging helper requires the
# directory whenever the file server is enabled (it stages nothing itself).
# ---------------------------------------------------------------------------
host_file_server_dir="${CA_HOST_FILE_SERVER_DIR:-}"
host_file_server_version="${CA_HOST_FILE_SERVER_VERSION:-}"
if { [[ -n "${host_file_server_dir}" ]] && [[ -z "${host_file_server_version}" ]]; } \
   || { [[ -z "${host_file_server_dir}" ]] && [[ -n "${host_file_server_version}" ]]; }; then
    log_err "CA_HOST_FILE_SERVER_DIR and CA_HOST_FILE_SERVER_VERSION must be supplied together"
    exit 2
fi
if [[ -n "${host_file_server_dir}" && "${needs_host_file_server}" -ne 1 ]]; then
    log_err "CA_HOST_FILE_SERVER_DIR requires CA_NEEDS_HOST_FILE_SERVER=1"
    exit 2
fi

# ---------------------------------------------------------------------------
# Emit the normalised contract. The bridge greps these keys back out, the
# same KEY=value-on-stdout contract _stage-host-fileserver.sh already uses.
# ---------------------------------------------------------------------------
printf 'INVENTORY_VAULT=%s\n'        "${inventory_vault}"
printf 'EXTRA_VAULTS=%s\n'           "${extra_vaults_arr[*]}"
printf 'NEEDS_HOST_FILE_SERVER=%s\n' "${needs_host_file_server}"
printf 'REQUIRES_TOKEN=%s\n'         "${requires_token}"
printf 'CONSUMER_ROOT=%s\n'          "${consumer_root}"
printf 'HOST_FILE_SERVER_DIR=%s\n'   "${host_file_server_dir}"
printf 'HOST_FILE_SERVER_VERSION=%s\n' "${host_file_server_version}"
