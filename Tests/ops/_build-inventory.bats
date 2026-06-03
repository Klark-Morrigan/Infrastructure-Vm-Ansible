#!/usr/bin/env bats
# Tests for ops/_build-inventory.sh - the pure stdin -> stdout
# transform that turns vm_provisioner_config into Ansible JSON
# inventory. No stubs needed: the script's only external dep is jq,
# and the test runs the real one. Output is compared structurally
# (jq -S) so key-order differences don't make assertions brittle.
# Run with: bats Tests/ops/_build-inventory.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_build-inventory.sh"

setup() {
    BASH_BIN="$(command -v bash)"
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

@test "single VM produces the expected inventory shape with all six host vars" {
    input='[{"vmName":"vm-01","ipAddress":"10.0.0.1","username":"u","password":"p"}]'
    expected='{
        "all": {
            "children": {
                "vm_provisioner_hosts": {
                    "hosts": {
                        "vm-01": {
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

@test "empty stdin fails fast" {
    run "${BASH_BIN}" "${SCRIPT}" <<< ''
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no input on stdin"* ]]
}
