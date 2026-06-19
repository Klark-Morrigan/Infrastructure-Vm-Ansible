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
  - [Troubleshooting: capturing logs and re-running an interrupted bootstrap](#troubleshooting-capturing-logs-and-re-running-an-interrupted-bootstrap)
- [Vault setup](#vault-setup)
- [Create users](#create-users)
- [Remove users](#remove-users)
- [Register runners](#register-runners)
- [Deregister runners](#deregister-runners)
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
`C:\a_Code\Infrastructure-VM-Ansible\`. Look there if the log seems
to have vanished.

If a bootstrap run is interrupted (Ctrl+C, network blip during
`ansible-galaxy collection install`, sudo prompt dismissed), **just
re-run it**. Every stage is idempotent: an existing healthy `.venv`
is reused, pip pins are no-ops when current, `ansible-galaxy
--force-with-deps` re-installs cleanly over a partial extraction.
The only state worth manually clearing is a half-built `.venv` that
has `bin/python` but no `bin/pip` (left behind by the pre-fix
`python3 -m venv` bug); in that case
`rm -rf /mnt/c/a_Code/Infrastructure-VM-Ansible/.venv` then re-run
bootstrap to recreate it cleanly.

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
`Common-PowerShell`. A follow-up feature replaces the wrapper with a
first-class implementation when the vault contract diverges (or
Vm-Users is archived).

The `GitHubRunnersConfig` payload (consumed by the
[register-runners flow](#register-runners)) lands in the
`GitHubRunners` vault under the secret name
`GitHubRunnersConfig-<Suffix>` via a peer wrapper:

```
pwsh ./ops/setup-runners-secrets.ps1 `
    -ConfigFile C:\private\runners-config.json `
    -SecretSuffix Production
```

or by dropping the JSON file onto
[`ops/setup-runners-secrets.bat`](ops/setup-runners-secrets.bat) (the
launcher omits `-SecretSuffix` on purpose so pwsh prompts the operator
for the lifecycle label at drop time rather than silently defaulting).

[`ops/setup-runners-secrets.ps1`](ops/setup-runners-secrets.ps1)
delegates to
[`Infrastructure-GitHubRunners/hyper-v/ubuntu/setup-secrets.ps1`](../Infrastructure-GitHubRunners/hyper-v/ubuntu/setup-secrets.ps1)
under the same sibling-checkout convention as the Vm-Users wrapper.
Both repos target the same `GitHubRunners` vault and the same
`GitHubRunnersConfig-<Suffix>` secret name - which is exactly what
this repo's bridge reads from when `NEEDS_GITHUB_RUNNERS=1`. The
GitHub PAT is **not** stored in this vault: it is supplied per
register-runners invocation via the entry script's prompt (or
`GH_TOKEN` for unattended callers).

## Create users

Once the controller is bootstrapped and the vault entry is in place,
the create-users flow reconciles every host in the `VmProvisionerConfig`
inventory with one command:

```
wsl ./ops/create-users.sh
```

or double-click [`ops/create-users.bat`](ops/create-users.bat) from
Explorer (Git Bash launcher; mirrors the
[`scripts/run-ci-yaml-and-bash.bat`](scripts/run-ci-yaml-and-bash.bat)
sibling-find pattern and reuses
[`Common-Automation/scripts/_find-bash.bat`](../Common-Automation/scripts/_find-bash.bat)).

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

## Remove users

The reverse flow tears down what `create-users` reconciled. One
command tells every host in the `VmProvisionerConfig` inventory to
drop the declared sudoers drop-ins, accounts, and (empty) groups:

```
wsl ./ops/remove-users.sh
```

or double-click [`ops/remove-users.bat`](ops/remove-users.bat) from
Explorer (same Git Bash launcher pattern as the create side).

[`ops/remove-users.sh`](ops/remove-users.sh) is a one-line wrapper
that dispatches [`playbooks/remove-users.yml`](playbooks/remove-users.yml)
through the [bridge](#bridge-contract); the same operator knobs as
the create side work unchanged:

```
wsl ./ops/remove-users.sh --check               # dry-run
wsl ./ops/remove-users.sh --tags users          # scope to one role
wsl ./ops/remove-users.sh --limit vm-1,vm-2     # scope to specific VMs
wsl ./ops/remove-users.sh -v                    # verbose play recap
```

The playbook invokes each role with `tasks_from: remove` in the
reverse order `sudoers -> users -> groups` (drop-ins first so they
no longer reference live accounts, accounts next so userdel clears
implicit primary groups, groups last so the empty-group check finds
them empty). `any_errors_fatal: false` matches the create posture —
one offline VM does not strand the rest.

There is no confirmation prompt. The destructive intent is in the
script name and the operator's choice to invoke it (decision in
`docs/dev/implementation/03-.../problem.md`). The remove direction
is also bounded by **declaration**, not drift: only usernames and
group names listed in `VmUsersConfig` for the host are touched;
out-of-config accounts, groups, and sudoers drop-ins are left alone.

Two contracts worth highlighting before invoking the flow:

- **Non-empty declared groups are kept, not forced.** If a declared
  group still has members after the users pass, the groups role
  emits a debug warning naming the remaining members and skips the
  removal; the play exits 0. Operators who want the group gone after
  that need to deal with the out-of-config members manually.
- **Running processes do not block removal.** Before `userdel`, the
  users role issues `pkill -KILL -u <username>` (rc=1 means no
  processes and is ignored). `userdel -f -r` then deletes the
  account and its home directory; a final assert surfaces the rare
  case where even `-f` could not free the account (D-state task,
  kernel-thread parent).

## Register runners

The runner-registration flow brings every declared self-hosted GitHub
Actions runner up against the same `VmProvisionerConfig` inventory.
One command stages the actions/runner tarball over a Hyper-V-side
HTTP listener, registers each runner with GitHub, and starts the
systemd service:

```
wsl ./ops/register-runners.sh
```

or double-click [`ops/register-runners.bat`](ops/register-runners.bat)
from Explorer (same Git Bash launcher pattern as the users-side
entries).

[`ops/register-runners.sh`](ops/register-runners.sh) prompts for the
GitHub PAT via `read -s` when `GH_TOKEN` is unset, exports it plus
`NEEDS_GITHUB_RUNNERS=1` (the [bridge](#bridge-contract)'s third
vault-read gate) and `NEEDS_HOST_FILE_SERVER=1` (the bridge's
host-file-server staging gate; register only, because the down path
fetches nothing), and dispatches
[`playbooks/register-runners.yml`](playbooks/register-runners.yml)
through the bridge. The same operator knobs as the users-side flows
work unchanged:

```
wsl ./ops/register-runners.sh --check                    # dry-run
wsl ./ops/register-runners.sh --tags runner_binary       # scope to one role
wsl ./ops/register-runners.sh --limit vm-1,vm-2          # scope to specific VMs
wsl ./ops/register-runners.sh -v                         # verbose play recap
```

For unattended callers (the E2E agent, CI), exporting `GH_TOKEN`
before invoking the entry suppresses the prompt entirely - the same
script serves both interactive operators and automation without
branching on a flag.

The playbook composes the three runner roles in
`runner_binary -> runner_registration -> runner_service` order
against the `vm_provisioner_hosts` inventory group; each role is
tagged with its own name. `any_errors_fatal: false` matches the
users-side posture - one offline VM does not strand the rest.

Two contracts worth highlighting before invoking the flow:

- **The GitHub PAT never reaches the vault.** It is supplied
  per-invocation (prompt or `GH_TOKEN`), threaded into the
  controller-side `ansible.builtin.uri` calls via the chmod-600
  extra-vars file, and cleared from the bridge environment before
  `ansible-playbook` runs. Every token-bearing task is `no_log: true`
  so the value never surfaces even at `-vvv`.
- **The tarball download bypasses the VM's NAT path.** The bridge
  starts a Windows-side `HttpListener` bound to the Hyper-V switch
  IP, downloads / caches the runner tarball under
  `%LOCALAPPDATA%\Temp\runner-cache\`, and serves it to each VM by
  basename. The listener PID rides in the bridge's `EXIT` trap, so a
  Ctrl+C, a network blip, or a play failure all still tear it down.

## Deregister runners

The reverse flow tears down what `register-runners` reconciled. One
command stops the systemd service for every declared runner,
deregisters it from GitHub, and removes the per-runner extract
directory under `/opt/runners/`:

```
wsl ./ops/deregister-runners.sh
```

or double-click [`ops/deregister-runners.bat`](ops/deregister-runners.bat)
from Explorer (same Git Bash launcher pattern as the register entry).

[`ops/deregister-runners.sh`](ops/deregister-runners.sh) mirrors the
register entry's prompt-or-`GH_TOKEN` shape and exports
`NEEDS_GITHUB_RUNNERS=1` so the [bridge](#bridge-contract) reads the
`GitHubRunners` vault. It deliberately does **not** export
`NEEDS_HOST_FILE_SERVER`: the down path fetches nothing from the
Windows side, so spawning the `HttpListener` would be a port and a
failure surface for no consumer. The wrapper owns one flag of its
own, `--force`, which it consumes and translates to
`--extra-vars runners_force_remove=true` for `ansible-playbook`
(which has no `--force` flag of its own); every other arg is
forwarded verbatim, so the usual operator knobs work unchanged:

```
wsl ./ops/deregister-runners.sh --force                    # delete unreachable VMs' runners via the GitHub API
wsl ./ops/deregister-runners.sh --check                    # dry-run
wsl ./ops/deregister-runners.sh --tags runner_service      # scope to one role
wsl ./ops/deregister-runners.sh --limit vm-1,vm-2          # scope to specific VMs
wsl ./ops/deregister-runners.sh -v                         # verbose play recap
```

The playbook invokes each role with `tasks_from: remove` in the
reverse order `runner_service -> runner_registration -> runner_binary`
(stop the unit first so it cannot hold credentials open, deregister
on GitHub next while `config.sh` is still on disk, remove the
extract directory last). There is no confirmation prompt; the
destructive intent is in the script name and the operator's choice
to invoke it.

Two contracts worth highlighting before invoking the flow:

- **`--force` runs controller-side via the GitHub REST API.** A
  reachable VM always deregisters through `config.sh remove`; only
  entries on **unreachable** VMs reach the force path, where the
  controller `DELETE`s `.../actions/runners/{id}` directly. Without
  `--force`, the play surfaces those entries as a single non-zero
  exit at the end of the run rather than silently leaking stale
  GitHub-side registrations.
- **The GitHub PAT is not stored.** Same per-invocation supply as
  the register flow (prompt or `GH_TOKEN`); same `no_log: true` on
  every token-bearing task; same clearance from the bridge
  environment before `ansible-playbook` runs.

## Bridge contract

The bash bridge between operator scripts under `ops/` and
`ansible-playbook` is split across single-purpose helpers under
`ops/` with a leading `_` (the "called by operator entries, not
typed by a human" convention). Each is unit-testable against just
its own external boundary:

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
- [`ops/_build-extra-vars.sh`](ops/_build-extra-vars.sh) - extra-
  vars orchestrator. Owns no payload domain itself; accepts the
  union of helper flags and dispatches to one per-payload-domain
  helper per domain present, then merges their JSON fragments via
  `jq -s add`. Required flags: `--provisioner-config <file>` and
  `--users-config <file>`. The runners-domain flags split into two
  paired groups, both optional:
  - **runners pair**: `--runners-config <file>` + `--github-token
    <value>` — the GitHubRunners-vault read result. Carries
    everything either direction (register / deregister) needs.
  - **file-server pair**: `--host-base-url <url>` + `--runner-version
    <ver>` — the bridge-resolved tarball download URL the register
    flow adds on top. The deregister flow omits both keys (its VMs
    fetch nothing).
  Within each pair the two flags arrive together or not at all;
  partial sets are rejected before any helper runs. The file-server
  pair has no meaning without the runners pair and is rejected if
  supplied alone. The per-domain helpers below own their own
  validation and bats coverage:
  - [`ops/_build-extra-vars-inventory.sh`](ops/_build-extra-vars-inventory.sh)
    — emits `vm_provisioner_config`. Always-on; the inventory source
    every payload domain shares.
  - [`ops/_build-extra-vars-users.sh`](ops/_build-extra-vars-users.sh)
    — emits `vm_users_config` for the groups / users / sudoers roles.
  - [`ops/_build-extra-vars-runners.sh`](ops/_build-extra-vars-runners.sh)
    — emits `github_runners_config` + `github_token` always, plus
    `host_file_server_base_url` + `runner_version` when the
    file-server pair is supplied. Owns the token-non-empty
    fast-fail and threads the value through `jq --arg` so
    shell-special characters land verbatim. Genuinely omits the two
    file-server keys when their pair is absent (the down-direction
    roles never reference them and an empty string would be a
    stale-URL trap).
  Config inputs are file paths (not values) so secrets stay out of
  argv. The GitHub token is the lone exception, passed by value
  because the entry script already holds it in a shell variable;
  argv on Linux is private to the owning user's process tree.
  Future payload domains (e.g. toolchain delivery: JDK / .NET SDK /
  file copy) land as a peer `_build-extra-vars-<domain>.sh` plus a
  dispatch arm in the orchestrator — no other call site changes.
- [`ops/_run-playbook.sh`](ops/_run-playbook.sh) - thin
  orchestrator. Validates args, sets up a per-invocation
  `mktemp -d` tree (`chmod 700`, files `chmod 600`, cleaned up by
  `EXIT` trap), activates `.venv`, drives the helpers in order,
  and dispatches `ansible-playbook` against the requested playbook
  path. Reads two vaults unconditionally (`VmProvisioner`,
  `VmUsers`) and adds a third (`GitHubRunners`) when the caller
  exports `NEEDS_GITHUB_RUNNERS=1` plus `GH_TOKEN=...` - the
  opt-in gate keeps the create-users / remove-users entry points
  free of an unused `pwsh.exe` round-trip. A second, independent
  gate `NEEDS_HOST_FILE_SERVER=1` (set by the register entry
  alongside `NEEDS_GITHUB_RUNNERS=1`, omitted by the deregister
  entry) controls the Windows-side staging: when set, the bridge
  delegates to `_stage-host-fileserver.sh` and (via the EXIT trap)
  stops the listener it backgrounded on every exit path; when
  unset, neither the listener nor the corresponding stop call run,
  and the file-server-pair extra-vars keys are genuinely absent.
  `NEEDS_HOST_FILE_SERVER=1` without `NEEDS_GITHUB_RUNNERS=1` is
  rejected fast - the listener has no consumer without the
  runner_binary role. `GH_TOKEN` is cleared from the bridge
  environment before `ansible-playbook` runs; the downstream play
  receives the token via the chmod-600 extra-vars file only. Any
  args after the playbook path are forwarded verbatim to
  `ansible-playbook` (so `--tags`, `--limit`, `--check`, `-v`,
  etc. all work without changes to the bridge).
- [`ops/_stage-host-fileserver.sh`](ops/_stage-host-fileserver.sh)
  - GitHubRunners opt-in branch. Drives the three pwsh.exe
  round-trips (resolve version, ensure tarball, start listener),
  picks the first VM's `ipAddress` from the provisioner config for
  the bind, polls the backgrounded listener for `BASE_URL=` +
  `PID=`, and emits its own three-line contract on stdout
  (`RUNNER_VERSION=`, `BASE_URL=`, `PID=`) for the bridge to parse.
- [`ops/_resolve-runner-version.ps1`](ops/_resolve-runner-version.ps1)
  - GitHub Releases API client. GETs
  `repos/actions/runner/releases/latest` with the supplied token and
  prints the version string with the leading `v` stripped. Mirrors
  `Resolve-RunnerVersion` in Infrastructure-GitHubRunners so both
  flows resolve identically.
- [`ops/_ensure-runner-tarball.ps1`](ops/_ensure-runner-tarball.ps1)
  - tarball cache helper. Returns the path to
  `$LOCALAPPDATA\Temp\runner-cache\actions-runner-linux-x64-<ver>.tar.gz`,
  downloading from `github.com` on cache miss and purging stale
  versions in the same cache directory. Mirrors
  `Invoke-RunnerTarballEnsure` in Infrastructure.GitHub.
- [`ops/_start-host-file-server.ps1`](ops/_start-host-file-server.ps1)
  - long-lived listener. Binds an `HttpListener` to the host adapter
  whose IP shares a /24 with the target VM (same algorithm as
  `Start-VmFileServer` in Infrastructure.HyperV), serves any file in
  the supplied `-StagingDir` by its basename, prints `BASE_URL=<url>`
  then `PID=<pid>` on stdout, and blocks until killed. Multi-file
  serving leaves room for a future toolchain-delivery feature to
  stage extra payloads in the same dir.
- [`ops/_stop-host-file-server.ps1`](ops/_stop-host-file-server.ps1)
  - idempotent stop helper. Force-stops the listener process by PID
  and waits for exit; a missing PID is treated as already-stopped.

External contract (consumed by feature playbooks): the extra-vars
document always has the two top-level keys `vm_provisioner_config`
and `vm_users_config`. Additionally, `github_runners_config` and
`github_token` are present whenever the caller opts into the
GitHubRunners vault read (`NEEDS_GITHUB_RUNNERS=1`), and
`host_file_server_base_url` + `runner_version` are present only
when the caller also opts into the host file server
(`NEEDS_HOST_FILE_SERVER=1`, register flow only). The inventory
has one group `vm_provisioner_hosts` keyed by `vmName`.

`jq` is a hard runtime dependency (JSON validation, inventory and
extra-vars composition); [`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
installs it via `sudo apt-get` when absent and falls back to the
`sudo apt-get install -y jq` hint if the install itself cannot
proceed.

Each bash helper has its own bats suite under
[`Tests/ops/`](Tests/ops/) covering its boundary in isolation;
`_run-playbook.bats` stubs `pwsh.exe`, `ansible-playbook`, and the
sibling bash helpers, then asserts orchestration only. The four
PowerShell helpers are covered by
[`Tests/ops/Start-HostFileServer.Tests.ps1`](Tests/ops/Start-HostFileServer.Tests.ps1)
- Pester rather than bats because each helper is single-file
PowerShell calling `Invoke-RestMethod`, `HttpListener`, or
`Get-NetIPAddress`; mocking those from bats would require a
`pwsh.exe` round-trip per assertion. The end-to-end smoke against a
real VM is captured in the feature plan.

## Tests and lint

CI is wired to two reusable workflows; nothing is copied per-repo:

- [`.github/workflows/ci-powershell.yml`](.github/workflows/ci-powershell.yml)
  -> `Common-PowerShell/.github/workflows/ci-powershell.yml@master`
  (Pester unit tests + `lint-no-bare-return-empty-array`).
- [`.github/workflows/ci-bash.yml`](.github/workflows/ci-bash.yml)
  -> `Common-Automation/.github/workflows/ci-bash.yml@master` (shellcheck
  on production / runner bash + `*.bats` suites + `+x` bit check).
- [`.github/workflows/ci-yaml.yml`](.github/workflows/ci-yaml.yml)
  -> `Common-Automation/.github/workflows/ci-yaml.yml@master` (yamllint,
  actionlint, action-validator, ansible-lint).
- [`.github/workflows/e2e.yml`](.github/workflows/e2e.yml)
  -> `Infrastructure-E2E/.github/workflows/e2e.yml@master`. Required PR
  check: the workstation polling agent picks up the deployment created
  by the shared workflow, runs the full runner-lifecycle test against a
  real Hyper-V VM with the agent's default `UsersFlow=ansible`, and
  reports back. An Ansible role / playbook / bridge change cannot merge
  to `master` until the new code has been proven to reconcile users and
  bring an online runner up via this repo's `ops/create-users.sh`. The
  agent also dispatches the runner-registration half via
  `Set-VmRunnersForTest`: when `RunnersFlow=ansible` is set in the
  agent's `E2EConfig` vault, the same gate drives this repo's
  `ops/register-runners.sh` instead of
  `Infrastructure-GitHubRunners/hyper-v/ubuntu/register-runners.ps1`.
  Opt in explicitly during the first validation cycle; the default-flip
  happens in a follow-up bump. Requires the GitHub App from
  Infrastructure-E2E's setup to be installed on this repo and the
  `GH_APP_ID` / `GH_APP_PRIVATE_KEY` Actions secrets to be present.

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

The `playbooks/deregister-runners.yml` controller-side glue (reachability
split, `--force` fan-out via the GitHub REST API, end-of-run assert) is
covered by a dedicated smoke playbook,
[`Tests/ansible/test-deregister-runners-playbook.yml`](Tests/ansible/test-deregister-runners-playbook.yml).
The smoke test stands up the shared localhost mock of the GitHub runners API
([`Tests/mock-github-api.py`](Tests/mock-github-api.py), single source for
both molecule scenarios and this smoke playbook),
points a fixture inventory at one reachable host (loopback) and one
deliberately unreachable host (TEST-NET-1 with a 2-second TCP timeout),
and drives `ansible-playbook playbooks/deregister-runners.yml` twice -
once without `runners_force_remove` (asserts the play-3 assert fires
and no `DELETE` was issued) and once with `runners_force_remove=true`
(asserts the assert passes and the unreachable runner's `DELETE` hit
the mock). Per-role remove behaviour stays under the molecule
scenarios; this smoke test owns only the playbook-level wiring.
Invoke with `wsl ansible-playbook Tests/ansible/test-deregister-runners-playbook.yml -i localhost,`
inside the repo's venv.

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
- [`roles/runner_entry_resolve`](roles/runner_entry_resolve/README.md) -
  repo-internal helper. Resolves the per-host slice of
  `GitHubRunnersConfig` into the shared `vm_runner_entries` fact;
  pulled in via meta dependency by the runner roles below so the
  selectattr filter lives in one file instead of three. Same
  single-source-of-truth posture as `vm_users_entry`.
- [`roles/runner_binary`](roles/runner_binary/README.md) - cache the
  `actions/runner` tarball under each declared `runnerUsername` on a
  host and extract a copy into `/opt/runners/<runnerName>/`. First
  role in the register-runners flow; downloads from
  `host_file_server_base_url` (the Hyper-V switch IP the bridge's
  PowerShell `HttpListener` binds to) so VMs avoid the NAT path to
  `github.com`.
- [`roles/runner_registration`](roles/runner_registration/README.md) -
  reconcile each runner's registration state on GitHub and on disk.
  Second role in the register-runners flow; runs after
  `runner_binary` (which lays `config.sh` on disk) and before
  `runner_service`. Controller-side `ansible.builtin.uri` calls probe
  `/repos/.../actions/runners` and mint registration / removal tokens
  with `no_log: true` on every token-bearing task; the GitHub PAT
  rides only in `Authorization` headers and never lands in URL query
  strings, argv, or shell history.
- [`roles/runner_service`](roles/runner_service/README.md) - reconcile
  the systemd service for each runner. Third (and last) role in the
  register-runners flow; runs after `runner_registration` (which lays
  `.runner` on disk - both `config.sh` and `.runner` are required for
  `svc.sh install` to succeed). Probes for the unit, installs via
  `svc.sh install <user>` when absent, enables + starts via
  `ansible.builtin.systemd`, then re-checks `systemctl is-active` per
  entry with a failure message that names the unit and points at
  `journalctl -u <unit> --no-pager -n 200`.

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
