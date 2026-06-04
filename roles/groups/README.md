# Role: groups

Reconciles declared OS groups on the target VM. First role applied by
[`playbooks/create-users.yml`](../../playbooks/create-users.yml) so that
primary and supplementary groups exist before the `users` role runs.

## Index

- [Var contract](#var-contract)
- [Behaviour](#behaviour)
- [Remove direction](#remove-direction)
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

## Remove direction

[`tasks/remove.yml`](tasks/remove.yml) is the symmetric entry point
for the teardown play
([`playbooks/remove-users.yml`](../../playbooks/remove-users.yml)).
Invoke via:

```yaml
- ansible.builtin.import_role:
    name: groups
    tasks_from: remove
```

Three tasks per declared group:

1. **Probe** - `getent group <name>` with `failed_when: false` and
   `changed_when: false`. rc!=0 means the group is already gone and
   the iteration becomes a silent skip (matches the legacy
   "absent -> skip" contract). The members field is field 4 of the
   colon-separated record.
2. **Remove (empty)** - `ansible.builtin.group` with `state: absent`,
   gated on `rc == 0` **and** members field empty. This is the only
   path that mutates `/etc/group`.
3. **Warn (non-empty)** - `ansible.builtin.debug` naming the
   remaining members for any declared group that still has members.
   The group is intentionally **kept**, not forced out, because
   removing it would silently strip a supplementary group from every
   still-resident member account.

Contract:

- Only **declared** groups are considered. A group on the VM that is
  not in this host's `VmUsersConfig` entry is left alone; drift
  removal is out of scope (see problem.md).
- Absent declared group -> skip silently (no error, no change).
- Empty declared group -> removed.
- Non-empty declared group -> kept, with a debug message naming the
  remaining members so the operator can decide whether to clear them
  and re-run.
- The probe is read-only (`changed_when: false`), and the warning
  task carries no `state` change either, so a re-run against a still
  non-empty group stays idempotent at the "changed task count" level
  even though the warning fires again.

The remove direction runs **last** in the teardown play (sudoers ->
users -> groups), so by the time it executes, the preceding role's
`userdel` has already cleared each removed account's supplementary
group memberships. A group that was declared purely for the users
the teardown just removed will appear empty here and be removed in
the same operator action.

## Idempotence guarantees

- Re-running with the same config reports `changed: 0`. The
  `ansible.builtin.group` module compares declared state against the
  live state and no-ops when they match.
- Declaring a `gid` that conflicts with an existing group of the same
  name fails the play. This matches the "GIDs never silently change"
  decision in [problem.md](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-groups) -
  on-disk numeric ownership does not drift under the role's feet.
- The create direction (`tasks/main.yml`) never removes groups.
  Empty / absent input means "nothing declared", not "remove
  everything". Removal is a separate operator action via
  `tasks_from: remove` (see [Remove direction](#remove-direction)).

## Tests

Two Molecule scenarios, both against an Ubuntu 24.04 Docker container.

[`Tests/molecule/groups/default/`](../../Tests/molecule/groups/default/)
exercises the create direction (`tasks/main.yml`):

- Empty groups list - no changes, no errors.
- New group without `gid` - group exists after.
- New group with `gid: 8000` - group exists with the declared gid.
- Idempotence - second converge reports `changed: 0`.
- Existing group with mismatched `gid` - play fails with the group
  name in the message; live state untouched.

[`Tests/molecule/groups/remove/`](../../Tests/molecule/groups/remove/)
exercises the remove direction (`tasks/remove.yml`). `prepare` seeds
declared groups (one empty, one with an out-of-config member, one not
created at all) plus a group declared for a different `vmName`;
`converge` invokes the role with `tasks_from: remove`; `verify`
covers:

- Declared empty group is removed.
- Declared absent group - probe returns rc!=0, no removal attempted,
  no error.
- Declared group with an out-of-config member is kept; the warning
  task fires and names the member.
- Group declared on a different `vmName` is left untouched on this
  host (selectattr filter applies to the remove direction too).
- Re-converge after removal is a clean no-op for the now-absent
  groups, and the warning task is still idempotent for the still
  non-empty group (`changed_when: false` on the probe).
- An empty `groups` list runs zero iterations and touches nothing.

## Rationale

See [problem.md - Role: groups](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-groups)
for the module / GID / loop-input decisions captured during design.
