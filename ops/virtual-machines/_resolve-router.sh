#!/usr/bin/env bash
# Router-VM resolution for the NAT topology, factored out of the dispatch
# bridge into the ops/virtual-machines/ module. The Hyper-V KVP / ICS /
# netsh-portproxy knowledge here is the most estate-specific code in the
# substrate, so it lives in one named place rather than inline in
# _run-playbook.sh - making the residual "this substrate still knows one
# estate's topology" coupling visible and contained.
#
# Sourced (not exec'd) on purpose: resolve_router must set ROUTER_* and
# SSHPASS in the BRIDGE's own environment, because the inventory builder
# (_build-inventory.sh) and the host-file-server staging
# (_stage-host-fileserver.sh) read them as env vars. A child process
# could not export back to its parent, and routing the router password
# out through a child's stdout would expose a secret that today never
# leaves this process tree.
#
#   resolve_router <provisioner-config-file>
#
# When the provisioner config has a kind=="router" row, resolves the
# router's upstream IPv4 (static from the vault, else Hyper-V KVP when
# externalDhcp leaves it empty), applies the WSL host-portproxy redirect
# to the SSH endpoint ONLY, exports the addresses the downstream helpers
# consume, and runs the reachability pre-flight. When no router row is
# present (single-switch topology) it is a no-op and every downstream
# helper takes its direct-routing branch.
#
# Two addresses are kept distinct on purpose:
#
#   ROUTER_IP       the router's TRUE upstream LAN IP (its identity on the
#                   Hyper-V switch, e.g. 192.168.137.10). NEVER rewritten -
#                   a topological fact the host-adapter lookup needs.
#   ROUTER_SSH_HOST the address the controller actually opens SSH to.
#                   Equals ROUTER_IP on direct hosts; under WSL rewritten
#                   to the host portproxy endpoint (the WSL adapter cannot
#                   reach the Internal-switch subnet through ICS NAT).
#
# Consumers of the exported vars:
#   - _build-inventory.sh        : per-workload ansible_ssh_common_args
#                                  (ProxyCommand+sshpass) aimed at
#                                  ROUTER_SSH_HOST.
#   - _assert-router-reachable.sh: probes ROUTER_SSH_HOST.
#   - _stage-host-fileserver.sh  : binds the listener on the host adapter
#                                  sharing the router's upstream /24
#                                  (Get-VmSwitchHostIp on ROUTER_IP, the
#                                  topological IP - not the SSH endpoint).
#   - ansible-playbook'd ssh     : reads $SSHPASS at sshpass -e time so
#                                  the password never lands in argv.

set -euo pipefail

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/../imports/_log.sh"

resolve_router() {
    local provisioner_file="$1"
    # Sibling reachability helper lives in this same ops/virtual-machines/
    # module; anchor to this file's own dir so the lookup is relocation-proof.
    local router_dir="${BASH_SOURCE[0]%/*}"

    local router_row
    router_row="$(jq -c '[ .[] | select((.kind // "") == "router") ][0] // empty' "${provisioner_file}")"
    # No router row => single-switch topology. Leave ROUTER_* unset so every
    # downstream helper takes its legacy direct-routing branch.
    [[ -z "${router_row}" ]] && return 0

    local router_vm_name router_switch static_router_ip
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
    local portproxy_port target_ip wsl_gateway
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
            echo "_resolve-router.sh: WSL detected; routing via host portproxy ${target_ip}:${portproxy_port} -> ${ROUTER_IP}:22"
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

    # Router reachability pre-flight. A non-zero exit (unreachable) aborts
    # the bridge under the caller's set -e - before ansible-playbook spends
    # its ~136s per-host connect-retry budget on a hop already proved broken.
    # The helper's stderr names the failed segment.
    "${router_dir}/_assert-router-reachable.sh" "${ROUTER_SSH_HOST}" "${ROUTER_PORT:-22}"
}
