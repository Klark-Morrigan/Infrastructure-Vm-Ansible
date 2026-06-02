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
        . as $vms
        | range(0; length) as $i
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
