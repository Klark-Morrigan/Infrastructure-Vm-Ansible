#!/usr/bin/env bash
# Pre-flight reachability probe for the router SSH hop. Every workload
# ssh is threaded through the router via the per-host ProxyCommand at
# <router-ip>:<port>; when that hop is broken - a stale netsh portproxy
# relay, a half-booted router, a dropped packet - Ansible only surfaces
# it as an opaque "Connection timed out during banner exchange"
# UNREACHABLE, and only after exhausting its per-host connect-retry
# budget (~136s). Probing the same hop here localises the failure to a
# segment - TCP reachability vs SSH banner - in seconds and lets the
# caller abort before the playbook pays that cost.
#
# Boundary: nc + ssh, the same tools the ProxyCommand uses, so the probe
# traverses the exact path. Auth is deliberately NOT exercised - a
# BatchMode ssh that reaches the banner (even "Permission denied")
# proves the relay and the router sshd are alive. Only a timed-out /
# banner-exchange / refused result is a failure.
#
# Usage: _assert-router-reachable.sh <router-ip> [port]
#   exit 0  reachable (TCP + SSH banner)
#   exit 1  unreachable - the message on stderr names the failed segment

set -euo pipefail

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"

router_ip="${1:?_assert-router-reachable.sh: router IP required}"
probe_port="${2:-22}"

log_info "probing router reachability at ${router_ip}:${probe_port} ..."

# Segment 1: TCP. A failure here means the connection never reaches the
# router sshd at all (the relay is not delivering).
if ! nc -z -w5 "${router_ip}" "${probe_port}" 2>/dev/null; then
    log_err "ROUTER UNREACHABLE - TCP connect to ${router_ip}:${probe_port} failed."
    echo "  Segment: controller -> host portproxy -> router. The relay is not" >&2
    echo "  delivering (the router sshd never sees the connection). This is the" >&2
    echo "  portproxy/relay or router-readiness segment, not Ansible." >&2
    exit 1
fi

# Segment 2: SSH banner. TCP opened, so the relay accepted the
# connection - but if no banner comes back the relay is half-open or the
# router sshd is not answering. grep matches only the failure phrases; a
# "Permission denied" (auth stage reached) is a healthy banner.
banner="$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "${probe_port}" "sshprobe@${router_ip}" true 2>&1 || true)"
if printf '%s' "${banner}" \
    | grep -qiE 'timed out|banner exchange|connection refused|no route to host'; then
    log_err "ROUTER SSH BANNER FAILED at ${router_ip}:${probe_port}:"
    printf '  %s\n' "${banner}" >&2
    echo "  Segment: TCP opened but no SSH banner returned - the relay is half-open" >&2
    echo "  or the router sshd is not answering. Not an Ansible fault." >&2
    exit 1
fi

log_info "router reachable (TCP + SSH banner OK at ${router_ip}:${probe_port})."
