# Role: groups

Reconciles declared OS groups on the target VM. First role applied by
[`playbooks/create-users.yml`](../../playbooks/create-users.yml) so that
primary and supplementary groups exist before the `users` role runs.

## Index

- [Var contract](#var-contract)
- [Behaviour](#behaviour)
- [Idempotence guarantees](#idempotence-guarantees)
- [Tests](#tests)
- [Rationale](#rationale)

## Var contract

The role reads one extra-var, `vm_users_config`, written by the bash
bridge ([`ops/_build-extra-vars.sh`](../../ops/_build-extra-vars.sh)) as
the verbatim `VmUsersConfig` JSON array. It picks out the entry for the
current host by matching `vmName` against `inventory_hostname` and then
iterates that entry's `groups` array.

Per-entry shape consumed:

```yaml
vmName: ubuntu-01-ci          # selector
groups:                       # optional; absent or empty -> no-op
  - groupName: docker         # required
    gid: 8000                 # optional
```

Hosts with no matching entry, or an entry with no `groups` key, produce
zero tasks - the role is safe to apply to every host in the play.

## Behaviour

For each declared group, `ansible.builtin.group` is invoked with
`state: present`. `gid` is omitted when absent (kernel-assigned) and
passed through when present.

## Idempotence guarantees

- Re-running with the same config reports `changed: 0`. The
  `ansible.builtin.group` module compares declared state against the
  live state and no-ops when they match.
- Declaring a `gid` that conflicts with an existing group of the same
  name fails the play. This matches the "GIDs never silently change"
  decision in [problem.md](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-groups) -
  on-disk numeric ownership does not drift under the role's feet.
- The role never removes groups. Empty / absent input means "nothing
  declared", not "remove everything"; removal lives in the
  feature 03 remove flow.

## Tests

Molecule scenario under
[`Tests/roles/groups/molecule/default/`](../../Tests/roles/groups/molecule/default/)
runs the role against an Ubuntu 24.04 Docker container and covers:

- Empty groups list - no changes, no errors.
- New group without `gid` - group exists after.
- New group with `gid: 8000` - group exists with the declared gid.
- Idempotence - second converge reports `changed: 0`.
- Existing group with mismatched `gid` - play fails with the group
  name in the message; live state untouched.

## Rationale

See [problem.md - Role: groups](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-groups)
for the module / GID / loop-input decisions captured during design.
