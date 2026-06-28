#!/usr/bin/env bash
# Bash bridge between operator entry scripts and ansible-playbook.
# Thin orchestrator: validates args, sets up the per-invocation tmpdir
# (chmod 700 + EXIT trap), activates the venv, drives the three
# underscored sibling helpers under ops/, then dispatches
# ansible-playbook. Each helper has its own bats coverage; this
# script's tests focus on orchestration only.
#
# The split keeps the bridge readable and each piece independently
# testable against just its own external boundary - read-vault-config
# needs a stubbed pwsh.exe; the two pure transforms need no stubs at
# all.

set -euo pipefail

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"

# ---------------------------------------------------------------------------
# Vault contract. This bridge names NO vault - not even the fleet
# inventory it reads on every dispatch. The inventory is the substrate's
# own input (VM names, addresses, credentials, router/NAT topology) and
# every dispatch needs it - _build-inventory.sh turns it into the Ansible
# inventory, router resolution reads it, host-file-server staging binds
# against a VM address from it - but the VAULT that holds it is named by a
# specific repo (Infrastructure-Vm-Provisioner), so the consumer declares
# it through the contract (CA_INVENTORY_VAULT) rather than the bridge
# hardcoding it. Downstream consumer vaults (e.g. GitHubRunners) are
# declared the same way through CA_EXTRA_VAULTS. Pinning the substrate to
# no repo's vault naming -
# inventory provider or downstream consumer alike - is the dependency
# inversion that keeps the repo a substrate rather than a knower of its
# own estate.
#
# The per-vault secret name follows the Infrastructure-Secrets convention
# <VaultName>Config-<suffix>, derived the same way for the inventory vault
# and for every contract-declared extra vault, so the generic read loop
# needs no per-consumer table.
# ---------------------------------------------------------------------------

# Required: SECRET_SUFFIX selects the lifecycle/environment whose
# secrets this run will read. Operator invocations pass `Production`;
# ephemeral fixtures (test harnesses, parallel workflows, multi-tenant
# deployments) pass their own label. Mandatory so a caller cannot
# silently fall through to a default name and collide with another
# lifecycle's data.
if [[ -z "${SECRET_SUFFIX:-}" ]]; then
    log_err "SECRET_SUFFIX must be set (e.g. Production or the caller's lifecycle label)"
    exit 2
fi

