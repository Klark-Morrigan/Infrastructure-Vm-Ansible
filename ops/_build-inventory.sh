#!/usr/bin/env bash
# Transforms the vm_provisioner_config JSON array (read on stdin) into
# an Ansible JSON inventory (written to stdout). Pure transform: no
# pwsh.exe, no filesystem writes, no environment dependencies beyond
# jq. Composable with shell redirection.
#
# Shape produced:
#
#   {
#     "all": {
#       "children": {
#         "vm_provisioner_hosts": {
#           "hosts": {
#             "<vmName>": {
#               "ansible_host":         "<ipAddress>",
#               "ansible_user":         "<username>",
#               "ansible_password":     "<password>",
#               "ansible_become":       true,
#               "ansible_become_method":"sudo",
#               "ansible_become_pass":  "<password>"
#             }, ...
#           }
#         }
#       }
#     }
#   }
#
# ansible_password and ansible_become_pass are sourced from the SAME
# vault field: the cloud-init admin user this controller logs in as
# also `sudo`s on the VM, and the provisioner writes one password
# for that account. Splitting them would require a second secret with
# no operator benefit. The custom-powershell flow
# (Infrastructure-Vm-Users/.../create-users.ps1) uses the same field
# for both via SSH.NET's PasswordAuthenticationMethod, so the two
# flows stay credential-symmetric.
#
# Ansible accepts JSON inventory natively, so emitting JSON avoids
# pulling in yq as a hard dep and keeps the file directly diff-able
# with `jq` while debugging.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Slurp stdin. The whole document is small (an array of VM defs);
#    reading it into memory and validating it in one jq invocation is
#    simpler than streaming and gives a single point to surface
#    field-level errors with the offending index named.
# ---------------------------------------------------------------------------
input="$(cat)"

if [[ -z "${input}" ]]; then
    echo "_build-inventory.sh: no input on stdin" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Per-VM required-field check. We loop in jq rather than letting the
#    null coercion silently emit ansible_host=null - a missing field is
#    a config error the operator must see, and naming the array index
#    plus field is what makes the error actionable. The check is
#    separated from the inventory build below so the error path is one
#    pipeline stage with a clean exit code.
# ---------------------------------------------------------------------------
if ! err="$(printf '%s' "${input}" | jq -r '
    if type != "array" then
        "_build-inventory.sh: input must be a JSON array of VM objects"
    else
        # Drop router VMs before the required-field check. Routers are
        # network infrastructure (NAT/DNS for the per-environment
        # private switch); Ansible never reconciles users / runners /
        # files on them, so including them would only surface false
        # "ipAddress missing" failures for DHCP-mode routers whose
        # upstream IP is discovered at boot and never written back to
        # the vault. kind == "router" => drop; anything else (kind
        # unset OR any other value) is a workload and kept.
        [ .[] | select((.kind // "") != "router") ] as $vms
        | range(0; $vms | length) as $i
        | $vms[$i] as $vm
        | ["vmName", "ipAddress", "username", "password"]
        | map(
            select(($vm[.] // "") == "")
            | "_build-inventory.sh: VM at index \($i) is missing required field \"\(.)\""
          )
        | .[]
    end
' 2>&1)"; then
    echo "_build-inventory.sh: jq failed validating input: ${err}" >&2
    exit 1
fi

if [[ -n "${err}" ]]; then
    echo "${err}" >&2
    exit 1
fi

# Re-apply the router filter to the inventory-building pipeline below.
# The validation block above filtered into its own jq-local $vms but
# the next jq invocation reads from $input - reapply so the output
# excludes the same rows.
input="$(printf '%s' "${input}" | jq '[ .[] | select((.kind // "") != "router") ]')"

# ---------------------------------------------------------------------------
# 3. Build the inventory. The `add // {}` tail collapses the per-VM
#    objects into a single map and handles the empty-array case
#    (`add` on `[]` is null - `// {}` falls back to an empty hosts
#    map, which Ansible accepts and reports as "no hosts").
# ---------------------------------------------------------------------------
printf '%s' "${input}" | jq '
    {
        all: {
            children: {
                vm_provisioner_hosts: {
                    hosts: (
                        map({
                            (.vmName): {
                                ansible_host:          .ipAddress,
                                ansible_user:          .username,
                                ansible_password:      .password,
                                ansible_become:        true,
                                ansible_become_method: "sudo",
                                ansible_become_pass:   .password
                            }
                        })
                        | add // {}
                    )
                }
            }
        }
    }
'
