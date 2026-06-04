# Role: sudoers

Reconciles per-user `/etc/sudoers.d/<username>` drop-ins. Third role
applied by
[`playbooks/create-users.yml`](../../playbooks/create-users.yml); runs
after `roles/users` so each account referenced by a drop-in already
exists.

## Index

- [Var contract](#var-contract)
- [Behaviour](#behaviour)
- [Remove direction](#remove-direction)
- [Idempotence guarantees](#idempotence-guarantees)
- [Tests](#tests)
- [Rationale](#rationale)

## Var contract

The role reads `vm_users_config` (the verbatim `VmUsersConfig` JSON
array written by the bash bridge - see
[`ops/_build-extra-vars.sh`](../../ops/_build-extra-vars.sh)), selects
the entry for the current host by matching `vmName` against
`inventory_hostname`, and iterates that entry's `users` array. Only
the `username` and `sudoersRules` fields are consumed here; the rest
of the user record belongs to `roles/users`.

```yaml
vmName: ubuntu-01-ci             # selector
users:                           # optional; absent or empty -> no-op
  - username: alice              # required (drop-in filename)
    sudoersRules:                # optional; empty/absent -> file absent
      - "alice ALL=(ALL) NOPASSWD:ALL"
      - "alice ALL=(root) /usr/bin/systemctl restart nginx"
```

`sudoersRules` strings are written into the drop-in **verbatim**. The
role does not parse, quote, or validate field-by-field; `visudo -cf`
is what gates correctness at apply time.

## Behaviour

Two tasks, gated by whether `sudoersRules` is non-empty:

- **Non-empty** -> `ansible.builtin.template` renders
  [`sudoers.j2`](templates/sudoers.j2) to
  `/etc/sudoers.d/<username>` with `owner=root`, `group=root`,
  `mode=0440`, and `validate: 'visudo -cf %s'`. `validate` runs against
  the staged temp file before the atomic swap, so a syntax error fails
  the task and leaves the live file untouched.
- **Empty / absent** -> `ansible.builtin.file` removes
  `/etc/sudoers.d/<username>` if it exists. Matches the legacy flow's
  "empty list = file absent" contract; an operator clearing the array
  wants the file gone.

Mode `0440 root:root` is the only ownership/mode `sudo` honours under
`/etc/sudoers.d/`; anything else and the file is silently ignored.

## Remove direction

[`tasks/remove.yml`](tasks/remove.yml) is the symmetric entry point
for the teardown play
([`playbooks/remove-users.yml`](../../playbooks/remove-users.yml)).
Invoke via:

```yaml
- ansible.builtin.import_role:
    name: sudoers
    tasks_from: remove
```

Shape is a single `ansible.builtin.file` task with `state: absent`,
looping over `vm_users_entry.users | default([])` and targeting
`/etc/sudoers.d/{{ item.username }}`. Contract:

- Only **declared** usernames are touched. A drop-in for a user not
  present in this host's `VmUsersConfig` entry is left in place;
  drift removal is out of scope (see problem.md).
- Absence of a declared drop-in is not an error - stock behaviour of
  `ansible.builtin.file` with `state: absent`.
- `visudo` is not invoked. Removing a drop-in cannot produce a broken
  sudoers config, only a smaller one.
- The `sudoersRules` field is irrelevant here - "no rule = no file"
  already holds on the create side, so the remove direction does not
  need to branch on it.

The remove direction runs **first** in the teardown play (sudoers ->
users -> groups), so an interrupted run never leaves a drop-in
pointing at a user that has already been deleted.

## Idempotence guarantees

- Re-running with the same config reports `changed: 0` across both
  tasks. Templates only re-render when the rendered bytes differ.
- Changing or adding a rule produces `changed: 1` on the next run for
  the affected user; the new file lands atomically after
  `visudo -cf` accepts it.
- Removing all rules removes the drop-in file. Adding rules back
  re-creates it - no orphaned 0440 file in between.
- A rule with invalid syntax fails the task for that user via
  `visudo`. The live `/etc/sudoers.d/<username>` is untouched
  because validation runs on the temp file before the swap; other
  users in the same play continue to reconcile normally.
- The role never deletes accounts. Removing the user entry from
  config drops the drop-in (the loop no longer sees the user) but
  the OS account remains - account removal lives in the feature 03
  remove flow.

## Tests

Two Molecule scenarios, both against an Ubuntu 24.04 Docker container.

[`Tests/molecule/sudoers/default/`](../../Tests/molecule/sudoers/default/)
exercises the create direction (`tasks/main.yml`):

- User with one rule - file exists with mode `0440` and contains the
  rule verbatim.
- User with multiple rules - file exists with all rules in declared
  order.
- User with an empty `sudoersRules` array - drop-in is absent
  (removed if previously present).
- Idempotence - second converge with the same input reports
  `changed: 0`.
- Rule with invalid syntax - play fails with a `visudo` error and the
  live file on the VM is unchanged from the previous successful run.

[`Tests/molecule/sudoers/remove/`](../../Tests/molecule/sudoers/remove/)
exercises the remove direction (`tasks/remove.yml`). `prepare` seeds
`/etc/sudoers.d/<username>` files for declared users plus one
out-of-config drop-in; `converge` invokes the role with
`tasks_from: remove`; `verify` covers:

- Seeded drop-ins for declared users are absent after converge.
- A seeded drop-in for an undeclared user is still present (drift
  removal is out of scope).
- A drop-in declared for a different `vmName` does not leak onto this
  host (selectattr filter applies to the remove direction too).
- Re-converge against an already-removed drop-in reports no error and
  no resurrection.
- An empty `users` list runs zero iterations and touches no files.

## Rationale

See [problem.md - Role: sudoers](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-sudoers)
for the create-side decisions (verbatim-string contract, `visudo`
validation, empty-list removal).

The remove direction's contract (declared-only, no `visudo`,
absence-is-not-an-error) is captured in
[`docs/dev/implementation/03-groups-users-sudoers-removal/problem.md`](../../docs/dev/implementation/03-groups-users-sudoers-removal/problem.md#role-sudoers-remove).
