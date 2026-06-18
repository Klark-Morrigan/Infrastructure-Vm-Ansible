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
# Vault contract. Hardcoded to match Infrastructure-Secrets convention.
# Pinning both ends to constants makes a mismatch a code-review issue
# rather than a silent runtime failure.
# ---------------------------------------------------------------------------
readonly VM_PROVISIONER_VAULT="VmProvisioner"
readonly VM_USERS_VAULT="VmUsers"
readonly GITHUB_RUNNERS_VAULT="GitHubRunners"

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
readonly VM_PROVISIONER_SECRET="VmProvisionerConfig-${SECRET_SUFFIX}"
readonly VM_USERS_SECRET="VmUsersConfig-${SECRET_SUFFIX}"
readonly GITHUB_RUNNERS_SECRET="GitHubRunnersConfig-${SECRET_SUFFIX}"

# Anchor every relative path to the repo root so the script works
# regardless of the caller's working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

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

if [[ ! -f "${repo_root}/${playbook_path}" && ! -f "${playbook_path}" ]]; then
    log_err "playbook not found: ${playbook_path}"
    exit 2
fi

# Validate the GitHubRunners opt-in inputs before any vault read so a
# misconfigured caller (NEEDS_GITHUB_RUNNERS=1 without GH_TOKEN) fails
# before two pwsh.exe round-trips it would never be able to consume.
needs_github_runners=0
if [[ "${NEEDS_GITHUB_RUNNERS:-0}" == "1" ]]; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
        log_err "NEEDS_GITHUB_RUNNERS=1 requires GH_TOKEN env var"
        exit 2
    fi
    needs_github_runners=1
fi