# Anchor every relative path to the repo root so the script works
# regardless of the caller's working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# ---------------------------------------------------------------------------
# Windows launcher bridge. This script's whole toolchain - the .venv +
# ansible-playbook, nc, and the WSL router-relay redirect below - lives in
# the WSL controller that ops/bootstrap-controller provisions. But the
# operator entry points launch it through Git Bash (the menu's
# Invoke-BashScript, and register-runners.bat via _find-bash.bat). Under Git
# Bash none of that toolchain exists: ansible is not on PATH, .venv/bin's
# python3 is a Linux symlink, nc is absent, and the relay redirect is
# skipped because /proc/version is not "microsoft". So when we detect a Git
# Bash / Cygwin launch, re-exec self inside the WSL default distro - the
# same distro bootstrap-controller provisions and drives via `wsl --`.
# uname -s is "Linux" inside WSL and on native-Linux CI, so the re-exec
# fires exactly once and never on the controller itself (no loop, no effect
# on the bats suite, which runs under Linux).
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        if ! command -v wsl.exe >/dev/null 2>&1; then
            log_err "launched under Git Bash but wsl.exe is not available; this bridge runs in the WSL controller. Install WSL and run ops/bootstrap-controller first."
            exit 2
        fi

        # Translate this script's own dir /c/... (Git Bash) -> /mnt/c/...
        # (WSL mount) into an absolute path wsl.exe can re-run. The script
        # self-anchors via BASH_SOURCE, so no working-directory juggling is
        # needed. \L lowercases the drive letter (GNU sed, which Git Bash
        # ships).
        wsl_script="$(printf '%s' "${script_dir}" | sed -E 's#^/([A-Za-z])/#/mnt/\L\1/#')/_run-playbook.sh"

        # CA_CONSUMER_ROOT names a consumer repo on disk (e.g. the user owner
        # repo). A wrapper resolves it via `pwd` under Git Bash, so it is a
        # /c/... path the WSL side cannot open; translate it to /mnt/c/... the
        # same way as the script path above and forward the translated value.
        # WSLENV's own /p path-translation flag is not used here because it
        # converts Windows-format (C:\...) paths, not the /c/... form Git Bash
        # pwd produces. Empty/unset stays empty and forwards harmlessly.
        if [[ -n "${CA_CONSUMER_ROOT:-}" ]]; then
            CA_CONSUMER_ROOT="$(printf '%s' "${CA_CONSUMER_ROOT}" | sed -E 's#^/([A-Za-z])/#/mnt/\L\1/#')"
            export CA_CONSUMER_ROOT
        fi

        # Forward only the caller-supplied inputs the bridge consults: the
        # SECRET_SUFFIX selector and the consumer-contract CA_* variables
        # the parse step reads. CA_INVENTORY_VAULT is included because it is
        # the one REQUIRED contract var - omitting it would make the parse
        # step reject every Git-Bash-launched flow with "CA_INVENTORY_VAULT
        # must be set" once it re-execs into WSL. WSLENV injects them into
        # the WSL environment; GH_TOKEN rides this channel rather than the
        # command line so it never lands in a `ps` listing. CA_CONSUMER_ROOT
        # rides it pre-translated (above). Append to any existing WSLENV
        # rather than clobber.
        export WSLENV="${WSLENV:+${WSLENV}:}SECRET_SUFFIX:CA_INVENTORY_VAULT:CA_EXTRA_VAULTS:CA_NEEDS_HOST_FILE_SERVER:CA_REQUIRES_TOKEN:CA_CONSUMER_ROOT:GH_TOKEN"

        # MSYS2 (Git Bash) rewrites /-leading arguments into Windows paths
        # when launching a Windows .exe, which corrupts the /mnt path and
        # the forwarded args wsl.exe receives - the defect that delivered an
        # empty playbook path on the far side. Disable arg path-conversion
        # for this exec so wsl.exe sees them verbatim.
        export MSYS2_ARG_CONV_EXCL='*'
        export MSYS_NO_PATHCONV=1
        log_info "Git Bash launch detected; re-executing under the WSL controller (default distro) ..."

        # Run the script by absolute path under the controller's bash, with
        # this invocation's original args ("$@" = playbook path + forwarded
        # ansible flags) passed straight through.
        exec wsl.exe -- bash "${wsl_script}" "$@"
        ;;
    *)
        # WSL ("Linux" uname) or native-Linux CI: the venv / nc / ansible
        # toolchain is already present, so run in place. This is the path
        # the controller and the bats suite take.
        ;;
esac

# _to_windows_path (shared from Common-Automation) is sourced before the
# EXIT trap is installed because cleanup() calls it to point pwsh.exe at
# the stop helper. The imports/ adapter owns the cross-repo resolution.
# shellcheck source=ops/imports/_to-windows-path.sh
source "${BASH_SOURCE[0]%/*}/imports/_to-windows-path.sh"

# Why this orchestrator narrates each phase via log_info (from imports/_log.sh):
# every phase below is silent on its own - vault reads and the
# KVP/portproxy/staging pwsh.exe round-trips capture or redirect their
# stdout, and the longest of them (the KVP IP poll, the runner-tarball
# download) can block for minutes. Without a per-phase marker the
# operator sees the caller's "Registering runners ..." line and then
# nothing, unable to tell which phase is stuck; the timestamp turns that
# stall into a measurable per-phase duration.

# ---------------------------------------------------------------------------
# 1. Argument validation. One positional arg required (the playbook
#    path); anything after it is forwarded verbatim to ansible-playbook
#    so operators can pass --tags / --limit / --check without
#    modifying the bridge.
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "usage: _run-playbook.sh <playbook-path> [ansible-playbook args...]" >&2
    exit 2
fi

playbook_path="$1"
shift
# Existence is checked after the contract is parsed below: the base the
# playbook resolves against depends on CA_CONSUMER_ROOT, which the contract
# parser normalises.

# ---------------------------------------------------------------------------
# 1b. Consumer contract. The wrapper declares - through CA_* env vars -
#     which vaults to read beyond the always-on VmProvisioner, whether to
#     stage the host file server, and whether the run needs a GitHub
#     token. _parse-consumer-contract.sh normalises that declaration and
#     rejects the one inconsistent combination it can express (a required
#     token with none supplied) before any vault read. Capturing its
#     stdout under set -e means that rejection (exit 2) aborts the whole
#     dispatch here, with the helper's message left on stderr.
# ---------------------------------------------------------------------------
contract="$("${script_dir}/_parse-consumer-contract.sh")"
inventory_vault="$(grep '^INVENTORY_VAULT=' <<<"${contract}" | head -n1 | cut -d= -f2-)"
extra_vaults_line="$(grep '^EXTRA_VAULTS=' <<<"${contract}" | head -n1)"
needs_host_file_server="$(grep '^NEEDS_HOST_FILE_SERVER=' <<<"${contract}" | head -n1 | cut -d= -f2-)"
requires_token="$(grep '^REQUIRES_TOKEN=' <<<"${contract}" | head -n1 | cut -d= -f2-)"
consumer_root="$(grep '^CONSUMER_ROOT=' <<<"${contract}" | head -n1 | cut -d= -f2-)"

