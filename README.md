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

The PowerShell stage ensures WSL2 is installed (delegating to
`Assert-Wsl2Ready` from `PowerShell.Common`) and then invokes
[`ops/bootstrap-controller.sh`](ops/bootstrap-controller.sh)
inside WSL to create the Python venv, install Ansible from
`requirements.txt`, and pull the Galaxy collections pinned in
`requirements.yml`. Both stages are idempotent.

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