# The host file server is its own opt-in on top of NEEDS_GITHUB_RUNNERS.
# Register sets both (VMs fetch the tarball); deregister sets only the
# former (nothing is fetched, so spawning the HttpListener would waste a
# port and add a failure surface the down path does not need). The
# file-server flag without the runners flag is meaningless - the
# listener serves the runner tarball and the runner_binary role is
# only loaded under NEEDS_GITHUB_RUNNERS=1.
needs_host_file_server=0
if [[ "${NEEDS_HOST_FILE_SERVER:-0}" == "1" ]]; then
    if [[ "${needs_github_runners}" -ne 1 ]]; then
        log_err "NEEDS_HOST_FILE_SERVER=1 requires NEEDS_GITHUB_RUNNERS=1"
        exit 2
    fi
    needs_host_file_server=1
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
# it via NEEDS_HOST_FILE_SERVER=1) is a long-lived pwsh process the
# bridge starts before ansible-playbook runs; killing it on every
# exit path - including signal-induced - is the trap's job, and
# bundling that with the tmpdir rm keeps a single EXIT handler for
# the orchestrator. When the caller did not opt into the file server,
# host_fs_pid stays empty and the stop call is a silent no-op.
host_fs_pid=""
cleanup() {
    if [[ -n "${host_fs_pid}" ]]; then
        local stop_ps1
        stop_ps1="$(_to_windows_path "${script_dir}/_stop-host-file-server.ps1")"
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
# 4. Vault reads. Each call validates its payload via jq empty before
#    returning, so a malformed secret fails here with the vault name
#    in the message - not later inside ansible-playbook. chmod 600 on
#    each file mirrors the tmpdir restriction. The GitHubRunners read
#    is gated by NEEDS_GITHUB_RUNNERS so the create-users / remove-users
#    entry points do not pay for a pwsh.exe round-trip they cannot
#    consume.
# ---------------------------------------------------------------------------
provisioner_file="${tmpdir}/provisioner.json"
users_file="${tmpdir}/users.json"

log_info "Reading vault secret ${VM_PROVISIONER_VAULT}/${VM_PROVISIONER_SECRET} ..."
"${script_dir}/_read-vault-config.sh" "${VM_PROVISIONER_VAULT}" "${VM_PROVISIONER_SECRET}" \
    > "${provisioner_file}"
chmod 600 "${provisioner_file}"

log_info "Reading vault secret ${VM_USERS_VAULT}/${VM_USERS_SECRET} ..."
"${script_dir}/_read-vault-config.sh" "${VM_USERS_VAULT}" "${VM_USERS_SECRET}" \
    > "${users_file}"
chmod 600 "${users_file}"

# Entry scripts opt in to the runners pipeline by exporting
# NEEDS_GITHUB_RUNNERS=1 (and GH_TOKEN). The bridge itself never
# prompts - the operator edge (ops/register-runners.sh) owns that.
runners_file=""
github_token=""
host_base_url=""
runner_version=""
if [[ "${needs_github_runners}" -eq 1 ]]; then
    runners_file="${tmpdir}/runners.json"
    log_info "Reading vault secret ${GITHUB_RUNNERS_VAULT}/${GITHUB_RUNNERS_SECRET} ..."
    "${script_dir}/_read-vault-config.sh" "${GITHUB_RUNNERS_VAULT}" "${GITHUB_RUNNERS_SECRET}" \
        > "${runners_file}"
    chmod 600 "${runners_file}"

    # Lift the token into a local so we can clear GH_TOKEN from the
    # bridge's environment before invoking ansible-playbook. The
    # downstream play receives the token via the chmod-600 extra-vars
    # file only; nothing else in this process tree needs it in env.
    github_token="${GH_TOKEN}"
    unset GH_TOKEN
fi

# ---------------------------------------------------------------------------
# 4b. Router-VM resolution (feature-53 NAT topology)
#
#     Workloads on a per-environment private switch are not reachable
#     from the controller (WSL on the host) directly - the Ansible
#     bridge must thread its ssh through the router via ProxyCommand.
#     Find the router row in VmProvisionerConfig (kind == 'router'),
#     resolve its upstream IPv4 via Hyper-V KVP when externalDhcp=true
#     leaves ipAddress empty in the vault, and export ROUTER_* env
#     vars consumed by the downstream helpers.
#
#     Two distinct addresses are kept separate on purpose:
#
#       ROUTER_IP       the router's TRUE upstream LAN IP (its identity
#                       on the Hyper-V switch, e.g. 192.168.137.10).
#                       NEVER rewritten - it is a topological fact.
#       ROUTER_SSH_HOST the address the controller actually opens an SSH
#                       connection to. Equals ROUTER_IP on direct hosts;
#                       under WSL it is rewritten to the host portproxy
#                       endpoint (the WSL adapter cannot reach the
#                       Internal-switch subnet through ICS NAT).
#
#     Consumers:
#
#       - _build-inventory.sh    : injects ansible_ssh_common_args per
#                                  workload (ProxyCommand+sshpass) aimed
#                                  at ROUTER_SSH_HOST - the SSH endpoint.
#       - _assert-router-reachable.sh : probes ROUTER_SSH_HOST.
#       - _stage-host-fileserver.sh : binds the listener on the host
#                                  adapter sharing the router's upstream
#                                  /24 (Get-VmSwitchHostIp on ROUTER_IP,
#                                  the topological IP - NOT the SSH
#                                  endpoint, which under WSL points at
#                                  the host's own WSL adapter and would
#                                  resolve no Hyper-V switch adapter).
#       - ansible-playbook'd ssh : reads $SSHPASS at sshpass -e time
#                                  to authenticate to the router
#                                  without putting the password in
#                                  argv.
#
#     When no router row is present (single-switch topology), the
#     ROUTER_* vars stay empty and every downstream helper takes its
#     legacy direct-routing branch.
# ---------------------------------------------------------------------------
router_row="$(jq -c '[ .[] | select((.kind // "") == "router") ][0] // empty' "${provisioner_file}")"
if [[ -n "${router_row}" ]]; then
    router_vm_name="$(printf '%s' "${router_row}" | jq -r '.vmName // empty')"
    router_switch="$( printf '%s' "${router_row}" | jq -r '.externalSwitchName // empty')"
    ROUTER_USERNAME="$(printf '%s' "${router_row}" | jq -r '.username // empty')"
    ROUTER_PASSWORD="$(printf '%s' "${router_row}" | jq -r '.password // empty')"
    static_router_ip="$(printf '%s' "${router_row}" | jq -r '.ipAddress // empty')"
    if [[ -z "${router_vm_name}" || -z "${router_switch}" || -z "${ROUTER_USERNAME}" || -z "${ROUTER_PASSWORD}" ]]; then
        log_err "router row missing required fields (vmName/externalSwitchName/username/password)"
        exit 1
    fi

    if [[ -n "${static_router_ip}" ]]; then
        ROUTER_IP="${static_router_ip}"
        log_info "Router '${router_vm_name}' static IP from vault: ${ROUTER_IP}"
    else
        # Get-VmKvpIpAddress polls KVP until the router publishes its
        # ext0 IPv4; tail -n1 strips any noise pwsh.exe might emit
        # before the value (status lines, warnings) on slow imports.
        # This poll blocks with no output until the router boots far
        # enough to publish KVP - the single most common silent stall in
        # this flow, so it gets its own before/after markers.
        log_info "Resolving router '${router_vm_name}' upstream IP via Hyper-V KVP on switch '${router_switch}' (polls until the router publishes; can take minutes on a cold boot) ..."
        ROUTER_IP="$(pwsh.exe -NoProfile -NoLogo -Command \
            "Import-Module Infrastructure.HyperV -MinimumVersion 0.11.0; Get-VmKvpIpAddress -VmName '${router_vm_name}' -SwitchName '${router_switch}'" \
            2>/dev/null | tr -d '\r' | tail -n1)"
        if [[ -z "${ROUTER_IP}" ]]; then
            log_err "Get-VmKvpIpAddress returned empty for router '${router_vm_name}' on switch '${router_switch}'"
            exit 1
        fi
        log_info "Router '${router_vm_name}' KVP IP resolved: ${ROUTER_IP}"
    fi

    # ROUTER_SSH_HOST defaults to the router's true LAN IP: on direct
    # (non-WSL) hosts the SSH endpoint and the topological IP are one and
    # the same. The WSL branch below overrides only this SSH endpoint,
    # leaving ROUTER_IP untouched for the Get-VmSwitchHostIp lookup in
    # _stage-host-fileserver.sh.
    ROUTER_SSH_HOST="${ROUTER_IP}"

    # WSL2-on-Windows portproxy redirect. WSL2 runs as its own
    # Hyper-V guest with its own NAT and cannot reach the host's
    # Internal-switch subnet (e.g. 192.168.137.0/24, the ICS-served
    # network where the router lives) through ICS NAT. The
    # Vm-Provisioner ensures a host-side netsh portproxy rule
    # forwarding <listenAddr>:<port> -> <routerIp>:22 at provisioning
    # time; here we discover that rule from inside WSL (via
    # pwsh.exe -> netsh) and point ROUTER_SSH_HOST/ROUTER_PORT at it.
    # ROUTER_IP itself is deliberately NOT rewritten - it remains the
    # router's upstream LAN IP so _stage-host-fileserver.sh can resolve
    # the host's Internal-switch adapter from it.
    #
    # Reaching the host portproxy from WSL has two cases:
    #   - WSL mirrored networking mode: 127.0.0.1 from WSL IS the
    #     host's loopback. Direct hit.
    #   - WSL NAT mode (default): 127.0.0.1 is WSL's OWN loopback,
    #     NOT the host's. Must aim at the host's WSL-side gateway IP
    #     (the IP reported by `ip route show default | awk '{print $3}'`).
    #     This requires the provisioner's portproxy to listen on
    #     0.0.0.0 (its default) rather than 127.0.0.1, so the
    #     listener is reachable from the WSL vEthernet interface.
    #
    # We probe 127.0.0.1 first (the mirrored-mode happy path), and
    # fall back to the WSL gateway IP if the probe fails. nc -z is
    # the minimal "is something listening?" check; -w1 caps the
    # wait at one second so a non-listening 127.0.0.1 does not
    # delay the fallback.
    #
    # Listen-port auto-discovery (no hardcoded port): we parse netsh
    # output for any rule whose ConnectAddress matches the router's
    # ROUTER_IP and use whichever ListenPort the provisioner chose.
    # The listen address regex accepts both 0.0.0.0 (default) and
    # 127.0.0.1 (operator-pinned). The provisioner's default is
    # 2222; operators who override via -ListenPort keep working.
    #
    # No-op on non-WSL hosts (Linux CI, Mac, etc. - no netsh, no
    # ICS NAT to work around) and on WSL hosts without a matching
    # portproxy rule (ROUTER_SSH_HOST stays equal to ROUTER_IP, the
    # direct path).
    if grep -qi microsoft /proc/version 2>/dev/null; then
        log_info "WSL detected; discovering host netsh portproxy rule for ${ROUTER_IP}:22 ..."
        portproxy_port="$(pwsh.exe -NoProfile -NoLogo -Command \
            "& netsh interface portproxy show v4tov4 2>\$null | Where-Object { \$_ -match '^(0\.0\.0\.0|127\.0\.0\.1)\s+(\d+)\s+${ROUTER_IP//./\\.}\s+22' } | ForEach-Object { (\$_ -split '\s+' | Where-Object { \$_ })[1] } | Select-Object -First 1" \
            2>/dev/null | tr -d '\r' | tail -n1)"
        if [[ -n "${portproxy_port}" ]]; then
            # Pick a reachable target. 127.0.0.1 works in mirrored
            # mode; otherwise the WSL gateway IP works for NAT mode
            # when the provisioner's portproxy listens on 0.0.0.0.
            target_ip="127.0.0.1"
            if ! nc -z -w1 "${target_ip}" "${portproxy_port}" >/dev/null 2>&1; then
                wsl_gateway="$(ip route show default 2>/dev/null | awk '/^default/ {print $3}' | head -n1)"
                if [[ -n "${wsl_gateway}" ]]; then
                    target_ip="${wsl_gateway}"
                fi
            fi
            echo "_run-playbook.sh: WSL detected; routing via host portproxy ${target_ip}:${portproxy_port} -> ${ROUTER_IP}:22"
            ROUTER_SSH_HOST="${target_ip}"
            ROUTER_PORT="${portproxy_port}"
            export ROUTER_PORT
        fi
    fi

    # SSHPASS is the env-based auth channel for sshpass -e: ansible-
    # playbook's ssh subprocesses inherit it and pass it through to
    # sshpass inside the ProxyCommand. The password never appears in
    # argv (no `sshpass -p`), so `ps` listings stay clean.
    export ROUTER_IP ROUTER_SSH_HOST ROUTER_USERNAME
    export SSHPASS="${ROUTER_PASSWORD}"
    # Avoid leaving the cleartext in a non-exported var the rest of the
    # script could accidentally interpolate into a log line. SSHPASS
    # is the only legitimate consumer from here on.
    unset ROUTER_PASSWORD

    # -----------------------------------------------------------------------
    # 4c. Router reachability pre-flight. Delegated to the sibling helper
    #     so the orchestrator stays thin and the probe is tested against
    #     just its nc/ssh boundary. A non-zero exit (unreachable) aborts
    #     the bridge here under set -e - before ansible-playbook spends its
    #     ~136s per-host connect-retry budget on a hop the helper already
    #     proved broken. The helper's stderr names the failed segment.
    # -----------------------------------------------------------------------
    "${script_dir}/_assert-router-reachable.sh" "${ROUTER_SSH_HOST}" "${ROUTER_PORT:-22}"
fi

# ---------------------------------------------------------------------------
# 5. Inventory generation. Pure stdin -> stdout transform; redirected
#    file picks up the chmod immediately. When the router resolution
#    above exported ROUTER_IP / ROUTER_USERNAME, the inventory builder
#    injects ansible_ssh_common_args per workload host.
# ---------------------------------------------------------------------------
hosts_file="${tmpdir}/hosts.json"
log_info "Building Ansible inventory ..."
"${script_dir}/_build-inventory.sh" < "${provisioner_file}" > "${hosts_file}"
chmod 600 "${hosts_file}"

# ---------------------------------------------------------------------------
# 5b. Host file server staging (NEEDS_HOST_FILE_SERVER opt-in only).
#
#     The whole resolve-tarball-then-listener pipeline lives in its
#     own helper so this orchestrator stays a thin sequence of
#     one-line dispatch steps. The helper prints three KEY=value
#     lines on stdout - RUNNER_VERSION, BASE_URL, PID - which we
#     parse into locals for use below (extra-vars compose, EXIT
#     trap). The listener it backgrounds lives until the EXIT trap
#     hands its pid to _stop-host-file-server.ps1.
#
#     The deregister flow leaves NEEDS_HOST_FILE_SERVER unset and so
#     skips this block entirely: nothing is fetched on the down path,
#     and host_fs_pid stays empty so the EXIT trap's stop call is a
#     no-op.
# ---------------------------------------------------------------------------
if [[ "${needs_host_file_server}" -eq 1 ]]; then
    listener_log="${tmpdir}/fileserver.out"
    # stage_out captures the helper's stdout (its KEY=value contract), so
    # its own progress lines go to stderr and surface here. This step
    # resolves the runner version, downloads the ~100MB runner tarball on
    # a cache miss, then starts the listener - the download is the second
    # most common silent stall after the KVP poll.
    log_info "Staging host file server (resolve runner version, cache tarball, start listener) ..."
    stage_out="$("${script_dir}/_stage-host-fileserver.sh" \
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
extra_vars_args=(
    --provisioner-config "${provisioner_file}"
    --users-config       "${users_file}"
)
if [[ -n "${runners_file}" ]]; then
    extra_vars_args+=(
        --runners-config "${runners_file}"
        --github-token   "${github_token}"
    )
    # File-server pair only when the caller opted in: the deregister
    # entry leaves host_base_url / runner_version empty, and the
    # extra-vars doc genuinely omits the two keys rather than emitting
    # empties (absence beats stale URL for the down-direction roles).
    if [[ "${needs_host_file_server}" -eq 1 ]]; then
        extra_vars_args+=(
            --host-base-url  "${host_base_url}"
            --runner-version "${runner_version}"
        )
    fi
fi

log_info "Composing extra-vars ..."
"${script_dir}/_build-extra-vars.sh" "${extra_vars_args[@]}" \
    > "${extra_vars_file}"
chmod 600 "${extra_vars_file}"

# ---------------------------------------------------------------------------
# 7. Dispatch. cd to repo root so role/playbook paths resolve naturally
#    and ansible.cfg is picked up. Forwarded args follow the playbook
#    path so operator flags reach ansible-playbook unmodified.
# ---------------------------------------------------------------------------
cd "${repo_root}"
log_info "Dispatching ansible-playbook ${playbook_path} (PLAY/TASK output follows) ..."
ansible-playbook \
    -i "${hosts_file}" \
    --extra-vars "@${extra_vars_file}" \
    "${playbook_path}" \
    "$@"
