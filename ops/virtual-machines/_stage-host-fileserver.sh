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
# Inputs (all required - the consumer always pre-stages the directory and
# resolves its artifact version, then hands both here; this helper only binds
# a listener over what it was given):
#   --provisioner-config <path>  Drives host-IP / target-VM-IP resolution for
#                                the listener bind.
#   --listener-log <path>        The listener's stdout is redirected here so
#                                this helper can grep BASE_URL+PID.
#   --staging-dir <dir>          The Windows-form directory to serve.
#   --runner-version <ver>       The artifact version that directory holds,
#                                echoed back on the contract below.
#
# Output contract (stdout, in the order emitted):
#
#   RUNNER_VERSION=<x.y.z>          (echoed from --runner-version)
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
listener_log=""
staging_dir=""
runner_version=""

usage() {
    echo "usage: _stage-host-fileserver.sh --provisioner-config <path>" \
         "--listener-log <path> --staging-dir <dir> --runner-version <ver>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provisioner-config)
            provisioner_path="${2:-}"
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

if [[ -z "${provisioner_path}" || -z "${listener_log}" \
   || -z "${staging_dir}" || -z "${runner_version}" ]]; then
    usage
    exit 2
fi
if [[ ! -f "${provisioner_path}" ]]; then
    log_err "provisioner config not found: ${provisioner_path}"
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Why this helper narrates via log_info (from imports/_log.sh): its stdout is
# the KEY=value contract the caller captures by command substitution, so the
# steps announce themselves on stderr instead - the listener start is a silent
# pwsh.exe round-trip, and a marker there neither corrupts that contract nor
# leaves the operator staring at a stall.

# ---------------------------------------------------------------------------
# 1. Serve the consumer-staged directory. The consumer already resolved the
#    artifact version and cached its files, so there is nothing to fetch here -
#    the file server serves whatever directory it was handed and knows nothing
#    about runner tarballs (the same reuse a later JDK / .NET consumer relies on).
# ---------------------------------------------------------------------------
log_info "Serving consumer-staged directory ${staging_dir} (runner ${runner_version}) ..."

# ---------------------------------------------------------------------------
# 2. Decide where to bind the listener.
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
# 3. Start the listener in the background and poll its stdout for
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
# 4. Emit the three contract lines for the bridge to parse. printf
#    so there is no trailing whitespace and the keys match the docs.
# ---------------------------------------------------------------------------
printf 'RUNNER_VERSION=%s\n' "${runner_version}"
printf 'BASE_URL=%s\n'        "${host_base_url}"
printf 'PID=%s\n'             "${host_fs_pid}"
