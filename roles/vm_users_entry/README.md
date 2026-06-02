# Role: vm_users_entry

Repo-internal helper. Resolves the `VmUsersConfig` entry for the
current host into the shared `vm_users_entry` fact, used by
[`roles/groups`](../groups/README.md), [`roles/users`](../users/README.md),
and [`roles/sudoers`](../sudoers/README.md) via meta dependency.

## Why this role exists

Each of the three consumer roles previously carried its own copy of
the same selectattr-then-first lookup, under three different fact
names (`_groups_vm_entry`, `_users_vm_entry`, `_sudoers_vm_entry`).
Single source of truth: changing the selector (vault schema rename,
swapping `vmName` for an id field, etc.) now touches one file
instead of three. Ansible deduplicates meta-dependency invocations
within a play, so the helper still runs exactly once even when all
three consumers are applied in sequence.

## Var contract

- **Reads**: `vm_users_config` (the verbatim `VmUsersConfig` JSON
  array written into extra-vars by the bash bridge).
- **Sets**: `vm_users_entry` - the single object whose `vmName`
  matches `inventory_hostname`, or `{}` if none does (the
  no-host-config case). Subsequent roles read `vm_users_entry.groups`
  or `vm_users_entry.users` directly.
