#!/usr/bin/env bash
# Serves a staged directory over a host file server so target VMs can fetch
# its files over the Hyper-V internal switch instead of the NAT-bound
# github.com path. The "which artifact" knowledge (which runner tarball,
# which version) is the consumer's: the runner owner pre-stages the directory
# and resolves the version, then hands both to this helper. The file server
# itself serves any file - it no longer knows about runner tarballs - so a
# later toolchain consumer (JDK / .NET) reuses it the same way.
#
# This is the host-file-server branch of the bridge factored into its own
# helper so _run-playbook.sh stays a thin orchestrator of one-line dispatch
# steps. The serve-only path is one pwsh.exe round-trip (start the
# HttpListener, long-lived and backgrounded).
#
# Inputs:
#   --provisioner-config <path>  Always: drives host-IP / target-VM-IP
#                                resolution for the listener bind.
#   --listener-log <path>        Always: the listener's stdout is redirected
#                                here so this helper can grep BASE_URL+PID.
#   --staging-dir <dir>          The Windows-form directory to serve. Supplied
#   --runner-version <ver>       with the artifact version by a consumer that
#                                pre-staged the directory. Both together.
#   --github-token <value>       Required only on the retained-fork fallback
#                                (no --staging-dir): the substrate then
#                                resolves the runner version and caches the
#                                tarball itself. Removed with the runner fork
#                                in Step 4.4.
#
# Output contract (stdout, in the order emitted):
#
#   RUNNER_VERSION=<x.y.z>          (echoed from --runner-version, or resolved)
#   BASE_URL=http://<host-ip>:<port>
#   PID=<pwsh-process-id>
#
# The PID is the listener process; the caller hands it back to
# _stop-host-file-server.ps1 in its EXIT trap so the listener dies
# on every bridge exit path. The listener's own stdout is redirected
# to --listener-log so this helper can grep BASE_URL+PID before
# exiting; the file is owned by the caller and lives as long as the
# caller's tmpdir, so log inspection on failure is still possible
# from the bridge's perspective.

set -euo pipefail

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/../imports/_log.sh"
# shellcheck source=ops/_die-on-unknown-flag.sh
source "${BASH_SOURCE[0]%/*}/../_die-on-unknown-flag.sh"

# _to_windows_path (shared from Common-Automation). The imports/ adapter
# owns the cross-repo resolution.
# shellcheck source=ops/imports/_to-windows-path.sh
source "${BASH_SOURCE[0]%/*}/../imports/_to-windows-path.sh"

provisioner_path=""
token=""
token_set=0
listener_log=""
staging_dir=""
runner_version=""

usage() {
    echo "usage: _stage-host-fileserver.sh --provisioner-config <path>" \
         "--listener-log <path>" \
         "[--staging-dir <dir> --runner-version <ver>] [--github-token <value>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provisioner-config)
            provisioner_path="${2:-}"
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
        --listener-log)
            listener_log="${2:-}"
            shift 2 || true
            ;;
        --staging-dir)
            staging_dir="${2:-}"
            shift 2 || true
            ;;
        --runner-version)
            runner_version="${2:-}"
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${provisioner_path}" || -z "${listener_log}" ]]; then
    usage
    exit 2
fi
if [[ ! -f "${provisioner_path}" ]]; then
    log_err "provisioner config not found: ${provisioner_path}"
    exit 1
fi
# The staged directory and its version are a pair, supplied together by a
# consumer that pre-staged the artifact.
if [[ -n "${staging_dir}" && -z "${runner_version}" ]] \
   || [[ -z "${staging_dir}" && -n "${runner_version}" ]]; then
    log_err "--staging-dir and --runner-version must be supplied together"
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Why this helper narrates each step via log_info (from imports/_log.sh): its
# stdout is the KEY=value contract the caller captures by command
# substitution, and each step is a silent pwsh.exe round-trip - the
# tarball cache miss in particular downloads ~100MB with no output - so
# the steps announce themselves on stderr instead, where they neither
# corrupt that contract nor leave the operator staring at a stall.

# ---------------------------------------------------------------------------
# 1-2. Acquire the directory to serve and its artifact version.
#
#   Consumer-staged path: --staging-dir / --runner-version were supplied, so
#   the consumer already resolved the version and cached the artifact. Nothing
#   to do here but serve what was handed over - the file server knows nothing
#   about runner tarballs.
#
#   Retained-fork fallback (no --staging-dir): the substrate resolves the
#   runner version and caches the tarball itself via the ../ runner-tarball
#   resolvers. This is the pre-extraction behaviour the Common-Ansible runner
#   fork still relies on; it (and the two ../ .ps1 references) leaves when the
#   runner fork is removed in Step 4.4.
# ---------------------------------------------------------------------------
if [[ -z "${staging_dir}" ]]; then
    if [[ "${token_set}" -ne 1 || -z "${token}" ]]; then
        log_err "--github-token is required when --staging-dir is not supplied"
        exit 2
    fi

    log_info "Resolving latest actions/runner version via GitHub API ..."
    resolve_ps1="$(_to_windows_path "${script_dir}/../_resolve-runner-version.ps1")"
    # Capture pwsh.exe's stderr - where _resolve-runner-version.ps1 writes its
    # error, e.g. "401 - check the GH_TOKEN scopes" for a bad/expired token -
    # to a temp file instead of discarding it, so a failure surfaces the cause
    # rather than dying silently under `set -o pipefail`. stdout stays the
    # clean version string; the captured stderr is printed only on failure.
    resolve_err="$(mktemp)"
    if runner_version="$(pwsh.exe -NoProfile -NoLogo \
            -File "${resolve_ps1}" \
            -Token "${token}" 2>"${resolve_err}" \
            | tr -d '\r' | tail -n1)" && [[ -n "${runner_version}" ]]; then
        rm -f "${resolve_err}"
    else
        log_err "failed to resolve runner version (GitHub API error below):"
        while IFS= read -r line; do
            [[ -n "${line}" ]] && log_err "  ${line}"
        done < "${resolve_err}"
        rm -f "${resolve_err}"
        exit 1
    fi

    log_info "Ensuring runner tarball ${runner_version} is cached (downloads ~100MB on a cache miss) ..."
    ensure_ps1="$(_to_windows_path "${script_dir}/../_ensure-runner-tarball.ps1")"
    tar_path="$(pwsh.exe -NoProfile -NoLogo \
        -File "${ensure_ps1}" \
        -Version "${runner_version}" 2>/dev/null \
        | tr -d '\r' | tail -n1)"
    if [[ -z "${tar_path}" ]]; then
        log_err "failed to stage runner tarball"
        exit 1
    fi
    # tar_path is a Windows path (Join-Path output, e.g.
    # C:\Users\...\runner-cache\actions-...tar.gz). bash `dirname` keys on '/'
    # and would return '.' for a backslash path, so strip the last component
    # directly - the result stays in Windows form, which is what the
    # listener's -StagingDir argument needs.
    staging_dir="${tar_path%[\\/]*}"
    log_info "Runner tarball ready: ${tar_path}"
