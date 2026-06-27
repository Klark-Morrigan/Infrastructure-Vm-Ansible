# Problem: Common-Ansible extraction and toolchain provisioning

## Index

- [Summary](#summary)
- [Background](#background)
- [What is changing](#what-is-changing)
- [Common-Ansible partitioning](#common-ansible-partitioning)
- [The bridge coupling to break](#the-bridge-coupling-to-break)
- [The three-section tooling taxonomy](#the-three-section-tooling-taxonomy)
- [Solution approach](#solution-approach)
- [Constraints](#constraints)
- [Risks and sequencing](#risks-and-sequencing)
- [Out of scope](#out-of-scope)

## Summary

A self-hosted GitHub Actions runner VM (`ubuntu-02-ci`) was wired to run
the reusable `ci-bash`, `ci-yaml`, and `ci-dotnet` gates, but the VM is
missing the tools those gates need: `shellcheck` (ci-bash failed with
`shellcheck: command not found`, exit 127), Docker (every ci-yaml linter
runs in a container, and ci-dotnet's integration tests need a daemon),
and `bats`. The VM has only the .NET SDK, installed by the bespoke
PowerShell toolchain reconciler in `Infrastructure-Vm-Provisioner`.

Rather than hand-install the missing tools (lost on re-provision) or grow
the PowerShell reconciler, we standardise VM toolchain provisioning on
**Ansible** - the tool this repo already uses to reconcile users and
register runners - and we restructure the Ansible estate so the reusable
parts are shared and the consumer-specific parts live with their
consumers.

## Background

- `Infrastructure-Vm-Ansible` is the Ansible control layer. A PowerShell
  to WSL bridge reads the VM config from a SecretManagement vault, builds
  inventory and extra-vars, and runs `ansible-playbook` inside a Linux
  venv. It currently owns two concerns: user/group/sudoers reconciliation
  and GitHub runner registration. See the repo README index.
- Toolchain installation (JDK, .NET SDK, .NET tools) lives separately, in
  `Infrastructure-Vm-Provisioner`'s PowerShell reconciler
  (`hyper-v/ubuntu/up/reconciler` plus `up/jdk`, `up/dotnet`). It supports
  exactly one acquisition mode: the host downloads a tarball and pushes it
  to the VM over SSH, then an SSH-driven `Install-Version` extracts it and
  writes a manifest. Reconciliation diffs desired versus installed and
  runs uninstall-then-install.
- The runner VMs sit behind a NAT router (`ubuntu-01-router`) and reach
  the internet through it (confirmed: `github -> HTTP 200`). The
  host-push model is therefore about caching heavy artifacts and version
  determinism, not air-gapping.
- This Ansible repo already pushes a host-staged artifact (the runner
  tarball) to VMs via a host file server (`ops/virtual-machines/_stage-host-fileserver.sh`,
  `ops/virtual-machines/_start-host-file-server.ps1`). The "host-prefetched and pushed"
  pattern is thus already proven in Ansible here.

## What is changing

The roadmap, in order:

1. Rename `Infrastructure-Vm-Ansible` to `Common-Ansible` to minimise
   future churn (the repo becomes the shared substrate; renaming the
   populated repo avoids standing up an empty one - it ships with its
   existing consumers).
2. Move the user-provisioning Ansible (roles, playbooks, ops wrappers) to
   the users repo (`Infrastructure-Vm-Users`); it consumes Common-Ansible
   for the shared controller and plumbing. The pre-migration
   implementation is kept as a fork in Common-Ansible until the consumer
   is proven.
3. Move the runner-provisioning Ansible to the runners repo
   (`Infrastructure-GitHubRunners`); same consume-and-fork model.
4. Migrate the existing toolchain provisioning (JDK, .NET SDK, .NET tools)
   from the PowerShell reconciler to Ansible roles. The PowerShell
   implementation is kept as a fork (not deleted) until the Ansible path
   is proven on production runners.
5. Add `shellcheck` provisioning in Ansible.
6. Add `bats` provisioning in Ansible.
7. Add Docker provisioning in Ansible.

## Common-Ansible partitioning

The repo is already factored into a generic dispatch bridge
(`ops/_run-playbook.sh` does the heavy lifting, toggled by env vars) and
thin per-flow operator wrappers (`create-users.sh`, `register-runners.sh`
set flags and name a playbook). That makes the substrate/consumer split
mostly a matter of moving files - except for the bridge coupling called
out in the next section. The four buckets:

### Bucket A - stays in Common-Ansible (shared substrate)

The controller, the dispatch bridge, and the plumbing every consumer
needs.

- Controller bootstrap: `bootstrap-controller.ps1/.bat`,
  `_bootstrap-controller-wsl.sh`, `_set-wsl-automount-metadata.ps1`,
  `_ansible-env.sh`.
- Dispatch bridge and generic extra-vars core: `_run-playbook.sh`,
  `_read-vault-config.sh`, `_build-extra-vars.sh`,
  `_validate-extra-vars-input.sh`, `_die-on-unknown-flag.sh`.
- VM-fleet module under `ops/virtual-machines/` - the helpers that know
  the fleet's shape (the `vm_provisioner_config` schema and the Hyper-V
  router topology), grouped so that estate-specific coupling stays in
  one named place out of the consumer-agnostic bridge:
  `_build-inventory.sh`, `_build-extra-vars-inventory.sh`,
  `_resolve-router.sh` (the router/NAT resolution lifted out of
  `_run-playbook.sh`), `_assert-router-reachable.sh`, and the host file
  server (`_stage-host-fileserver.sh`, `_start-host-file-server.ps1`,
  `_stop-host-file-server.ps1`) - the section-1 host-push mechanism,
  today only the runner tarball uses it; section-1 toolchains (JDK,
  .NET) reuse it.
- Apt helper (the new section-2 roles need it): `_ensure-apt-command.sh`.
- Common-Automation adapter: `ops/imports/*` (`_log.sh`,
  `_common-automation-root.sh`, `_to-windows-path.sh`).
- Repo scaffolding: `ansible.cfg`, baseline `requirements.yml`,
  `inventory/` skeleton, `.githooks`, `.github` CI, `scripts/` lint/test
  runners, the `Tests/` harness, README structure, generic
  `setup-secrets.ps1/.bat`.

### Bucket B - moves to Infrastructure-Vm-Users (consumes A)

- Roles: `vm_users_entry`, `groups`, `sudoers`, `users`, with their
  `Tests/molecule/*` scenarios.
- Playbooks: `create-users.yml`, `remove-users.yml`,
  `playbooks/tasks/_ensure-acl-present.yml`.
- Wrappers: `create-users.sh/.bat`, `remove-users.sh/.bat`,
  `_build-extra-vars-users.sh`.
- The `VmUsers` vault knowledge.

### Bucket C - moves to Infrastructure-GitHubRunners (consumes A)

- Roles: `runner_entry_resolve`, `runner_binary`, `runner_registration`,
  `runner_service`, with their molecule scenarios.
- Playbooks: `register-runners.yml`, `deregister-runners.yml`,
  `runner-status.yml`, `playbooks/tasks/_handle-unreachable-entry.yml`,
  `_runner-status-one.yml`.
- Wrappers: `register-runners.*`, `deregister-runners.*`,
  `runner-status.sh`, `_require-gh-token.sh`, `_build-extra-vars-runners.sh`,
  `_ensure-runner-tarball.ps1`, `_resolve-runner-version.ps1`,
  `setup-runners-secrets.ps1/.bat`.
- The `GitHubRunners` vault, `GH_TOKEN`, and the `NEEDS_HOST_FILE_SERVER`
  opt-in usage (the server itself stays in A).

### Bucket D - new toolchain roles (reusable, land in Common-Ansible)

- `toolchain_apt` (shellcheck, bats - section 2), `docker` (section 3),
  and the migrated `jdk` / `dotnet_sdk` / `dotnet_tools` (section 1,
  reusing A's host file server). These are reusable roles consumed by the
  provisioning flow, so they belong in Common-Ansible alongside A.

The two leaf "entry resolve" roles (`vm_users_entry`,
`runner_entry_resolve`) are the same pattern - resolve a per-host entry
from extra-vars - with different schemas. They move with their domains
(B and C). A generic entry-resolve role is promoted to A only if a third
consumer appears; not now.

## The bridge coupling to break

`ops/_run-playbook.sh` is almost generic but hardcodes its consumers: it
names all three vaults (`VmProvisioner`, `VmUsers`, `GitHubRunners`) and
carries the runner-specific toggles (`NEEDS_GITHUB_RUNNERS`, `GH_TOKEN`,
`NEEDS_HOST_FILE_SERVER`). Moved into Common-Ansible as-is, the substrate
would import knowledge of its own consumers - a dependency-inversion
violation. The extraction's real (non-mechanical) work is making the
bridge consumer-agnostic:

- Every consumer needs an inventory (the base VM list and addresses), so
  the bridge always reads one - but the *vault it reads it from* is
  consumer-declared too, not hardcoded. `VmProvisioner` is itself a named
  vault owned by `Infrastructure-Vm-Provisioner`; baking that name into
  the substrate would couple it to one repo's naming. The contract
  therefore carries a required inventory-vault field (the wrapper passes
  `VmProvisioner`), so the bridge names no vault at all.
- `VmUsers` and `GitHubRunners` become consumer-declared the same way:
  the wrapper states "read these extra vaults, set these toggles" through
  the contract, instead of the bridge naming them.

This decoupling is a prerequisite for steps 2-3 and is sequenced before
the consumer-specific code moves out.

## The three-section tooling taxonomy

Each tool a VM needs is classified by acquisition strategy. This taxonomy
is expressed in the per-VM config and drives which Ansible mechanism a
toolchain role uses.

| Section | Meaning | Mechanism | First tools |
| --- | --- | --- | --- |
| 1. Host-prefetched, pushed | Heavy artifacts the host caches once and pushes to each VM | Control-node download + `copy`/`unarchive` to the VM (the existing file-server pattern) | JDK, .NET SDK |
| 2. VM-downloaded | Small packages the VM fetches itself | `ansible.builtin.apt` / `get_url` on the VM | shellcheck, bats |
| 3. Base-image / daemon | Daemons or rarely-versioned services that warrant install at a coarser grain | Ansible role (apt repo + service + group), evaluated against base-image baking | Docker |

Docker's exact home (an Ansible role versus base-image baking) is settled
in [Solution approach](#solution-approach).

## Solution approach

### Off-the-shelf survey

| Option | Source / license | Fit | Integration cost | Notes |
| --- | --- | --- | --- | --- |
| Extend the PowerShell reconciler | In-repo | Covers section 1; section 2 needs a new VM-side mode; no section 3 | None new | Keeps a bespoke SSH-over-PowerShell convergence model we hand-maintain |
| **Ansible** | OSS, GPL/Apache modules | Covers all three sections: `apt`/`get_url` (s2), `community.docker` (s3), control-node `copy`+`unarchive` (s1) | Already in this repo and stack; pin collections | Industry standard for this exact job; idempotent re-run model |
| cloud-init | OSS, Apache/GPL | Section 3 only (`packages:`/`runcmd` at first boot) | Already used for seed | Seed is deliberately offline/no-`packages:` today |
| Packer | BSL-1.1 (not OSI) | Section 3 only (golden image) | New tool and image pipeline | Overkill without an existing image pipeline |
| mise / asdf | OSS, MIT | Language runtimes; weak for daemons and CLI tools | New per-VM dependency | Overlaps the manifest model |

### Why Common-, not Infrastructure-

The estate uses two repo prefixes with distinct meanings: `Common-*` is
reusable substrate consumed by other repos (`Common-Automation` reusable
CI, `Common-PowerShell` shared cmdlets, `Common-DotNet` reusable .NET CI),
while `Infrastructure-*` is a concrete flow that provisions or deploys to
real machines (`Infrastructure-HyperV`, `Infrastructure-Vm-Provisioner`,
`Infrastructure-GitHubRunners`).

After this migration the user and runner flows move out to their consumer
repos, leaving the consumer-agnostic controller bridge plus reusable roles
(including the bucket-D toolchain roles) - pure substrate. That is the
`Common-*` semantic, so `Common-Ansible` is the consistent name and the
fourth member of the Common- family.

The name is honest only while one line holds: the playbooks and inventory
that target production VMs (which toolchain lands on which box) live in a
consumer repo, never in Common-Ansible. If the repo both ships substrate
and deploys to production, `Infrastructure-Ansible` would be the truthful
name. The bridge-decoupling work (see
[The bridge coupling to break](#the-bridge-coupling-to-break)) is what
keeps the repo on the substrate side of that line and earns the `Common-`
prefix.

### Chosen direction: adopt Ansible, restructure into Common-Ansible

Ansible covers every section, including the host-push pattern already
proven in this repo, and removes the need to maintain a bespoke
PowerShell-over-SSH convergence engine. The one capability Ansible does
not give for free is the reconciler's "uninstall versions no longer
desired" diff; this is a small explicit pattern in Ansible (record
installed versions as a fact, remove the set difference) and is designed
in step 4, not inherited.

Docker is provisioned by an **Ansible role** (apt repo, service enable,
and adding the runner service user to the `docker` group), not by
base-image baking. Rationale: there is no Packer/golden-image pipeline
today, so "base image" would mean cloud-init `runcmd`, which forces
relaxing the seed's deliberate offline stance and pushes a daemon install
into hard-to-debug first boot. These runner VMs already receive an Ansible
pass, so a docker role is co-located, idempotent, and re-runnable.
Base-image baking is revisited only if a measured boot-time or fleet-scale
problem appears - recorded in [Out of scope](#out-of-scope).

The `Common-Ansible` extraction mirrors the existing `Common-Automation`
(reusable CI) and `Common-PowerShell` (shared cmdlets) substrate pattern:
a reusable-roles repo consumed by `Infrastructure-Vm-Users`,
`Infrastructure-GitHubRunners`, and (for toolchains) the provisioning
flow, via `requirements.yml` git-sourced roles/collections.

## Constraints

- Reusable substrate ships with a consumer; the rename keeps the existing
  consumers attached rather than creating an empty repo.
- Cross-repo consumption (consumer repos pull Common-Ansible's reusable
  roles) is preferred over copy-forking the shared parts; only the
  consumer-specific roles move into the consumer repos.
- Master-only branches across all affected repos.
- Tests mirror production structure. Molecule scenarios for roles;
  playbook-level integration tests where a role composition is the unit.
- README sections are earned per step and kept in the structured index.
- ASCII only; comments wrap at 90 columns.
- Rename blast radius must be handled in-step: git remote, local working
  directory, the GitHub repo, and the `.menu` references
  (`supersets.psd1`, `menus.psd1`, `cluster-order.psd1`,
  `manual-dependencies.psd1`, `Get-ScenarioMenus.ps1`).
- The runner VM definition lives in the `VmProvisionerConfig-Production`
  secret (vault `VmProvisioner`); the config-schema change and the secret
  update are explicit plan steps, followed by re-provisioning the runner.

## Risks and sequencing

- The roadmap front-loads the restructure (steps 1-4) before the new
  tools (steps 5-7), so the red runner stays red until late. If unblocking
  ci-bash sooner matters, the `shellcheck`/`bats`/`docker` roles (5-7) can
  be authored against the current repo structure first and the
  Common-Ansible extraction (1-3) sequenced around them. This tradeoff is
  surfaced for the plan-review decision.
- Repo rename breaks any unpinned `uses:`/remote/`requirements.yml`
  reference; every referrer is updated in the rename step.
- Keeping the PowerShell reconciler as a fork (step 4) means two engines
  coexist transiently; the cutover criterion (Ansible toolchain proven on
  a production runner) is defined before the PowerShell path is retired in
  a later feature.

## Out of scope

- Retiring the PowerShell toolchain reconciler entirely (kept as a fork; a
  later feature removes it once the Ansible path is proven).
- Base-image / Packer baking of Docker (revisited only on a measured
  boot-time or fleet-scale need).
- Migrating non-toolchain provisioner concerns (networking, disk, seed)
  to Ansible.