# Consumer-root resolution. When the contract named a consumer root, the
# playbook, the consumer's roles (_ansible-env.sh below), and the per-domain
# extra-vars fragment (_build-extra-vars.sh) all resolve from it rather than
# from this substrate root - the location half of consumer-agnosticism that
# lets a consumer own its playbook/roles/fragment while reusing the bridge.
# Empty -> the substrate's own root, the unchanged path the retained forks
# take. A named-but-absent root is an operator/wiring error, caught here
# before any vault read rather than surfacing as a confusing "playbook not
# found" or "role not found" later.
if [[ -n "${consumer_root}" && ! -d "${consumer_root}" ]]; then
    log_err "CA_CONSUMER_ROOT is set but not a directory: ${consumer_root}"
    exit 2
fi
playbook_base="${consumer_root:-${repo_root}}"
if [[ -f "${playbook_base}/${playbook_path}" ]]; then
    # Resolve to an absolute path so the dispatch below is independent of the
    # cwd: with a consumer root, the playbook lives outside this substrate
    # tree and a base-relative path would otherwise miss after the cd.
    playbook_resolved="${playbook_base}/${playbook_path}"
elif [[ -f "${playbook_path}" ]]; then
    playbook_resolved="${playbook_path}"
else
    log_err "playbook not found: ${playbook_path} (searched under ${playbook_base})"
    exit 2
fi

# EXTRA_VAULTS is a space-separated list, possibly empty (no extras).
# word-splitting via read -a drops the empty case to a zero-length array;
# || true keeps a no-trailing-newline read's non-zero status from
# tripping set -e.
read -r -a extra_vaults <<<"${extra_vaults_line#EXTRA_VAULTS=}" || true

