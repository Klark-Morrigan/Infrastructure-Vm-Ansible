# Infrastructure-VM-Ansible

Ansible controller repo for reconciling OS groups, users, and sudoers on
provisioned VMs. Invoked from Windows via a PowerShell -> WSL bridge that
reads configuration from PowerShell SecretManagement vaults and dispatches
to `ansible-playbook` inside a Linux venv.

Design history and rationale live under
[docs/dev/implementation/](docs/dev/implementation/); each section below
was extended by the feature step that earned it.

## Index

- [Controller bootstrap](#controller-bootstrap)
  - [Troubleshooting: WSL default distro has no bash](#troubleshooting-wsl-default-distro-has-no-bash)
- [Vault setup](#vault-setup)
- [Create users](#create-users)
- [Bridge contract](#bridge-contract)
- [Tests and lint](#tests-and-lint)
- [Roles](#roles)
- [Feature folders](#feature-folders)

## Controller bootstrap

A fresh Windows host reaches the runnable state in one command:

```
pwsh ./ops/bootstrap-controller.ps1
```

or double-click
[`ops/bootstrap-controller.bat`](ops/bootstrap-controller.bat)
from Explorer (thin launcher: invokes `pwsh` against the `.ps1` and
holds the window open).

The PowerShell stage installs `PowerShell.Common` and
`Infrastructure.Secrets` from PSGallery (idempotent — `Invoke-ModuleInstall`
no-ops when current), ensures WSL2 is installed (delegating to
`Assert-Wsl2Ready` from `PowerShell.Common`), verifies the default WSL
distro actually has `bash` (delegating to `Assert-WslHasBash`), and
then invokes
[`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
inside WSL to create the Python venv, install Ansible from
`requirements.txt`, and pull the Galaxy collections pinned in
`requirements.yml`. Both stages are idempotent.

When `python3` (plus `python3-venv`) or `jq` is absent the bash
stage installs the missing package via `sudo apt-get`; the existing
`sudo apt-get install -y <pkg>` hint stays as the fallback path for
when the install itself cannot proceed (no `sudo`, `apt-get` missing,
offline, apt lock).

The `sudo` call **prompts for the WSL user's password once per fresh
bootstrap** (the very first user you set when WSL provisioned the
distro). Three ways to deal with it depending on how often a fresh
bootstrap will happen:

- **Type the password** at the prompt. Once per workstation in
  practice (the install is idempotent; re-bootstrapping a healthy
  workstation skips the `sudo apt-get` branch entirely).
- **Pre-install the three packages once**, then bootstrap is
  fully unattended:

  ```
  wsl -d Ubuntu-24.04 -- sudo apt-get update
  wsl -d Ubuntu-24.04 -- sudo apt-get install -y python3 python3-venv jq
  ```

- **Add a scoped passwordless-sudo rule** inside the distro
  (`sudo visudo -f /etc/sudoers.d/passwordless-apt`,
  contents `<your-user> ALL=(ALL) NOPASSWD: /usr/bin/apt-get`).
  Bootstrap then runs unattended forever, at the cost of standing
  apt-get sudo for that user.

Once bootstrap finishes you should see `Ansible <version>` in its
summary block and a populated `.venv/` in the repo root. Until both
are true the bridge fails with `_run-playbook.sh: .venv missing -
run ops/bootstrap-controller.{ps1,sh} first` (this is the bridge
refusing to run before bootstrap, not a separate bug).

### Troubleshooting: WSL default distro has no bash

If bootstrap fails with a yellow `bash was not found on PATH inside
the default WSL distro ...` message, the workstation's default WSL
distro does not ship bash. The usual root cause is **Docker Desktop**:
its installer ships a minimal `docker-desktop` engine distro (busybox
userland, no bash) and silently makes it the WSL default, so a bare
`wsl --` call lands there and every `#!/usr/bin/env bash` script in
the bridge fails with `env: can't execute 'bash': No such file or
directory`.

Diagnose:

```
wsl --list --verbose
```

If the `*` (default) is on `docker-desktop`, that is the trap.
Remediate by installing a real distro and pinning it as default:

```
wsl --install -d Ubuntu-24.04
wsl --set-default Ubuntu-24.04
```

Re-run `ops/bootstrap-controller.ps1`; the second WSL gate now
passes and the bash bridge runs against the new default.

E2E callers (`Infrastructure-E2E/agent/Start-E2EAgent.ps1`) avoid the
trap entirely by passing `-WslDistro <name>` and storing the same
value in the `E2EConfig` vault, so they target the bash-having distro
explicitly via `wsl -d <name> --` regardless of what the workstation's
default happens to be at the time.

## Vault setup

Operators write the `VmUsersConfig` payload to the local SecretStore
vault `VmUsers` (secret name `VmUsersConfig`) by running:

```
pwsh ./ops/setup-secrets.ps1 -ConfigFile C:\private\vm-users-config.json
```

or by dropping the JSON file onto
[`ops/setup-secrets.bat`](ops/setup-secrets.bat) (Explorer launcher;
forwards the dropped path as `-ConfigFile`).

[`ops/setup-secrets.ps1`](ops/setup-secrets.ps1) is a **thin wrapper**
that delegates to
[`Infrastructure-Vm-Users/hyper-v/ubuntu/setup-secrets.ps1`](../Infrastructure-Vm-Users/hyper-v/ubuntu/setup-secrets.ps1).
The Vm-Users script owns the schema validator, the
SecretStore/SecretManagement install, the vault registration, and
the `Set-Secret` write. Both repos target the same `VmUsers` vault
and `VmUsersConfig` secret name - which is exactly what this repo's
bash bridge in [`ops/_read-vault-config.sh`](ops/_read-vault-config.sh)
reads from. Forking the writer before the vault contract actually
diverges would just create a second place to keep in lock-step;
the wrapper buys discoverability (the entry sits next to the rest
of `ops/`) without that cost.

The wrapper expects `Infrastructure-Vm-Users` as a sibling checkout
under the same parent directory as this repo - same convention used
by [`scripts/Run-Tests.ps1`](scripts/Run-Tests.ps1) for
`PowerShell-Common`. A follow-up feature replaces the wrapper with a
first-class implementation when the vault contract diverges (or
Vm-Users is archived).

## Create users

Once the controller is bootstrapped and the vault entry is in place,
the create-users flow reconciles every host in the `VmProvisionerConfig`
inventory with one command:

```
wsl ./ops/create-users.sh
```

or double-click [`ops/create-users.bat`](ops/create-users.bat) from
Explorer (Git Bash launcher; mirrors the
[`scripts/run-tests.bat`](scripts/run-tests.bat) sibling-find pattern
and reuses [`GitHub-Common/scripts/_find-bash.bat`](../GitHub-Common/scripts/_find-bash.bat)).

[`ops/create-users.sh`](ops/create-users.sh) is a one-line wrapper
that dispatches [`playbooks/create-users.yml`](playbooks/create-users.yml)
through the [bridge](#bridge-contract); every flag after the entry
point is forwarded to `ansible-playbook` verbatim, so the usual
operator knobs work unchanged:

```
wsl ./ops/create-users.sh --check               # dry-run
wsl ./ops/create-users.sh --tags users          # scope to one role
wsl ./ops/create-users.sh --limit vm-1,vm-2     # scope to specific VMs
wsl ./ops/create-users.sh -v                    # verbose play recap
```

The playbook composes the three roles in `groups -> users -> sudoers`
order against the `vm_provisioner_hosts` inventory group; each role
is tagged with its own name. `any_errors_fatal: false` keeps a
transiently offline VM from stranding the rest of the fleet.

## Bridge contract

The bash bridge between operator scripts under `ops/` and
`ansible-playbook` is split across four single-purpose helpers
under `ops/` with a leading `_` (the "called by operator entries,
not typed by a human" convention). Each is unit-testable against
just its own external boundary:

- [`ops/_read-vault-config.sh`](ops/_read-vault-config.sh) - vault
  reader. Shells out to `pwsh.exe` to fetch a named secret via the
  `Infrastructure.Secrets` wrapper (`Get-InfrastructureSecret`, never
  bare `Get-Secret` — single provider-swap point per problem.md),
  strips CRLF + UTF-8 BOM, validates JSON, prints the payload on
  stdout. Only helper that talks to the Windows side.
- [`ops/_build-inventory.sh`](ops/_build-inventory.sh) - pure
  transform. Reads `vm_provisioner_config` on stdin and writes
  Ansible JSON inventory (group `vm_provisioner_hosts`, host key
  `vmName`) on stdout.
- [`ops/_build-extra-vars.sh`](ops/_build-extra-vars.sh) - pure
  transform. Takes `--provisioner-config <file>` and
  `--users-config <file>` and emits the canonical extra-vars JSON
  with the two top-level keys (`vm_provisioner_config`,
  `vm_users_config`) on stdout. File paths (not values) so secrets
  stay out of argv.
- [`ops/_run-playbook.sh`](ops/_run-playbook.sh) - thin
  orchestrator. Validates args, sets up a per-invocation
  `mktemp -d` tree (`chmod 700`, files `chmod 600`, cleaned up by
  `EXIT` trap), activates `.venv`, drives the three helpers in
  order, and dispatches `ansible-playbook` against the requested
  playbook path. Any args after the playbook path are forwarded
  verbatim to `ansible-playbook` (so `--tags`, `--limit`,
  `--check`, `-v`, etc. all work without changes to the bridge).

External contract (consumed by later feature playbooks): the
extra-vars document has exactly two top-level keys
(`vm_provisioner_config`, `vm_users_config`); the inventory has one
group `vm_provisioner_hosts` keyed by `vmName`.

`jq` is a hard runtime dependency (JSON validation, inventory and
extra-vars composition); [`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
installs it via `sudo apt-get` when absent and falls back to the
`sudo apt-get install -y jq` hint if the install itself cannot
proceed.

Each helper has its own bats suite under
[`Tests/ops/`](Tests/ops/) covering its boundary in isolation;
`_run-playbook.bats` stubs all four boundaries (`pwsh.exe`,
`ansible-playbook`, plus the three sibling helpers) and asserts
orchestration only. The end-to-end smoke against a real VM is
captured in step 12 of the feature plan.

## Tests and lint

CI is wired to two reusable workflows; nothing is copied per-repo:

- [`.github/workflows/ci-powershell.yml`](.github/workflows/ci-powershell.yml)
  -> `PowerShell-Common/.github/workflows/ci-powershell.yml@master`
  (Pester unit tests + `lint-no-bare-return-empty-array`).
- [`.github/workflows/ci-bash.yml`](.github/workflows/ci-bash.yml)
  -> `GitHub-Common/.github/workflows/ci-bash.yml@master` (shellcheck
  on production / runner bash + `*.bats` suites + `+x` bit check).
- [`.github/workflows/ci-yaml.yml`](.github/workflows/ci-yaml.yml)
  -> `GitHub-Common/.github/workflows/ci-yaml.yml@master` (yamllint,
  actionlint, action-validator, ansible-lint).
- [`.github/workflows/e2e.yml`](.github/workflows/e2e.yml)
  -> `Infrastructure-E2E/.github/workflows/e2e.yml@master`. Required PR
  check: the workstation polling agent picks up the deployment created
  by the shared workflow, runs the full runner-lifecycle test against a
  real Hyper-V VM with the agent's default `UsersFlow=ansible`, and
  reports back. An Ansible role / playbook / bridge change cannot merge
  to `master` until the new code has been proven to reconcile users and
  bring an online runner up via this repo's `ops/create-users.sh`.
  Requires the GitHub App from Infrastructure-E2E's setup to be
  installed on this repo and the `GH_APP_ID` / `GH_APP_PRIVATE_KEY`
  Actions secrets to be present.

The same checks run locally via thin shims that delegate to the
canonical runners in the sibling repos (so a fix to the CI logic
lands in one place):

- [`scripts/Run-Tests.ps1`](scripts/Run-Tests.ps1) -> calls
  `PowerShell-Common/.github/actions/run-unit-tests/Run-Tests.ps1`.
- [`scripts/run-tests.sh`](scripts/run-tests.sh) -> calls
  `GitHub-Common/scripts/run-tests.sh` with
  `GHCOMMON_TARGET_REPO` pointed at this repo.
- [`scripts/run-tests.bat`](scripts/run-tests.bat) -> Explorer-click
  launcher; forwards to `GitHub-Common/scripts/run-tests.bat` with
  `GHCOMMON_TARGET_REPO` set.
- [`scripts/fix-permissions.sh`](scripts/fix-permissions.sh) /
  [`scripts/fix-permissions.bat`](scripts/fix-permissions.bat) ->
  forward to `GitHub-Common/scripts/fix-permissions.{sh,bat}` to
  re-stage `+x` on tracked `*.sh` files that lost it (heals what the
  `check-sh-executable` CI gate flags).

Both shims assume `PowerShell-Common` and `GitHub-Common` are sibling
checkouts under the same parent directory.

## Roles

Per-role contracts (var schema, idempotence guarantees, test scope)
live in each role's own README. The top-level entry below grows as
each role lands; the create-users playbook orders them
`groups -> users -> sudoers`.

- [`roles/vm_users_entry`](roles/vm_users_entry/README.md) -
  repo-internal helper. Resolves the per-host `VmUsersConfig` entry
  into the shared `vm_users_entry` fact; pulled in via meta dependency
  by the three roles below so the selectattr+first lookup lives in
  one file instead of three.
- [`roles/groups`](roles/groups/README.md) - reconcile declared OS
  groups from `vm_users_config[*].groups`; first role applied.
- [`roles/users`](roles/users/README.md) - reconcile declared OS
  users from `vm_users_config[*].users`; runs after `groups`.
  Passwords are hashed controller-side with a deterministic
  per-user salt so re-runs are truly idempotent; `homeDir` updates
  never relocate on-disk data (`move_home: false`).
- [`roles/sudoers`](roles/sudoers/README.md) - reconcile per-user
  `/etc/sudoers.d/<username>` drop-ins from
  `vm_users_config[*].users[*].sudoersRules`; runs after `users`.
  Rules are written verbatim and gated by `visudo -cf` on the staged
  temp file before the atomic swap, so a malformed rule fails the
  task without touching the live file. An empty / absent
  `sudoersRules` array removes the drop-in.

## Feature folders

- [Current feature: 02 - groups, users, sudoers creation](docs/dev/implementation/02-groups-users-sudoers-creation/)
  - [Problem](docs/dev/implementation/02-groups-users-sudoers-creation/problem.md)
  - [Plan](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md)
