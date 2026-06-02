# Infrastructure-VM-Ansible

Ansible controller repo for reconciling OS groups, users, and sudoers on
provisioned VMs. Invoked from Windows via a PowerShell -> WSL bridge that
reads configuration from PowerShell SecretManagement vaults and dispatches
to `ansible-playbook` inside a Linux venv.

This stub is filled out properly in
[step 10](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md#step-10---readme-and-per-step-docs)
of the current feature. Design history and rationale live under
[docs/dev/implementation/](docs/dev/implementation/).

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
`Assert-Wsl2Ready` from `PowerShell.Common`), and then invokes
[`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
inside WSL to create the Python venv, install Ansible from
`requirements.txt`, and pull the Galaxy collections pinned in
`requirements.yml`. Both stages are idempotent.

When `python3` (plus `python3-venv`) or `jq` is absent the bash
stage installs the missing package via `sudo apt-get`; the existing
`sudo apt-get install -y <pkg>` hint stays as the fallback path for
when the install itself cannot proceed (no `sudo`, `apt-get` missing,
offline, apt lock).

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

## Index

- [Current feature: 02 - groups, users, sudoers creation](docs/dev/implementation/02-groups-users-sudoers-creation/)
  - [Problem](docs/dev/implementation/02-groups-users-sudoers-creation/problem.md)
  - [Plan](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md)