else
    log_info "Serving consumer-staged directory ${staging_dir} (runner ${runner_version}) ..."
fi

# ---------------------------------------------------------------------------
# 3. Decide where to bind the listener.
#
#    Two paths, picked by the caller's ROUTER_IP environment variable:
#
#    a. ROUTER_IP set (feature-53 NAT topology). Workloads sit on a
#       per-environment private switch the host has no route to, so the
#       legacy "match the workload's /24" lookup would explode with
#       "No host adapter found". Resolve the host adapter on the
#       router's UPSTREAM LAN instead (via Get-VmSwitchHostIp on the
#       router IP) and pass it through as -HostIp. Workloads then reach
#       the listener via their default route -> router priv0 -> router
#       MASQUERADE on ext0 -> host.
#
#    b. ROUTER_IP unset (legacy single-switch topology). The first
#       workload's ipAddress drives Get-VmSwitchHostIp inside
#       _start-host-file-server.ps1 via the -TargetVmIp parameter.
#       Routers are filtered out because they have no ipAddress under
#       externalDhcp=true and would null-out the lookup.
# ---------------------------------------------------------------------------
listener_args=(-StagingDir "${staging_dir}")
if [[ -n "${ROUTER_IP:-}" ]]; then
    log_info "Resolving host adapter IP on the router's upstream LAN (ROUTER_IP=${ROUTER_IP}) ..."
    host_ip="$(pwsh.exe -NoProfile -NoLogo -Command \
        "Import-Module Infrastructure.HyperV -MinimumVersion 0.11.0; Get-VmSwitchHostIp -VmIpAddress '${ROUTER_IP}'" \
        2>/dev/null | tr -d '\r' | tail -n1)"
    if [[ -z "${host_ip}" ]]; then
        log_err "Get-VmSwitchHostIp returned empty for ROUTER_IP=${ROUTER_IP}"
        exit 1
    fi
    listener_args+=(-HostIp "${host_ip}")
else
    target_vm_ip="$(jq -r '[ .[] | select((.kind // "") != "router") ][0].ipAddress // empty' "${provisioner_path}")"
    if [[ -z "${target_vm_ip}" ]]; then
        log_err "provisioner config has no VMs with ipAddress - cannot bind host file server"
        exit 1
    fi
    listener_args+=(-TargetVmIp "${target_vm_ip}")
fi

# ---------------------------------------------------------------------------
# 4. Start the listener in the background and poll its stdout for
#    BASE_URL + PID. The listener prints both within milliseconds of
#    Listener.Start() returning; anything slower than ~10s is a real
#    failure (a missed firewall rule, a stale URL ACL, an exit code
#    from the helper itself). The `kill -0` check short-circuits the
#    wait if the helper has already exited.
# ---------------------------------------------------------------------------
log_info "Starting host file server listener ..."
: > "${listener_log}"
start_ps1="$(_to_windows_path "${script_dir}/_start-host-file-server.ps1")"
pwsh.exe -NoProfile -NoLogo \
    -File "${start_ps1}" \
    "${listener_args[@]}" \
    > "${listener_log}" 2>&1 &
listener_bash_pid=$!

for _ in $(seq 1 40); do
    if grep -q '^PID=' "${listener_log}"; then break; fi
    if ! kill -0 "${listener_bash_pid}" 2>/dev/null; then
        log_err "host file server exited before reporting PID:"
        cat "${listener_log}" >&2
        exit 1
    fi
    sleep 0.25
done

host_base_url="$(grep '^BASE_URL=' "${listener_log}" | head -n1 | cut -d= -f2-)"
host_fs_pid="$(grep   '^PID='      "${listener_log}" | head -n1 | cut -d= -f2-)"
host_base_url="${host_base_url//$'\r'/}"
host_fs_pid="${host_fs_pid//$'\r'/}"

if [[ -z "${host_base_url}" || -z "${host_fs_pid}" ]]; then
    log_err "host file server did not report BASE_URL and PID:"
    cat "${listener_log}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Emit the three contract lines for the bridge to parse. printf
#    so there is no trailing whitespace and the keys match the docs.
# ---------------------------------------------------------------------------
printf 'RUNNER_VERSION=%s\n' "${runner_version}"
printf 'BASE_URL=%s\n'        "${host_base_url}"
printf 'PID=%s\n'             "${host_fs_pid}"