# Staging the host file server downloads the runner tarball from the
# GitHub API, which needs the token; tie the two capability flags
# together here so a caller that opts into the file server without a
# token fails before the tmpdir and the listener are stood up. This is a
# generic capability coupling (file server needs token), not consumer
# knowledge - the bridge still names no specific consumer.
if [[ "${needs_host_file_server}" == "1" && "${requires_token}" != "1" ]]; then
    log_err "the host file server (CA_NEEDS_HOST_FILE_SERVER=1) requires a token (CA_REQUIRES_TOKEN=1)"
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Per-invocation tmpdir. mktemp -d under $TMPDIR (tmpfs on most
#    distros, so secrets never reach the disk-backed FS). chmod 700
#    is belt-and-braces against a misconfigured /tmp; the EXIT trap
#    guarantees cleanup on every exit path including signal-induced.
# ---------------------------------------------------------------------------
tmpdir="$(mktemp -d -t vm-ansible.XXXXXX)"
chmod 700 "${tmpdir}"

# Combined cleanup. The host file server (when the caller opted into
# it via CA_NEEDS_HOST_FILE_SERVER=1) is a long-lived pwsh process the
# bridge starts before ansible-playbook runs; killing it on every
# exit path - including signal-induced - is the trap's job, and
# bundling that with the tmpdir rm keeps a single EXIT handler for
# the orchestrator. When the caller did not opt into the file server,
# host_fs_pid stays empty and the stop call is a silent no-op.
host_fs_pid=""
cleanup() {
    if [[ -n "${host_fs_pid}" ]]; then
        local stop_ps1
        stop_ps1="$(_to_windows_path "${script_dir}/virtual-machines/_stop-host-file-server.ps1")"
        pwsh.exe -NoProfile -File "${stop_ps1}" \
            -ProcessId "${host_fs_pid}" >/dev/null 2>&1 || true
        host_fs_pid=""
    fi
    rm -rf "${tmpdir}"
}
# shellcheck disable=SC2064  # expand $tmpdir/$script_dir at trap-install time on purpose
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Venv activation. Step 2's bootstrap creates .venv with the pinned
#    ansible-core; a missing venv is an operator error, not something
#    to silently work around.
# ---------------------------------------------------------------------------
venv_activate="${repo_root}/.venv/bin/activate"
if [[ ! -f "${venv_activate}" ]]; then
    log_err ".venv missing - run ops/bootstrap-controller.{ps1,sh} first"
    exit 1
fi
# shellcheck disable=SC1090  # path is computed at runtime
source "${venv_activate}"

# shellcheck source=ops/_ansible-env.sh
source "${script_dir}/_ansible-env.sh"

# ---------------------------------------------------------------------------
# 4. Vault reads. The contract-declared inventory vault is always read
#    (the fleet the dispatch targets). Then each contract-declared extra
#    vault is read generically into its own tmpdir file - the bridge names
#    no vault, it reads whatever the contract listed, so register-runners
#    pays only for GitHubRunners and a consumer pays only for what it
#    declares. Each
#    read validates its payload via jq empty before returning, so a
#    malformed secret fails here with the vault name in the message - not
#    later inside ansible-playbook. chmod 600 mirrors the tmpdir
#    restriction. The declared extra vaults accumulate as generic
#    --vault-config Name=path pairs handed to the extra-vars composer,
#    which owns the vault-name -> per-domain dispatch.
# ---------------------------------------------------------------------------
provisioner_file="${tmpdir}/provisioner.json"
inventory_secret="${inventory_vault}Config-${SECRET_SUFFIX}"

log_info "Reading vault secret ${inventory_vault}/${inventory_secret} ..."
"${script_dir}/_read-vault-config.sh" "${inventory_vault}" "${inventory_secret}" \
    > "${provisioner_file}"
chmod 600 "${provisioner_file}"

extra_vault_args=()
for vault in "${extra_vaults[@]}"; do
    vault_file="${tmpdir}/vault-${vault}.json"
    vault_secret="${vault}Config-${SECRET_SUFFIX}"
    log_info "Reading vault secret ${vault}/${vault_secret} ..."
    "${script_dir}/_read-vault-config.sh" "${vault}" "${vault_secret}" \
        > "${vault_file}"
    chmod 600 "${vault_file}"
    extra_vault_args+=( --vault-config "${vault}=${vault_file}" )
done

# Lift the token out of the environment when the contract declared one,
# then clear GH_TOKEN unconditionally: a required token is carried to the
# composer (and the staging helper) by value via the local below, and a
# stray GH_TOKEN that no contract asked for must still never reach
# ansible-playbook's environment. The downstream play receives the token
# via the chmod-600 extra-vars file only.
github_token=""
if [[ "${requires_token}" == "1" ]]; then
    # ${GH_TOKEN:-} (with default) signals the intentional external
    # reference to shellcheck; the contract parser already proved it
    # non-empty whenever requires_token is 1.
    github_token="${GH_TOKEN:-}"
fi
unset GH_TOKEN || true

host_base_url=""
runner_version=""

# ---------------------------------------------------------------------------
# 4b. Router-VM resolution (NAT topology). Delegated to the
#     ops/virtual-machines/_resolve-router.sh module: resolve_router finds
#     the router row, resolves its upstream IP (static or Hyper-V KVP),
#     applies the WSL portproxy redirect, exports the ROUTER_* / SSHPASS
#     env the inventory builder and host-file-server staging consume, and
#     runs the reachability pre-flight. A no-op when the fleet has no
#     router row. The module is the contained home for this estate's
#     Hyper-V / ICS / netsh-portproxy topology knowledge, kept out of the
#     otherwise consumer-agnostic orchestrator.
# ---------------------------------------------------------------------------
# shellcheck source=ops/virtual-machines/_resolve-router.sh
source "${script_dir}/virtual-machines/_resolve-router.sh"
resolve_router "${provisioner_file}"

# ---------------------------------------------------------------------------
# 5. Inventory generation. Pure stdin -> stdout transform; redirected
#    file picks up the chmod immediately. When the router resolution
#    above exported ROUTER_IP / ROUTER_USERNAME, the inventory builder
#    injects ansible_ssh_common_args per workload host.
# ---------------------------------------------------------------------------
hosts_file="${tmpdir}/hosts.json"
log_info "Building Ansible inventory ..."
"${script_dir}/virtual-machines/_build-inventory.sh" < "${provisioner_file}" > "${hosts_file}"
chmod 600 "${hosts_file}"

# ---------------------------------------------------------------------------
# 5b. Host file server staging (contract NEEDS_HOST_FILE_SERVER opt-in).
#
#     The whole resolve-tarball-then-listener pipeline lives in its
#     own helper so this orchestrator stays a thin sequence of
#     one-line dispatch steps. The helper prints three KEY=value
#     lines on stdout - RUNNER_VERSION, BASE_URL, PID - which we
#     parse into locals for use below (extra-vars compose, EXIT
#     trap). The listener it backgrounds lives until the EXIT trap
#     hands its pid to _stop-host-file-server.ps1.
#
#     The deregister flow leaves CA_NEEDS_HOST_FILE_SERVER unset and so
#     skips this block entirely: nothing is fetched on the down path,
#     and host_fs_pid stays empty so the EXIT trap's stop call is a
#     no-op.
# ---------------------------------------------------------------------------
if [[ "${needs_host_file_server}" == "1" ]]; then
    listener_log="${tmpdir}/fileserver.out"
    # stage_out captures the helper's stdout (its KEY=value contract), so
    # its own progress lines go to stderr and surface here. This step
    # resolves the runner version, downloads the ~100MB runner tarball on
    # a cache miss, then starts the listener - the download is the second
    # most common silent stall after the KVP poll.
    log_info "Staging host file server (resolve runner version, cache tarball, start listener) ..."
    stage_out="$("${script_dir}/virtual-machines/_stage-host-fileserver.sh" \
        --provisioner-config "${provisioner_file}" \
        --github-token       "${github_token}" \
        --listener-log       "${listener_log}")"
    log_info "Host file server staged."

    runner_version="$(grep '^RUNNER_VERSION=' <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
    host_base_url="$(grep  '^BASE_URL='        <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
    host_fs_pid="$(grep    '^PID='             <<<"${stage_out}" | head -n1 | cut -d= -f2-)"

    if [[ -z "${runner_version}" || -z "${host_base_url}" || -z "${host_fs_pid}" ]]; then
        log_err "staging helper did not return RUNNER_VERSION/BASE_URL/PID"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 6. Extra-vars composition. Pure transform; takes file paths so the
#    payloads never appear on argv where `ps` could see them.
# ---------------------------------------------------------------------------
extra_vars_file="${tmpdir}/extra-vars.json"
extra_vars_args=( --provisioner-config "${provisioner_file}" )
# When a consumer owns the per-domain fragment, the composer resolves it
# from <consumer-root>/ops; empty keeps the composer on its own ops/.
if [[ -n "${consumer_root}" ]]; then
    extra_vars_args+=( --consumer-root "${consumer_root}" )
fi
# Forward every contract-declared vault generically; the composer maps
# each Name to the per-domain fragment helper that owns its shape.
extra_vars_args+=( "${extra_vault_args[@]}" )
# Token by value when the contract declared one. The composer enforces
# the token<->vault pairing, so the bridge only forwards it and never
# decides which vault consumes it.
if [[ -n "${github_token}" ]]; then
    extra_vars_args+=( --github-token "${github_token}" )
fi
# File-server pair only when the caller opted in: the deregister entry
# leaves host_base_url / runner_version empty, and the extra-vars doc
# genuinely omits the two keys rather than emitting empties (absence
# beats a stale URL for the down-direction roles).
if [[ "${needs_host_file_server}" == "1" ]]; then
    extra_vars_args+=(
        --host-base-url  "${host_base_url}"
        --runner-version "${runner_version}"
    )
fi

log_info "Composing extra-vars ..."
"${script_dir}/_build-extra-vars.sh" "${extra_vars_args[@]}" \
    > "${extra_vars_file}"
chmod 600 "${extra_vars_file}"

# ---------------------------------------------------------------------------
# 7. Dispatch. cd to repo root so ansible.cfg is picked up and any
#    substrate-relative path resolves naturally. The playbook is passed by
#    its resolved absolute path (playbook_resolved) so a consumer-owned
#    playbook outside this tree is found regardless of cwd; roles resolve
#    through the absolute ANSIBLE_ROLES_PATH _ansible-env.sh exported, not
#    cwd. Forwarded args follow the playbook so operator flags reach
#    ansible-playbook unmodified.
# ---------------------------------------------------------------------------
cd "${repo_root}"
log_info "Dispatching ansible-playbook ${playbook_resolved} (PLAY/TASK output follows) ..."
ansible-playbook \
    -i "${hosts_file}" \
    --extra-vars "@${extra_vars_file}" \
    "${playbook_resolved}" \
    "$@"
