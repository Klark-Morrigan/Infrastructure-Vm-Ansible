# Role: users

Reconciles declared OS users on the target VM. Second role applied by
[`playbooks/create-users.yml`](../../playbooks/create-users.yml); runs
after `roles/groups` so primary and supplementary groups are already
present.

## Index

- [Var contract](#var-contract)
- [Behaviour](#behaviour)
- [Password handling](#password-handling)
- [Remove direction](#remove-direction)
- [Idempotence guarantees](#idempotence-guarantees)
- [Tests](#tests)
- [Rationale](#rationale)

## Var contract

The role reads one extra-var, `vm_users_config`, written by the bash
bridge ([`ops/_build-extra-vars.sh`](../../ops/_build-extra-vars.sh)) as
the verbatim `VmUsersConfig` JSON array. It selects the entry for the
current host by matching `vmName` against `inventory_hostname` and then
iterates that entry's `users` array.

Per-entry shape consumed:

```yaml
vmName: ubuntu-01-ci             # selector
users:                           # optional; absent or empty -> no-op
  - username: alice              # required
    shell: /bin/bash             # required
    homeDir: /home/alice         # required
    groups: [docker]             # optional; supplementary groups
    password: "<plaintext>"      # optional; hashed controller-side
```

`sudoersRules` on a user entry is consumed by `roles/sudoers`, not by
this role.

## Behaviour

For each declared user, `ansible.builtin.user` is invoked with
`state: present`, `append: false`, and `move_home: false`. The
`groups` argument is the authoritative supplementary-group list -
because `append: false`, dropping a group from config removes the
user from that group on the next run.

The `password` argument is a ternary: users with a declared
`password` get the hashed value (see below), users without get
`omit` so the account's authentication state is left untouched -
the "do not lock the account" branch from the plan.
`update_password: always` stays unconditional; it has no effect
when `password` is omitted. The task runs with `no_log: true`,
so per-iteration `--diff` output is suppressed; the
`loop_control.label` keeps per-user traceability in the play
recap.

## Password handling

When `password` is declared in config, it is hashed on the controller
via `password_hash('sha512', salt=...)` and written to `/etc/shadow`
verbatim. Plaintext never crosses the wire; the `no_log: true` on the
password task keeps it out of `--verbose` output too.

The salt is the first 16 hex chars of `md5(username)`:

```
salt = (item.username | hash('md5'))[:16]
```

MD5 here is a stable bucketing function from username to a 16-char
string in SHA-512 crypt's salt charset (`[a-f0-9]` is a subset of
`[A-Za-z0-9./]`). It is **not** a cryptographic primitive in this
context. The salt's job in `/etc/shadow` is uniqueness across users
(defeats rainbow tables, since users with identical passwords still
end up with different hashes); the determinism is what gives true
idempotence: re-running with the same plaintext yields the same
crypt string, so `ansible.builtin.user` sees no diff and reports
`changed: 0`. A random salt per run would re-hash to a different
value every reconcile and the task would always report `changed`,
hiding genuine drift.

## Remove direction

[`tasks/remove.yml`](tasks/remove.yml) is the symmetric entry point
for the teardown play
([`playbooks/remove-users.yml`](../../playbooks/remove-users.yml)).
Invoke via:

```yaml
- ansible.builtin.import_role:
    name: users
    tasks_from: remove
```

Three tasks per declared user:

1. **Pre-kill** - `pkill -KILL -u <username>`. rc=1 (no matching
   process) is the common case and is treated as success; rc>=2
   (syntax or fatal error) fails the play. `changed_when: rc == 0`
   keeps re-runs against a now-quiet account idempotent.
2. **userdel** - `ansible.builtin.user` with `state: absent`,
   `remove: true` (deletes the home directory and mail spool), and
   `force: true` (`userdel -f`, belt-and-braces if the pre-kill
   missed). `failed_when: false` lets the loop visit every declared
   user even if one removal errors, so a single stuck account does
   not strand the rest.
3. **Final assert** - inspects `users_remove_results.results` and
   fails the play if any iteration was marked `failed`. Restores a
   non-zero exit code so a stuck removal stays loud.

The pre-kill is the substantive departure from
[Infrastructure-Vm-Users' legacy `remove-users.ps1`](https://github.com/Klark-Morrigan/Infrastructure-Vm-Users)
flow, which surfaced an error and moved on when the user had running
processes, leaving the account stuck. Operator-driven removal is a
declared act here, and leaving processes alive is the surprising
outcome - so we issue SIGKILL first, then let `userdel -f` clear
whatever is left. The per-iteration capture + final assert covers
the rare case the pre-kill cannot free the account (e.g. a D-state
task whose parent is a kernel thread).

Contract:

- Only **declared** usernames are touched. An account on the VM
  that is not in this host's `VmUsersConfig` entry is left alone;
  drift removal is out of scope (see problem.md).
- Absence of a declared account is not an error - `userdel`
  behaviour, surfaced verbatim, no special-case branch needed.
- The user's implicit primary group (same name, no other members)
  is cleared automatically by `userdel`; the `groups` role's remove
  direction then handles named groups in `vm_users_config.groups`.
- Home directories are removed by `remove: true`. Unlike the create
  direction's `move_home: false`, this is symmetric with operator
  intent: a declared removal includes the on-disk data.

The remove direction runs **second** in the teardown play
(sudoers -> users -> groups), so sudoers drop-ins are already gone
by the time the account is deleted (no dangling `/etc/sudoers.d/`
entry pointing at a missing user) and named groups are still
present in case userdel needs to read them.

## Idempotence guarantees

- Re-running with the same config reports `changed: 0` across both
  user tasks. The deterministic salt is what enables this under
  `update_password: always`.
- Changing `password` in config produces `changed: 1` on the next
  run; the new hash lands in `/etc/shadow`.
- Removing a group from a user's `groups` array removes the user
  from that group on the next run (`append: false`).
- Changing `homeDir` updates the home column in `/etc/passwd` but
  **does not** move the on-disk directory (`move_home: false`).
  Migrating data is an explicit operator step, by design - see
  [problem.md](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#out-of-scope-for-this-feature).
- The role never deletes users. Empty / absent input means "nothing
  declared", not "remove everything"; removal lives in the
  feature 03 remove flow.

## Tests

Two Molecule scenarios, both against an Ubuntu 24.04 Docker container.

[`Tests/molecule/users/default/`](../../Tests/molecule/users/default/)
exercises the create direction (`tasks/main.yml`):

- User with `nologin` shell - created; cannot log in interactively.
- User with bash shell and a password - created; `/etc/shadow` entry
  starts with `$6$` and uses the expected 16-char salt.
- Idempotence - second converge with the same input reports
  `changed: 0` (proves the deterministic salt).
- Password change in config - `changed: 1`, new hash in shadow.
- Supplementary group removed from config - `getent group` no longer
  lists the user.
- `homeDir` changed in config - `/etc/passwd` updates, but the
  on-disk directory at the old path still exists
  (proves `move_home: false`).

[`Tests/molecule/users/remove/`](../../Tests/molecule/users/remove/)
exercises the remove direction (`tasks/remove.yml`). `prepare` seeds
accounts directly (declared idle, declared without a home, declared
with a long-running process, undeclared drift, and a fixture for a
different `vmName`); `converge` invokes the role with
`tasks_from: remove`; `verify` covers:

- Idle declared user is removed; `/home/<username>` is gone.
- Declared user with no on-disk home directory still removes cleanly
  (`userdel -r` ignores the missing path).
- Declared user with a running process is killed (pre-kill rc=0,
  `changed: true`) then removed; no stray process survives - the
  case the legacy PS flow would have left stuck.
- Undeclared user survives (drift removal is out of scope).
- User declared on a different `vmName` does not leak onto this host
  (selectattr filter applies to the remove direction too).
- Re-converge against an already-removed user reports no error and
  no resurrection.
- An empty `users` list runs zero iterations and touches no
  accounts.
- Stubbed `pkill` exiting rc=2 trips the `failed_when` guard and
  fails the play with a useful error, covering the rc>=2 branch.

## Rationale

See [problem.md - Role: users](../../docs/dev/implementation/02-groups-users-sudoers-creation/problem.md#role-users)
for the password-hash, salt, and `move_home` decisions captured
during design.
