# Role: runner_binary

Reconciles the actions/runner tarball cache and per-runner extracted
directory on the target VM. First role applied by
[`playbooks/register-runners.yml`](../../playbooks/register-runners.yml)
(once that playbook lands in step 6); runs before `runner_registration`
so `config.sh` exists on disk when the registration step looks for it.

## Index

- [Var contract](#var-contract)
- [Register direction](#register-direction)
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
  [`ops/_start-host-file-server.ps1`](../../ops/_start-host-file-server.ps1).
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

Both phases run with `become: true`. Ownership is the runner service
user end-to-end so the registration and service roles can act on the
runner directory tree as that user without per-task fix-ups.

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
- The role never deletes anything. Replacing or rotating an existing
  runner extract is the deregister flow's job (feature 09's `remove`
  direction on this role).

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
