#!/usr/bin/env bats
# Tests for ops/virtual-machines/_build-inventory.sh - the pure stdin -> stdout
# transform that turns vm_provisioner_config into Ansible JSON
# inventory. Its only runtime deps are jq (the real one is used) and the
# shared logger it sources via _log.sh; _bats_init_temp stands up the
# COMMON_AUTOMATION_ROOT stub that the logger shim resolves. Output is
# compared structurally (jq -S) so key-order differences don't make
# assertions brittle.
# Run with: bats Tests/ops/_build-inventory.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops/virtual-machines" && pwd)/_build-inventory.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp buildInventory
}

teardown() {
    _bats_cleanup_temp
}

# json_eq <expected-json> <actual-json> - structural JSON equality
# via jq's sort-keys + deep-equal. Avoids whitespace and key-order
# fragility that string-equality would impose.
json_eq() {
    local expected="$1"
    local actual="$2"
    diff <(printf '%s' "${expected}" | jq -S .) \
         <(printf '%s' "${actual}"   | jq -S .)
}

@test "empty array yields empty hosts map (Ansible-valid)" {
    run "${BASH_BIN}" "${SCRIPT}" <<< '[]'
    [ "${status}" -eq 0 ]
    json_eq '{"all":{"children":{"vm_provisioner_hosts":{"hosts":{}}}}}' "${output}"
}

@test "single VM produces the expected inventory shape with all host vars" {
    input='[{"vmName":"vm-01","ipAddress":"10.0.0.1","username":"u","password":"p"}]'
    expected='{
        "all": {
            "children": {
                "vm_provisioner_hosts": {
                    "hosts": {
                        "vm-01": {
                            "ansible_connection":    "ssh",
                            "ansible_host":          "10.0.0.1",
                            "ansible_user":          "u",
                            "ansible_password":      "p",
                            "ansible_become":        true,
                            "ansible_become_method": "sudo",
                            "ansible_become_pass":   "p"
                        }
                    }
                }
            }
        }
    }'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    json_eq "${expected}" "${output}"
}

@test "multi-VM input maps each host by vmName" {
    input='[
        {"vmName":"a","ipAddress":"10.0.0.1","username":"u1","password":"p1"},
        {"vmName":"b","ipAddress":"10.0.0.2","username":"u2","password":"p2"}
    ]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    # Verify both keys present and per-host vars routed correctly.
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts | keys | sort | join(",")')" = "a,b" ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.a.ansible_host')" = "10.0.0.1" ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.b.ansible_host')" = "10.0.0.2" ]
}

@test "VM missing vmName fails with the offending index and field named" {
    input='[
        {"vmName":"a","ipAddress":"10.0.0.1","username":"u","password":"p"},
        {                "ipAddress":"10.0.0.2","username":"u","password":"p"}
    ]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"index 1"* ]]
    [[ "${output}" == *"vmName"* ]]
}

@test "VM missing any other required field fails with that field named" {
    input='[{"vmName":"a","ipAddress":"10.0.0.1","username":"u"}]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"password"* ]]
}

@test "non-array input fails with a clear error" {
    run "${BASH_BIN}" "${SCRIPT}" <<< '{"vmName":"a"}'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a JSON array"* ]]
}

@test "router VMs are dropped from the inventory" {
    # Routers are network infrastructure (NAT/DNS for the per-env
    # private switch) and never get Ansible-reconciled. The DHCP-mode
    # default has no ipAddress on the router row; without the filter
    # the required-field check would reject the input. With it, the
    # workload survives untouched and the router is silently elided.
    input='[
        {"vmName":"router","kind":"router","username":"r","password":"rp"},
        {"vmName":"wl","ipAddress":"10.0.0.10","username":"u","password":"p"}
    ]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts | keys | join(",")')" = "wl" ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_host')" = "10.0.0.10" ]
}

@test "router-only input yields an empty hosts map (no workload to reconcile)" {
    # The all-router edge case: the operator's config has only a
    # router. Ansible has nothing to do; the output must still be a
    # valid Ansible inventory shape (empty hosts map) so downstream
    # tooling does not blow up on a missing key.
    input='[{"vmName":"router","kind":"router","username":"r","password":"rp"}]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    json_eq '{"all":{"children":{"vm_provisioner_hosts":{"hosts":{}}}}}' "${output}"
}

@test "ROUTER_IP unset: ansible_ssh_common_args is omitted (legacy direct path)" {
    # Regression guard: the absence-path must preserve byte-identical
    # output for pre-feature-53 callers. A workload entry with no
    # router context must NOT carry ansible_ssh_common_args.
    input='[{"vmName":"wl","ipAddress":"10.0.0.10","username":"u","password":"p"}]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_ssh_common_args // "ABSENT"')" = "ABSENT" ]
}

