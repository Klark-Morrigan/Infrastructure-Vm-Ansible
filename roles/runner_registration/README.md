# Role: runner_registration

Reconciles a self-hosted GitHub Actions runner's registration state
against the GitHub repo and the on-disk `.runner` marker. Drives two
directions:

- **Register.** Second role applied by
  [`playbooks/register-runners.yml`](../../playbooks/register-runners.yml);
  runs after [`runner_binary`](../runner_binary/README.md) (which lays
  `config.sh` on disk) and before
  [`runner_service`](../runner_service/README.md) (which needs the
  runner to be registered before `svc.sh install` can succeed).
- **Remove.** Second role applied by
  [`playbooks/deregister-runners.yml`](../../playbooks/deregister-runners.yml)
  via `tasks_from: remove`; runs after
  [`runner_service`](../runner_service/README.md) (which quiesces the
  unit) and before [`runner_binary`](../runner_binary/README.md)
  (which deletes the on-disk extract).

## Index

- [Var contract](#var-contract)
- [Register direction](#register-direction)
- [Remove direction](#remove-direction)
- [Token hygiene](#token-hygiene)
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
  runnerName: ubuntu-01-ci-a       # unique on GitHub, also the dir name
  runnerUsername: u-actions-runner # service user that owns runner files
  githubUrl: https://github.com/owner/repo-a
  runnerLabels: [self-hosted, ubuntu, x64]
  ```

  `deployUsername` / `ipAddress` are consumed by other roles or the
  bridge, not by this role.
- `github_token` - the GitHub Personal Access Token the bridge wrote
  into the chmod-600 extra-vars file from the operator's `GH_TOKEN`
  environment variable. Required scope: `repo` (private repos) or
  `public_repo` (public repos only). The role asserts the value is
  non-empty before any GitHub round-trip.
- `github_api_base_url` (default `https://api.github.com`) - the
  REST API base URL. Override for GHE Server or, in molecule
  scenarios, for a controller-local mock that records requests so the
  reconcile branches can be asserted without round-tripping to real
  GitHub.

## Register direction

For every entry in `vm_runner_entries`, the role evaluates two probes
and picks one of three branches:

| Branch                                | On-disk `.runner` | GitHub registration | Action                                                              |
|---------------------------------------|-------------------|---------------------|---------------------------------------------------------------------|
| **healthy**                           | present           | present             | skip - no token mint, no `config.sh`                                |
| **register**                          | absent            | absent or present   | mint registration token, run `config.sh --unattended`               |
| **re-register** (lost local state)    | present           | absent              | mint removal + registration tokens, run `config.sh remove` then `--unattended` |

Probes (one round-trip each per entry, both controller-side):

1. **Existence probe.** `ansible.builtin.uri` GET against
   `<github_api_base_url>/repos/<owner>/<repo>/actions/runners?per_page=100`,
   filtered by `runnerName` from the response. `delegate_to: localhost`
   so the call originates on the controller (which has internet egress)
   instead of on the managed VM (which often does not).
2. **On-disk probe.** `ansible.builtin.stat` on
   `/opt/runners/<runnerName>/.runner` - the marker file
   `config.sh --unattended` writes after a successful registration.

`owner` / `repo` are parsed from each entry's `githubUrl` (the path is
split on `/`; a trailing `.git` is stripped if present), so a single
PAT can register runners across multiple repos in one play.

Reconcile decisions are computed as two booleans
(`runner_should_register`, `runner_should_remove_first`) in one
`set_fact` so the guarded tasks below read as a flat list rather than
a nested `when` tree. Implementation lives in
[`tasks/reconcile-entry.yml`](tasks/reconcile-entry.yml), included
once per entry from
[`tasks/main.yml`](tasks/main.yml) so each runner's facts stay scoped
to its own iteration. The existence probe itself lives in
[`tasks/_probe-github.yml`](tasks/_probe-github.yml) so the remove
direction shares the same owner/repo parse, the same URI shape, and
the same `runner_registration_on_github` fact name.

## Remove direction

Selected by [`playbooks/deregister-runners.yml`](../../playbooks/deregister-runners.yml)
via `import_role { name: runner_registration, tasks_from: remove }`.
Runs second in the remove order: after
[`runner_service`](../runner_service/README.md) (which quiesces the
unit so `.credentials` is no longer held open) and before
[`runner_binary`](../runner_binary/README.md) (which deletes
`/opt/runners/<name>/` — `config.sh remove` reads `.credentials` from
that directory, so the dir has to still exist while this role runs).

For every entry in `vm_runner_entries`, the role evaluates the same
existence probe the register direction uses and picks one of two
branches:

| Branch                       | GitHub registration | Action                                                                            |
|------------------------------|---------------------|-----------------------------------------------------------------------------------|
| **skip**                     | absent              | no-op — no token mint, no `config.sh`                                             |
| **remove**                   | present             | mint removal token, run `config.sh remove --token <removal> --unattended` as user |

Per-entry implementation lives in
[`tasks/_remove-one.yml`](tasks/_remove-one.yml), included once per
entry from [`tasks/remove.yml`](tasks/remove.yml) so each runner's
probe and token facts stay scoped to that iteration. Three small
shared files keep both directions on the same wire surface:

- [`tasks/_assert-token.yml`](tasks/_assert-token.yml) — the
  empty-`github_token` fast-fail gate. `main.yml` and `remove.yml`
  both `include_tasks` it; the same fail_msg points operators at
  either `ops/register-runners.sh` or `ops/deregister-runners.sh`.
- [`tasks/_probe-github.yml`](tasks/_probe-github.yml) — the GitHub
  existence probe + `runner_registration_on_github` fact. The
  register direction's re-register branch and the remove direction
  pivot on the same boolean so a fact-name drift across directions
  is impossible.
- [`tasks/_mint-remove-token.yml`](tasks/_mint-remove-token.yml) —
  the removal-token mint. The register direction's re-register
  branch and the remove direction share the URI body and the
  `runner_registration_remove_token_resp` fact name; only the
  guarding `when:` differs.

The on-disk marker files (`.runner`, `.credentials`) are not touched
by this role on the remove path — they live inside
`/opt/runners/<name>/` and disappear when `runner_binary`'s remove
direction deletes the directory. A "GitHub-absent but disk-present"
branch is therefore unnecessary here: the on-disk teardown happens
unconditionally one role later.

## Token hygiene

Every task that touches a token (the GitHub PAT, the minted
registration token, or the minted removal token) sets `no_log: true`.
At default verbosity Ansible never prints token values; at `-vvv` it
prints `VALUE_SPECIFIED_IN_NO_LOG_PARAMETER` placeholders for the
affected arguments rather than the raw bytes. The PAT itself rides in
the `Authorization` header (never in the URL query string) so it does
not survive in any proxy or access log between the controller and
api.github.com.

Tokens are minted run-time only. Nothing in this role writes a token
to disk; the per-entry `register: ...` facts holding the response
bodies fall out of scope at the end of each `include_tasks`
iteration. The PAT itself lives only in the chmod-600 tmpfs
extra-vars file the bash bridge writes (cleaned by the bridge's
`trap EXIT`).

All three `config.sh` invocations (register's `--unattended`,
register's re-register-branch `remove`, remove direction's
`remove --unattended`) use the `argv` form of
`ansible.builtin.command`, not the shell-string form, so the token
never lands in a `bash` history file via shell-word expansion.

## Idempotence guarantees

- **Register direction.** Re-running with the same `vm_runner_entries`
  and a healthy fleet (every entry registered on GitHub and on disk)
  reports `changed: 0` across the role — both `config.sh` tasks are
  guarded off by the reconcile facts, the only API call is the
  read-only existence probe (which Ansible scores as `ok`, not
  `changed`).
- **Register direction.** Adding a new entry to `vm_runner_entries`
  between runs reconciles only the new entry; existing healthy
  entries skip both `config.sh` tasks unchanged.
- **Register direction.** The register direction never decides to
  deregister a runner from GitHub. The re-register branch's
  `config.sh remove` clears the on-disk registration only; if the
  matching GitHub record had been present the role would have taken
  the healthy branch instead. Removal of active GitHub records is
  the remove direction's job.
- **Remove direction.** Re-running after a successful remove reports
  `changed: 0` — the existence probe finds every entry absent on
  GitHub, both guarded tasks (remove-token mint, `config.sh remove`)
  skip on the `runner_registration_on_github` boolean.
- **Remove direction.** An entry whose GitHub record was already
  removed out-of-band (manual UI delete, separate teardown) is a
  silent no-op: the probe sees it absent, the skip branch fires.
  No "GitHub-absent / disk-present" branch is needed because
  `runner_binary`'s remove direction deletes the dir unconditionally
  one role later.

## Tests

[`Tests/molecule/runner_registration/default/`](../../Tests/molecule/runner_registration/default/)
exercises the three reconcile branches against a mock GitHub API
running on the molecule controller (the role's `delegate_to: localhost`
keeps the API calls on the controller, so the mock can be loopback-
bound there):

- **healthy** - `.runner` present + mock returns the runner in the
  GET response - skip; the mock records exactly one `GET /runners`
  for this runner and no token-mint POSTs.
- **register** (fresh) - `.runner` absent + mock returns an empty
  runner list - mint registration token, run `config.sh --unattended`;
  the mock records one `GET /runners` and one
  `POST /registration-token`; the stub `config.sh` log captures the
  expected argv (`--url`, `--token`, `--name`, `--labels`).
- **re-register** - `.runner` present + mock returns an empty runner
  list - mint both tokens, run `config.sh remove` then `--unattended`;
  the mock records both POSTs and the stub `config.sh` log captures
  both invocations in order.
- **Empty `github_token`** - the role's input assert fails fast
  before any HTTP round-trip; the mock records zero requests.
- **Selector** - an entry on a different `vmName` does not leak
  onto the host under test (covered transitively by the
  [`runner_entry_resolve`](../runner_entry_resolve/README.md)
  scenario).

The mock server records every request to a JSON-lines log file the
verify play parses with `slurp` + `from_yaml` so the per-branch
assertions read as set equalities on the captured request list rather
than fragile substring matches. Both scenarios share two task files
under
[`Tests/molecule/runner_registration/tasks/`](../../Tests/molecule/runner_registration/tasks/):
`_kill-mock-pidfile.yml` (the pidfile-kill-with-retry block used by
prepare + cleanup of each scenario) and `_launch-mock.yml` (the
`nohup` mock-server launch plus `wait_for`).

[`Tests/molecule/runner_registration/remove/`](../../Tests/molecule/runner_registration/remove/)
exercises the remove direction against the same mock GitHub API
(shared script: `../default/mock-github-api.py`, run on a dedicated
loopback port so the two scenarios do not collide). Three entries
cover the per-entry branches:

- **remove** - entry in the mock's registered set - mint removal
  token, run `config.sh remove --token <FAKE_REMOVAL_TOKEN>
  --unattended`; the mock records one `GET /runners` per pass plus
  one `POST /remove-token` on the converge run; the stub `config.sh`
  log captures the expected argv.
- **skip** - entry absent from the mock's registered set - no token
  mint, no `config.sh` call; the mock records the GET only.
- **Selector** - an entry on a different `vmName` is dropped by
  `runner_entry_resolve`; the mock never sees its repo path.
- **Empty `github_token`** - the role's input assert fails fast
  before any HTTP round-trip; the mock records zero requests
  during the rescued include.

A `side_effect.yml` clears the mock's registered set between the
converge and idempotence passes (real GitHub drops the registration
after a successful `config.sh remove`; the static mock does not, so
the side_effect mirrors that for the idempotence assertion). On the
idempotence pass every entry takes the skip branch and the role
reports `changed: 0`.

## Rationale

Three roles instead of one keeps each external surface in its own
file: this role owns the GitHub API surface end-to-end, `runner_binary`
owns the file-server / unarchive surface, `runner_service` owns the
systemd surface. A molecule scenario for any one of them can stub
the others' surfaces without dragging the full register flow into
fixture territory.

The reconcile-via-two-booleans shape (rather than a four-way
`when:` ladder) is what the existing PowerShell
`Invoke-VmRunnerGroup` resolves to once its branching is unrolled;
keeping the same shape here means an operator who debugged the
PowerShell flow recognises the Ansible flow at a glance.

The mock-on-controller test posture is the natural consequence of
`delegate_to: localhost`: a mock inside the container would require
either changing the delegate (a test-only knob the role has no
business carrying) or accepting that the test cannot exercise the
real production code path. The controller in this repo runs in WSL,
and WSL loopback works for both the mock server and the role's URI
tasks - the same address space, no port-forwarding.
