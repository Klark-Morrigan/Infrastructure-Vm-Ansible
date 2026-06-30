# Common-Ansible

Ansible controller substrate - a PowerShell -> WSL dispatch bridge and
reusable roles - run against provisioned VMs. Invoked from Windows via the
bridge, which reads configuration from PowerShell SecretManagement vaults
and dispatches to `ansible-playbook` inside a Linux venv. Consumer repos
reuse the substrate to own their own domains (see
[Consuming the substrate](#consuming-the-substrate)).

Design history and rationale live under
[docs/dev/implementation/](docs/dev/implementation/); each section below
was extended by the feature step that earned it.

## Index

- [Controller bootstrap](#controller-bootstrap)
  - [Troubleshooting: WSL default distro has no bash](#troubleshooting-wsl-default-distro-has-no-bash)
  - [Troubleshooting: capturing logs and re-running an interrupted bootstrap](#troubleshooting-capturing-logs-and-re-running-an-interrupted-bootstrap)
- [Bridge contract](#bridge-contract)
- [Tests and lint](#tests-and-lint)
- [Consuming the substrate](#consuming-the-substrate)
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

The PowerShell stage installs `Common.PowerShell` and
`Infrastructure.Secrets` from PSGallery (idempotent — `Invoke-ModuleInstall`
no-ops when current), ensures WSL2 is installed (delegating to
`Assert-Wsl2Ready` from `Common.PowerShell`), verifies the default WSL
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

### Troubleshooting: capturing logs and re-running an interrupted bootstrap

When invoking the WSL stage directly (rather than via
`ops/bootstrap-controller.ps1` or the menu) it is tempting to pipe
through `tee` to capture a log:

```powershell
wsl -d Ubuntu-24.04 -- bash -lc './ops/_bootstrap-controller-wsl.sh' 2>&1 | tee bootstrap.log
```

That works **only if no sudo prompt will fire**. The pipeline
detaches stdin from the terminal; sudo cannot find a TTY to read a
password and dies with `sudo: a password is required` (or, worse,
silently no-ops the install branch and the bootstrap reports success
without actually installing anything). Two safe workarounds:

- Pre-install the apt prerequisites once (`wsl -d Ubuntu-24.04 -u root
  -- apt-get install -y python3 python3-venv jq`); subsequent
  bootstrap runs never enter the sudo branch and can be tee'd freely.
- Run bootstrap *without* `tee`, type the password at the prompt, and
  re-run with `tee` afterwards for the log (the second run skips the
  sudo branch because the packages are now present).

Note that `tee bootstrap.log` writes to the calling shell's current
directory, not the repo - so the file lands at the location PowerShell
reports in its prompt (typically `C:\Users\<you>\`), not at
`C:\a_Code\Common-Ansible\`. Look there if the log seems
to have vanished.

If a bootstrap run is interrupted (Ctrl+C, network blip during
`ansible-galaxy collection install`, sudo prompt dismissed), **just
re-run it**. Every stage is idempotent: an existing healthy `.venv`
is reused, pip pins are no-ops when current, `ansible-galaxy
--force-with-deps` re-installs cleanly over a partial extraction.
The only state worth manually clearing is a half-built `.venv` that
has `bin/python` but no `bin/pip` (left behind by the pre-fix
`python3 -m venv` bug); in that case
`rm -rf /mnt/c/a_Code/Common-Ansible/.venv` then re-run
bootstrap to recreate it cleanly.

## Bridge contract

The bash bridge between operator scripts under `ops/` and
`ansible-playbook` is split across single-purpose helpers under
`ops/` with a leading `_` (the "called by operator entries, not
typed by a human" convention). Each is unit-testable against just
its own external boundary.

The helpers that know the VM fleet's shape - inventory building, the
Hyper-V/ICS/portproxy router resolution, and the host file server -
live together under [`ops/virtual-machines/`](ops/virtual-machines/).
Grouping them keeps the estate-specific coupling (the
`vm_provisioner_config` schema, the `<Name>Config-<suffix>` secret
convention, and the Hyper-V router topology) in one named place rather
than scattered through the otherwise consumer-agnostic bridge - a
visible, contained seam for any later move toward a fully fleet-agnostic
substrate. The generic helpers (contract parse, vault read, extra-vars
compose, the orchestrator itself) stay at the `ops/` root:

- [`ops/_parse-consumer-contract.sh`](ops/_parse-consumer-contract.sh)
  - consumer contract parser. A wrapper declares what the run needs
  through `CA_*` environment variables rather than the bridge
  hardcoding any vault name or toggle; this helper normalises that
  declaration into a stable parsed form. Inputs: `CA_INVENTORY_VAULT`
  (required - the vault holding the fleet inventory, named by the
  consumer so the substrate hardcodes no vault, not even the
  inventory's; the wrappers pass `VmProvisioner`); and the optional,
  default-"none" `CA_EXTRA_VAULTS` (vault names beyond the inventory
  vault, whitespace- or comma-separated), `CA_NEEDS_HOST_FILE_SERVER`
  (`1` opts in), `CA_REQUIRES_TOKEN` (`1` declares a GitHub token is
  needed, supplied out-of-band via `GH_TOKEN`), and `CA_CONSUMER_ROOT`
  (optional path to a consumer repo that owns the playbook, roles, and
  per-domain extra-vars fragment this run dispatches; empty -> the
  bridge resolves those from its own substrate root). It emits five
  `KEY=value` lines on stdout (`INVENTORY_VAULT=`, `EXTRA_VAULTS=`,
  `NEEDS_HOST_FILE_SERVER=`, `REQUIRES_TOKEN=`, `CONSUMER_ROOT=`) and
  rejects an invalid contract - a missing required inventory vault, or a
  required token with none supplied - with a non-zero exit before any
  vault read. Keeping this parse in a single-purpose sibling is the seam
  that lets the substrate serve unknown future consumers without
  importing their identities.
- [`ops/_read-vault-config.sh`](ops/_read-vault-config.sh) - vault
  reader. Shells out to `pwsh.exe` to fetch a named secret via the
  `Infrastructure.Secrets` wrapper (`Get-InfrastructureSecret`, never
  bare `Get-Secret` — single provider-swap point per problem.md),
  strips CRLF + UTF-8 BOM, validates JSON, prints the payload on
  stdout. Only helper that talks to the Windows side.
- [`ops/virtual-machines/_build-inventory.sh`](ops/virtual-machines/_build-inventory.sh)
  - pure transform. Reads `vm_provisioner_config` on stdin and writes
  Ansible JSON inventory (group `vm_provisioner_hosts`, host key
  `vmName`) on stdout. Lives in the `ops/virtual-machines/` module with
  the rest of the VM-fleet code (see the note at the top of this
  section).
- [`ops/_build-extra-vars.sh`](ops/_build-extra-vars.sh) - extra-
  vars composer. Owns no payload domain itself, but owns the one
  piece of domain knowledge the orchestrator must not: which vault
  feeds which per-domain fragment helper. The bridge hands it the
  always-on provisioner config plus every contract-declared vault as a
  generic `--vault-config <Name>=<path>` pair, and the composer routes
  each Name to its helper, then merges the fragments via `jq -s add`.
  Inputs:
  - `--provisioner-config <file>` (required) — the inventory the bridge
    read from the contract-declared vault. A flag name, not a vault
    name: the composer never learns which vault it came from.
  - `--vault-config <Name>=<path>` (repeatable) — one per extra vault.
    `GitHubRunners` routes to the runners helper. An unrecognised Name
    is a contract typo or a
    domain with no helper yet and is rejected, never silently dropped.
  - `--github-token <value>` — routed to the runners helper. The
    token pairs with the `GitHubRunners` vault: either alone is
    rejected (a token with no consumer, or a runners vault that cannot
    register without one).
  - `--host-base-url <url>` + `--runner-version <ver>` — the host file
    server URL the listener bound to, plus the consumer-supplied artifact
    version, that the register flow adds on top. The pair arrives together
    or not at all, and has no meaning without the `GitHubRunners` vault;
    partial or orphaned sets are rejected before any helper runs.
  - `--consumer-root <path>` (optional) — when a consumer owns the
    per-domain fragment, resolve `_build-extra-vars-<domain>.sh` from
    `<path>/ops` instead of this composer's own directory. The inventory
    fragment is always substrate and is unaffected. Empty keeps every
    fragment on the composer's own `ops/` (the substrate's own flows).
  The always-on inventory helper owns its own validation and bats
  coverage:
  - [`ops/virtual-machines/_build-extra-vars-inventory.sh`](ops/virtual-machines/_build-extra-vars-inventory.sh)
    — emits `vm_provisioner_config`. Always-on; the inventory source
    every payload domain shares.
  Every other payload fragment is consumer-owned: the dispatch arm
  resolves `_build-extra-vars-<domain>.sh` from `<consumer-root>/ops`,
  so the substrate ships none of them (the `GitHubRunners` arm resolves
  the runners fragment from the runner owner's repo).
  Config inputs are file paths (not values) so secrets stay out of
  argv. The GitHub token is the lone exception, passed by value
  because the entry script already holds it in a shell variable;
  argv on Linux is private to the owning user's process tree.
  Concentrating the vault-name -> helper map here (the layer that
  already dispatches per domain) is what lets the orchestrator stay
  ignorant of any specific consumer. Future payload domains (e.g.
  toolchain delivery: JDK / .NET SDK / file copy) land as a peer
  `_build-extra-vars-<domain>.sh` plus a dispatch arm here — the
  bridge already forwards every declared vault verbatim, so no other
  call site changes.
- [`ops/_run-playbook.sh`](ops/_run-playbook.sh) - thin,
  consumer-agnostic orchestrator. Validates args, parses the consumer
  contract (via `_parse-consumer-contract.sh`), sets up a
  per-invocation `mktemp -d` tree (`chmod 700`, files `chmod 600`,
  cleaned up by `EXIT` trap), activates `.venv`, drives the helpers in
  order, and dispatches `ansible-playbook` against the requested
  playbook path. Reads the contract-declared inventory vault
  (`CA_INVENTORY_VAULT`) unconditionally - the fleet every dispatch
  targets - deriving its secret as `<Name>Config-<suffix>`, and then
  reads each vault the contract's `CA_EXTRA_VAULTS` declared,
  generically, into its own tmpdir file - so register-runners pays only
  for `GitHubRunners` and a consumer pays only for what it declares, and
  the bridge names no vault at all (inventory provider or consumer alike).
  Each declared extra vault is forwarded to the composer as a generic
  `--vault-config <Name>=<path>` pair. The contract's
  `CA_NEEDS_HOST_FILE_SERVER=1` controls the Windows-side staging:
  when set, the bridge delegates to `_stage-host-fileserver.sh` and
  (via the EXIT trap) stops the listener it backgrounded on every exit
  path; when unset, neither the listener nor the stop call run, and the
  file-server-pair extra-vars keys are genuinely absent. Every flow that
  stages the file server also declares a token (its downstream play
  consumes one), so `CA_NEEDS_HOST_FILE_SERVER=1` requires
  `CA_REQUIRES_TOKEN=1` and is rejected fast otherwise. `GH_TOKEN` is
  lifted to a local when the contract
  requires a token and then cleared from the bridge environment
  unconditionally before `ansible-playbook` runs; the downstream play
  receives the token via the chmod-600 extra-vars file only. Any args
  after the playbook path are forwarded verbatim to `ansible-playbook`
  (so `--tags`, `--limit`, `--check`, `-v`, etc. all work without
  changes to the bridge). When the contract names `CA_CONSUMER_ROOT`,
  the playbook resolves under that root, `_ansible-env.sh` puts the
  consumer's `<root>/roles` ahead of the substrate `roles/` on
  `ANSIBLE_ROLES_PATH`, and the composer is handed `--consumer-root` so
  the per-domain fragment resolves from there too - so a consumer owns
  its playbook, roles, and fragment while reusing this bridge. Empty
  keeps all three on the substrate's own root (the path the bridge's own
  flows take). Under a Git Bash launch the root is translated to the
  `/mnt/...` form and forwarded over `WSLENV` with the other `CA_*`
  variables before the WSL re-exec.
- [`ops/virtual-machines/_stage-host-fileserver.sh`](ops/virtual-machines/_stage-host-fileserver.sh)
  - host file server opt-in branch. Serve-only: the consumer supplies the
  already-staged directory and its artifact version, so this helper just
  picks the bind IP from the provisioner config, starts the listener over
  that directory (one pwsh.exe round-trip), polls the backgrounded
  listener for `BASE_URL=` + `PID=`, and emits its own three-line contract
  on stdout (`RUNNER_VERSION=`, `BASE_URL=`, `PID=`) for the bridge to
  parse.
- [`ops/virtual-machines/_start-host-file-server.ps1`](ops/virtual-machines/_start-host-file-server.ps1)
  - long-lived listener. Binds an `HttpListener` to the host adapter
  whose IP shares a /24 with the target VM (same algorithm as
  `Start-VmFileServer` in Infrastructure.HyperV), serves any file in
  the supplied `-StagingDir` by its basename, prints `BASE_URL=<url>`
  then `PID=<pid>` on stdout, and blocks until killed. Multi-file
  serving leaves room for a future toolchain-delivery feature to
  stage extra payloads in the same dir.
- [`ops/virtual-machines/_stop-host-file-server.ps1`](ops/virtual-machines/_stop-host-file-server.ps1)
  - idempotent stop helper. Force-stops the listener process by PID
  and waits for exit; a missing PID is treated as already-stopped.
- [`ops/virtual-machines/_resolve-router.sh`](ops/virtual-machines/_resolve-router.sh)
  - router/NAT resolution, sourced by the bridge. `resolve_router`
  finds the `kind: router` row, resolves its upstream IP (static from
  the vault or Hyper-V KVP), applies the WSL host-portproxy redirect to
  the SSH endpoint, exports `ROUTER_*` / `SSHPASS` for the inventory
  builder and host-file-server staging, and runs the reachability
  pre-flight via
  [`ops/virtual-machines/_assert-router-reachable.sh`](ops/virtual-machines/_assert-router-reachable.sh).
  Sourced (not exec'd) because it must set those env vars in the
  bridge's own shell and never route the router password through a
  child's stdout. A no-op on single-switch fleets.

External contract (consumed by feature playbooks): the extra-vars
document always has the top-level key `vm_provisioner_config` (the
shared inventory). Every other key is present only when the contract
declared the vault that feeds it: `github_runners_config` +
`github_token` when `CA_EXTRA_VAULTS` names `GitHubRunners` (with
`CA_REQUIRES_TOKEN=1`); and `host_file_server_base_url` +
`runner_version` only when the caller also opts into the host file
server (`CA_NEEDS_HOST_FILE_SERVER=1`, register flow only). The
inventory has one group `vm_provisioner_hosts` keyed by `vmName`.

`jq` is a hard runtime dependency (JSON validation, inventory and
extra-vars composition); [`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
installs it via `sudo apt-get` when absent and falls back to the
`sudo apt-get install -y jq` hint if the install itself cannot
proceed.

Each bash helper has its own bats suite under
[`Tests/ops/`](Tests/ops/) covering its boundary in isolation;
`_run-playbook.bats` stubs `pwsh.exe`, `ansible-playbook`, and the
sibling bash helpers, then asserts orchestration only. The two
host-file-server PowerShell helpers are covered by
[`Tests/ops/Start-HostFileServer.Tests.ps1`](Tests/ops/Start-HostFileServer.Tests.ps1)
- Pester rather than bats because each helper is single-file
PowerShell calling `HttpListener` or `Get-NetIPAddress`; mocking
those from bats would require a `pwsh.exe` round-trip per assertion.
The end-to-end smoke against a real VM is captured in the feature plan.

## Tests and lint

CI is wired to three reusable workflows; nothing is copied per-repo:

- [`.github/workflows/ci-powershell.yml`](.github/workflows/ci-powershell.yml)
  -> `Common-PowerShell/.github/workflows/ci-powershell.yml@master`
  (Pester unit tests + `lint-no-bare-return-empty-array`).
- [`.github/workflows/ci-bash.yml`](.github/workflows/ci-bash.yml)
  -> `Common-Automation/.github/workflows/ci-bash.yml@master` (shellcheck
  on production bash + `*.bats` suites + `+x` bit check).
- [`.github/workflows/ci-yaml.yml`](.github/workflows/ci-yaml.yml)
  -> `Common-Automation/.github/workflows/ci-yaml.yml@master` (yamllint,
  actionlint, action-validator, ansible-lint).

This repo carries **no E2E gate of its own**. As the consumed substrate
(dispatch bridge + reusable roles), its real-VM behaviour is exercised
end-to-end by the consumers' E2E gates - each consumer checks
Common-Ansible out as a sibling and runs its own flow through this
bridge - so a per-PR live-Hyper-V run here would only duplicate that
coverage (and, for the user layer, gate this repo's PRs on a domain it
no longer owns). The substrate's own bar is the bats suites plus the
lint workflows above.

The same checks run locally via thin shims that delegate to the
canonical runners in the sibling repos (so a fix to the CI logic
lands in one place):

- [`scripts/Run-Tests.ps1`](scripts/Run-Tests.ps1) -> calls
  `Common-PowerShell/.github/actions/run-unit-tests/Run-Tests.ps1`.
- [`scripts/run-ci-yaml-and-bash.sh`](scripts/run-ci-yaml-and-bash.sh)
  (with its [`.bat`](scripts/run-ci-yaml-and-bash.bat) Explorer launcher)
  is the MAIN entry -> delegates to Common-Automation's orchestrator to run
  BOTH the lint suite AND the bats tests in one go, the full local
  equivalent of `ci-yaml.yml` + `ci-bash.yml`.
- [`scripts/run-lint-yaml-and-bash.sh`](scripts/run-lint-yaml-and-bash.sh)
  (with its [`.bat`](scripts/run-lint-yaml-and-bash.bat) launcher) ->
  delegates to Common-Automation to run the lint half only (shellcheck,
  actionlint, action-validator, yamllint, ansible-lint); no bats.
- [`scripts/run-tests-bash.sh`](scripts/run-tests-bash.sh)
  (with its [`.bat`](scripts/run-tests-bash.bat) launcher) -> delegates to
  Common-Automation to run the bats tests only.
- [`scripts/fix-permissions.sh`](scripts/fix-permissions.sh) /
  [`scripts/fix-permissions.bat`](scripts/fix-permissions.bat) ->
  forward to `Common-Automation/scripts/fix-permissions.{sh,bat}` to
  re-stage `+x` on tracked `*.sh` files that lost it (heals what the
  `check-sh-executable` CI gate flags).

These shims assume `Common-PowerShell` and `Common-Automation` are sibling
checkouts under the same parent directory. The same assumption now extends
to the operator-side `ops/` bridge: `_run-playbook.sh` and
`_stage-host-fileserver.sh` source the generic `_to_windows_path` helper
from `Common-Automation/scripts/_to-windows-path.sh` (single source of
truth for the WSL->Windows path conversion that keeps `pwsh.exe -File`
from exiting 64). They resolve it from the sibling checkout by default;
`COMMON_AUTOMATION_ROOT` overrides the root, which the bats suites use to
point the source at a mocked copy.

## Consuming the substrate

The reusable roles in [`roles/`](roles/) are **not standalone** - they
read the extra-vars and inventory the dispatch bridge composes
(`github_runners_config`, `host_file_server_base_url`, the
`vm_runner_entries` fact). Roles and bridge are therefore one cohesive
substrate and are consumed **together, through a single sibling
checkout** - not split across two transports.

A consumer keeps Common-Ansible checked out alongside it (under the same
parent, e.g. `c:\a_Code\Common-Ansible`) and resolves that root once -
the same adapter pattern
[`ops/imports/_common-automation-root.sh`](ops/imports/_common-automation-root.sh)
already uses for Common-Automation, overridable with
`COMMON_ANSIBLE_ROOT`. From that one root it gets both:

- **roles** - by adding `<root>/roles` to `ANSIBLE_ROLES_PATH`, so
  playbooks reference substrate roles by their short name; and
- **the ops bridge** - by sourcing/exec'ing `<root>/ops/` (the
  controller bootstrap and `_run-playbook.sh` dispatch).

The two bullets above cover a consumer reusing the **substrate's own**
roles by short name. A consumer that owns roles and a playbook of its
own - the user and runner owners, whose domain roles live in their
repo, not here - declares its repo root through `CA_CONSUMER_ROOT`
(part of the bridge contract). The bridge then resolves that consumer's
playbook, puts its `<consumer-root>/roles` ahead of the substrate
`roles/` on `ANSIBLE_ROLES_PATH`, and resolves its per-domain
extra-vars fragment from `<consumer-root>/ops` - so the consumer owns
its playbook, roles, and fragment while the substrate carries none of
that domain. The substrate's own wrappers leave `CA_CONSUMER_ROOT`
unset and resolve everything from this root unchanged.

Infrastructure-Vm-Users is the reference consumer. A published Galaxy
collection was considered and rejected: a collection can carry only the
roles (the ops bridge cannot ship in one - the controller bootstrap that
builds the venv that runs `ansible-galaxy` is itself part of the bridge),
and the roles have no value without the bridge, so a collection would
split one indivisible substrate into two transports for no gain. If a
genuinely standalone role library emerges later (e.g. the section-2/3
toolchain roles, which need no bridge contract), that subset is a fair
candidate to publish on its own.

## Feature folders

- [Current feature: 08 - GitHub runners registration](docs/dev/implementation/08-github-runners-registration/)
  - [Problem](docs/dev/implementation/08-github-runners-registration/problem.md)
  - [Plan](docs/dev/implementation/08-github-runners-registration/plan.md)
- [03 - groups, users, sudoers removal](docs/dev/implementation/03-groups-users-sudoers-removal/)
  - [Problem](docs/dev/implementation/03-groups-users-sudoers-removal/problem.md)
  - [Plan](docs/dev/implementation/03-groups-users-sudoers-removal/plan.md)
- [02 - groups, users, sudoers creation](docs/dev/implementation/02-groups-users-sudoers-creation/)
  - [Problem](docs/dev/implementation/02-groups-users-sudoers-creation/problem.md)
  - [Plan](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md)
