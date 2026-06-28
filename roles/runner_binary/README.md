# Role: runner_binary

Reconciles the actions/runner tarball cache and per-runner extracted
directory on the target VM. First role applied by
[`playbooks/register-runners.yml`](../../playbooks/register-runners.yml)
(once that playbook lands in step 6); runs before `runner_registration`
so `config.sh` exists on disk when the registration step looks for it.

## Index

- [Var contract](#var-contract)
- [Register direction](#register-direction)
- [Remove direction](#remove-direction)
- [Idempotence guarantees](#idempotence-guarantees)
- [Tests](#tests)
- [Rationale](#rationale)

## Var contract

The role reads three extra-vars supplied by the bash bridge
([`ops/_build-extra-vars.sh`](../../ops/_build-extra-vars.sh) +
`_build-extra-vars-runners.sh`):

- `github_runners_config` - the verbatim `GitHubRunnersConfig-<Suffix>`
  JSON array. The host slice is derived by the
  [`runner_entry_resolve`](../runner_entry_resolve/README.md) meta
  dependency into the shared `vm_runner_entries` fact. Per-entry
  shape consumed by this role:

  ```yaml
  vmName: ubuntu-01-ci             # selector (matched on host)
  runnerName: ubuntu-01-ci-a       # used for /opt/runners/<name>/
  runnerUsername: u-actions-runner # service user that owns runner files
  ```

  Other entry fields (`deployUsername`, `githubUrl`, `runnerLabels`,
  `ipAddress`) are consumed by `runner_registration` /
  `runner_service`, not by this role.
- `host_file_server_base_url` - base URL of the Windows-side HTTP
  listener bound to the Hyper-V switch IP by
  [`ops/virtual-machines/_start-host-file-server.ps1`](../../ops/virtual-machines/_start-host-file-server.ps1).
  The role pulls the tarball from
  `<base_url>/actions-runner-linux-x64-<version>.tar.gz`.
- `runner_version` - the resolved `actions/runner` version string
  (without the leading `v`). Defaults to `"latest"` so molecule
  scenarios can pin a fixture version; production always receives the
  resolved value from the bridge.

## Register direction

Two task groups, both keyed off `vm_runner_entries`:

1. **Tarball cache.** One `ansible.builtin.get_url` per distinct
   `runnerUsername` on the host (the loop folds duplicates via
   `map(attribute='runnerUsername') | unique`). Destination is
   `/home/<runnerUsername>/cache/actions-runner-linux-x64-<version>.tar.gz`.
   `get_url` runs `become_user: <runnerUsername>` so the downloaded
   file is owned by the runner service user from creation. A preceding
   `file:` task ensures `/home/<user>/cache/` exists at `0755`; a
   preceding `stat:` task feeds the `when: not item.stat.exists` guard
   so re-runs skip the download entirely (without `get_url`'s own
   header-check round-trip).
2. **Per-runner extract.** One `ansible.builtin.unarchive` per entry,
   `src` set to the cache file, `dest` set to
   `/opt/runners/<runnerName>/`, `remote_src: true` so no
   controller-side copy occurs. Idempotence guard: stat
   `/opt/runners/<runnerName>/config.sh` (the marker the
   actions/runner tarball lays at its root); only extract when absent.
   The destination directory itself is pre-created at `0755` so
   `unarchive` does not need to create missing parents.

Before either group, the role makes each `runnerUsername`'s same-named
group its **primary** group (`ansible.builtin.group` then
`ansible.builtin.user` with `group:`). The role stamps
`group: <runnerUsername>` on every file it owns, including the tarball the
cache step fetches unprivileged under `become_user`; a non-root user can
only `chgrp` to a group it belongs to, so the per-user group has to be the
user's own. That invariant is normally implicit (useradd's per-user group),
but a target whose `useradd` defaults new users into a shared group (e.g.
`users`, gid 100) breaks it - the role establishes it explicitly rather than
trusting the target's default. A primary group is not touched by a
user-reconciliation run's `append: false` supplementary group handling,
so it survives a later user reconcile.

Both phases run with `become: true`. Ownership is the runner service
user end-to-end so the registration and service roles can act on the
runner directory tree as that user without per-task fix-ups.

## Remove direction

Entry point: `tasks/remove.yml`, invoked via
[`playbooks/deregister-runners.yml`](../../playbooks/deregister-runners.yml)
(once that playbook lands in step 5) as the last of the three remove
roles - the previous two (`runner_service`, `runner_registration`)
need `/opt/runners/<name>/` to still exist so `svc.sh` and
`config.sh` can run from inside it.

Inputs: `vm_runner_entries` (same fact the register direction reads,
populated by the `runner_entry_resolve` meta dep). No GitHub
credentials, no file-server URL - the remove direction is
filesystem-local.

Behaviour: one `ansible.builtin.file` task with `state: absent`,
looping over `vm_runner_entries` and deleting
`/opt/runners/<runnerName>/`. Absent directory is a stock-module
no-op, so the "directory already gone" / "re-run after teardown"
paths report `changed: 0` without a separate stat probe.

What is **not** removed:

- The tarball cache under `/home/<runnerUsername>/cache/`. Shared
  across runners on the same VM and reused by the next register run;
  re-downloading the actions-runner archive on every teardown /
  setup cycle would defeat the cache.
- The `runnerUsername` home directory and the runner service user
  account itself. Owned by the user-provisioning flow (the user owner
  repo, Infrastructure-Vm-Users), not this role.
- Anything outside the per-host slice. An entry whose `vmName` does
  not match `inventory_hostname` is dropped by `runner_entry_resolve`
  before the loop sees it, so a stray `/opt/runners/<name>/` on disk
  that the vault does not declare for this host is left alone.

## Idempotence guarantees

- Re-running with the same `vm_runner_entries`, `runner_version`, and
  `host_file_server_base_url` reports `changed: 0` across every task
  group.
- An entry whose `runnerUsername` is shared with another entry on the
  same host triggers exactly one cache download (the `| unique` filter
  collapses the loop) and one extract per `runnerName`.
- A fresh `runner_version` triggers a fresh cache download (versioned
  filename) but leaves the previously extracted directories alone -
  the marker stat looks at `config.sh`, not at the tarball name.
- Re-running the remove direction against a host where the directories
  are already absent is a stock no-op (the `file: state=absent` task
  reports `changed: 0` per entry). Replacing or rotating an existing
  runner extract is the deregister flow's job
  ([`tasks/remove.yml`](tasks/remove.yml)).

## Tests

[`Tests/molecule/runner_binary/default/`](../../Tests/molecule/runner_binary/default/)
exercises the register direction (`tasks/main.yml`):

- Empty `vm_runner_entries` - no tasks loop, no errors, no downloads.
- One entry, tarball absent - one download, one extract; cache file
  present and owned by the runner service user;
  `/opt/runners/<name>/config.sh` present and owned by the same user.
- Two entries on the same VM with the same `runnerUsername` - one
  cache download (proves the `unique` collapse), two extracts.
- Two entries on the same VM with different `runnerUsername` - two
  cache downloads (one per user, in each user's `$HOME/cache/`), two
  extracts.
- Re-converge against the same fixture - `changed: 0` across the role.
- `host_file_server_base_url` pointed at an unreachable host fails the
  `get_url` task per affected runner user with a clear error rather
  than silently skipping (a buggy condition would mask the listener
  having died).

[`Tests/molecule/runner_binary/remove/`](../../Tests/molecule/runner_binary/remove/)
exercises the remove direction (`tasks/remove.yml`). Prepare runs
the register direction against a fixture tarball so a real
`/opt/runners/<name>/` exists going into converge; the converge
includes the role with `tasks_from: remove`; verify asserts:

- Two entries on the same VM, both directories present pre-converge
  -> both removed; `/opt/runners/<name>/` absent for each.
- The tarball cache files under `/home/<runnerUsername>/cache/`
  survive the remove direction (the "do not touch the cache"
  contract).
- One entry whose `/opt/runners/<name>/` was never present pre-
  converge (no register step for it) -> the file-absent task is a
  no-op and the converge completes without error.
- Re-converge reports `changed: 0` across the role.
- A selector-negative entry (`vmName: other-host`) never reaches
  this host's loop; the `runner_entry_resolve` meta dep filters it
  out before the remove direction sees it.

A companion scenario,
[`Tests/molecule/runner_entry_resolve/default/`](../../Tests/molecule/runner_entry_resolve/default/),
asserts the host-slice fact shape for 0 / 1 / 2 declared entries so
the meta dep's contract has direct coverage too.

## Rationale

Splitting the cache and extract phases per `runnerUsername` /
`runnerName` mirrors the PowerShell flow today
(`Invoke-RunnerTarballDeploy` + `Invoke-RunnerExtract` keyed off
`Group-Object { $_.Entry.runnerUsername }`); the contract that
matters is "one tarball per service user, one extract per runner".
The host-file-server URL is the measured NAT-bypass from the
existing flow - see
[problem.md - Solution approach](../../docs/dev/implementation/08-github-runners-registration/problem.md#solution-approach)
for the bandwidth rationale.