@test "ROUTER_IP set: workload entries get ansible_ssh_common_args with ProxyCommand+sshpass" {
    # When the caller exports ROUTER_IP + ROUTER_USERNAME, every workload
    # row gains an ansible_ssh_common_args clause that routes its ssh
    # through the router. The clause must (a) name the router IP and
    # user, (b) use sshpass -e so the router password is read from
    # $SSHPASS not argv, (c) disable host-key checks on both legs.
    input='[{"vmName":"wl","ipAddress":"10.99.0.10","username":"u","password":"p"}]'
    ROUTER_IP=192.168.1.42 ROUTER_USERNAME=routeradmin \
        run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    ssh_args="$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_ssh_common_args')"
    [[ "${ssh_args}" == *"ProxyCommand="* ]]
    [[ "${ssh_args}" == *"sshpass -e ssh"* ]]
    [[ "${ssh_args}" == *"routeradmin@192.168.1.42"* ]]
    [[ "${ssh_args}" == *"StrictHostKeyChecking=no"* ]]
    [[ "${ssh_args}" == *"UserKnownHostsFile=/dev/null"* ]]
    # ConnectTimeout must bound BOTH the inner (router) and outer ssh so an
    # unreachable hop fails fast instead of hanging on SYN retries.
    [[ "${ssh_args}" == *"ConnectTimeout=10"* ]]
    [ "$(printf '%s' "${ssh_args}" | grep -o 'ConnectTimeout=10' | wc -l)" -eq 2 ]
}

@test "workload entries pin ansible_connection=ssh (delegated probes do not inherit connection: local)" {
    # The deregister reachability probe runs in a connection: local play and
    # delegate_to's each VM; without an explicit ansible_connection the
    # delegated wait_for_connection would inherit local (always "reachable")
    # instead of probing the VM. Pinning ssh is unconditional - present even
    # on the legacy direct-routing path (no ROUTER_IP).
    input='[{"vmName":"wl","ipAddress":"10.99.0.10","username":"u","password":"p"}]'
    run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_connection')" = "ssh" ]
}

@test "ROUTER_IP set: router password is NOT embedded in ansible_ssh_common_args" {
    # Security guard: the router password must come from $SSHPASS at
    # sshpass invocation time, never embedded in the inventory. A
    # leaked secret would survive in the chmod-600 inventory file
    # AND in any process listing that observed ansible-playbook's
    # argv.
    input='[{"vmName":"wl","ipAddress":"10.99.0.10","username":"u","password":"p"}]'
    ROUTER_IP=192.168.1.42 ROUTER_USERNAME=routeradmin \
        run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    ssh_args="$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_ssh_common_args')"
    [[ "${ssh_args}" != *"sshpass -p"* ]]
}

@test "ROUTER_PORT set: ProxyCommand injects -p <port> into the inner ssh" {
    # When the caller routes through a host portproxy (typical of
    # WSL2-on-Windows where the router is on an Internal switch),
    # ROUTER_IP=127.0.0.1 + ROUTER_PORT=<listen_port> redirects the
    # ProxyCommand's inner ssh to the loopback shortcut. The -p
    # flag must be present so ssh hits the portproxy listener, not
    # 22 on localhost (which would refuse).
    input='[{"vmName":"wl","ipAddress":"10.99.0.10","username":"u","password":"p"}]'
    ROUTER_IP=127.0.0.1 ROUTER_PORT=2222 ROUTER_USERNAME=routeradmin \
        run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    ssh_args="$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_ssh_common_args')"
    [[ "${ssh_args}" == *"-p 2222"* ]]
    [[ "${ssh_args}" == *"routeradmin@127.0.0.1"* ]]
}

@test "ROUTER_PORT unset: ProxyCommand has no -p flag (defaults to ssh's port 22)" {
    # Direct-routing operators (Linux CI, bridged-Ethernet hosts)
    # do not need the portproxy redirect. Absence of ROUTER_PORT
    # MUST NOT inject an empty -p flag (ssh rejects '-p ' with a
    # parse error).
    input='[{"vmName":"wl","ipAddress":"10.99.0.10","username":"u","password":"p"}]'
    ROUTER_IP=192.168.1.42 ROUTER_USERNAME=routeradmin \
        run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    ssh_args="$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_ssh_common_args')"
    [[ "${ssh_args}" != *" -p "* ]]
}

@test "ROUTER_USERNAME unset: no ProxyCommand injection even if ROUTER_IP is set" {
    # Partial context is treated as no-context to avoid emitting a
    # malformed ProxyCommand that ssh would reject with an opaque
    # parse error.
    input='[{"vmName":"wl","ipAddress":"10.99.0.10","username":"u","password":"p"}]'
    ROUTER_IP=192.168.1.42 \
        run "${BASH_BIN}" "${SCRIPT}" <<< "${input}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.all.children.vm_provisioner_hosts.hosts.wl.ansible_ssh_common_args // "ABSENT"')" = "ABSENT" ]
}

@test "empty stdin fails fast" {
    run "${BASH_BIN}" "${SCRIPT}" <<< ''
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no input on stdin"* ]]
}
