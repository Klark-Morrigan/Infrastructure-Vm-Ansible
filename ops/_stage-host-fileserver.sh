#!/usr/bin/env bash
# Stages the runner tarball Windows-side and starts a host file
# server so target VMs can fetch it over the Hyper-V internal switch
# instead of the NAT-bound github.com path.
#
# This is the GitHubRunners opt-in branch of the bridge factored
# into its own helper so _run-playbook.sh stays a thin orchestrator
# of one-line dispatch steps. Three pwsh.exe round-trips:
#
#   1. Resolve the latest actions/runner version.
#   2. Ensure the matching tarball is cached locally.
#   3. Start the HttpListener (long-lived, backgrounded).
#
# Output contract (stdout, in the order emitted):
#
#   RUNNER_VERSION=<x.y.z>
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

# shellcheck source=ops/_die-on-unknown-flag.sh
source "${BASH_SOURCE[0]%/*}/_die-on-unknown-flag.sh"

# _to_windows_path is a generic helper shared from Common-Automation
# (see its own header for the sibling/COMMON_AUTOMATION_ROOT contract).
_ops_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common_automation_root="${COMMON_AUTOMATION_ROOT:-$(cd "${_ops_dir}/../../Common-Automation" && pwd)}"
# shellcheck source=/dev/null
source "${common_automation_root}/scripts/_to-windows-path.sh"

provisioner_path=""
token=""
token_set=0
listener_log=""

usage() {
    echo "usage: _stage-host-fileserver.sh --provisioner-config <path>" \
         "--github-token <value> --listener-log <path>" >&2
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
        *)
            _die_on_unknown_flag _stage-host-fileserver.sh "$1"
            ;;
    esac
done

if [[ -z "${provisioner_path}" || "${token_set}" -ne 1 || -z "${listener_log}" ]]; then
    usage
    exit 2
fi
if [[ -z "${token}" ]]; then
    echo "_stage-host-fileserver.sh: --github-token requires a non-empty value" >&2
    exit 2
fi
if [[ ! -f "${provisioner_path}" ]]; then
    echo "_stage-host-fileserver.sh: provisioner config not found: ${provisioner_path}" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Progress logger. This helper's stdout is the KEY=value contract the
# caller captures via command substitution, so every progress line must
# go to stderr or it would corrupt that contract. Each step below is a
# pwsh.exe round-trip that runs silently; the tarball cache miss in
# particular downloads ~100MB with no output, so the steps announce
# themselves to stderr (which the caller merges 2>&1 and shows).
# shellcheck disable=SC2312  # date never fails; masking its status is fine here
log() { printf '[%s] _stage-host-fileserver.sh: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Resolve runner version. The trailing `tail -n1` strips any
#    chatter pwsh.exe prints before the function's return value (e.g.
#    progress lines under -v) so only the version reaches stdout.
# ---------------------------------------------------------------------------
log "Resolving latest actions/runner version via GitHub API ..."
resolve_ps1="$(_to_windows_path "${script_dir}/_resolve-runner-version.ps1")"
runner_version="$(pwsh.exe -NoProfile -NoLogo \
    -File "${resolve_ps1}" \
    -Token "${token}" 2>/dev/null \
    | tr -d '\r' | tail -n1)"
if [[ -z "${runner_version}" ]]; then
    echo "_stage-host-fileserver.sh: failed to resolve runner version" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Ensure tarball is cached. The PowerShell helper returns the
#    absolute path; we hand its parent directory to the listener so a
#    future toolchain-delivery feature can stage extra payloads in
#    the same dir without touching this script.
# ---------------------------------------------------------------------------
log "Ensuring runner tarball ${runner_version} is cached (downloads ~100MB on a cache miss) ..."
ensure_ps1="$(_to_windows_path "${script_dir}/_ensure-runner-tarball.ps1")"
tar_path="$(pwsh.exe -NoProfile -NoLogo \
    -File "${ensure_ps1}" \
    -Version "${runner_version}" 2>/dev/null \
    | tr -d '\r' | tail -n1)"
if [[ -z "${tar_path}" ]]; then
    echo "_stage-host-fileserver.sh: failed to stage runner tarball" >&2
    exit 1
fi
# tar_path is a Windows path (the PowerShell helper returns Join-Path
# output, e.g. C:\Users\...\runner-cache\actions-...tar.gz). bash `dirname`
# keys on '/' and would return '.' for a backslash path, so strip the last
# path component directly - the result stays in Windows form, which is what
# the listener's -StagingDir argument needs.
staging_dir="${tar_path%[\\/]*}"
log "Runner tarball ready: ${tar_path}"

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
    log "Resolving host adapter IP on the router's upstream LAN (ROUTER_IP=${ROUTER_IP}) ..."
    host_ip="$(pwsh.exe -NoProfile -NoLogo -Command \
        "Import-Module Infrastructure.HyperV -MinimumVersion 0.11.0; Get-VmSwitchHostIp -VmIpAddress '${ROUTER_IP}'" \
        2>/dev/null | tr -d '\r' | tail -n1)"
    if [[ -z "${host_ip}" ]]; then
        echo "_stage-host-fileserver.sh: Get-VmSwitchHostIp returned empty for ROUTER_IP=${ROUTER_IP}" >&2
        exit 1
    fi
    listener_args+=(-HostIp "${host_ip}")
else
    target_vm_ip="$(jq -r '[ .[] | select((.kind // "") != "router") ][0].ipAddress // empty' "${provisioner_path}")"
    if [[ -z "${target_vm_ip}" ]]; then
        echo "_stage-host-fileserver.sh: provisioner config has no VMs with ipAddress - cannot bind host file server" >&2
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
log "Starting host file server listener ..."
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
        echo "_stage-host-fileserver.sh: host file server exited before reporting PID:" >&2
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
    echo "_stage-host-fileserver.sh: host file server did not report BASE_URL and PID:" >&2
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
