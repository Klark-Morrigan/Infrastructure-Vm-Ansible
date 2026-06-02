# Role: sudoers

Reconciles per-user `/etc/sudoers.d/<username>` drop-ins. Third role
applied by
[`playbooks/create-users.yml`](../../playbooks/create-users.yml); runs
after `roles/users` so each account referenced by a drop-in already
exists.

## Index

- [Var contract](#var-contract)
- [Behaviour](#behaviour)
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

Molecule scenario under
[`Tests/molecule/sudoers/default/`](../../Tests/molecule/sudoers/default/)
runs the role against an Ubuntu 24.04 Docker container and covers:

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

## Rationale

See [problem.md - Role: sudoers](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-sudoers)
for the verbatim-string contract, `visudo` validation, and empty-list
removal decisions captured during design.
