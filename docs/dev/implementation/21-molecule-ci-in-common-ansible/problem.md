# Problem: Molecule CI in Common-Ansible

## Index

- [Summary](#summary)
- [For laymen](#for-laymen)
- [Background](#background)
- [What is changing](#what-is-changing)
- [The scenarios do not currently pass](#the-scenarios-do-not-currently-pass)
- [Why this belongs in Common-Ansible](#why-this-belongs-in-common-ansible)
- [Solution approach](#solution-approach)
- [Relationship to feature 20](#relationship-to-feature-20)
- [Constraints](#constraints)
- [Risks and sequencing](#risks-and-sequencing)
- [Out of scope](#out-of-scope)

## Summary

The Ansible roles in this estate ship molecule scenarios under
`Tests/molecule/<role>/<scenario>/` (converge, idempotence, verify, plus
a remove direction), but **no CI workflow runs them** - a grep for
`molecule` across Common-Automation's reusable workflows and every repo's
`.github/` is empty. Molecule is the only check that exercises a role's
real behaviour on a running OS; everything in CI today is static
(`ansible-lint`, `yamllint`). So a role that lints clean and is valid
YAML but does the wrong thing on a real machine - e.g. applies to every
host instead of the one matching `vmName` - ships undetected.

Compounding this, the scenarios do not currently pass `converge` even
locally (see [below](#the-scenarios-do-not-currently-pass)), so "add
molecule to CI" is not a one-line workflow add: the scenarios must be
fixed first.

This feature fixes the scenarios so they actually run, and adds molecule
as a second job in the Ansible-domain `ci-ansible.yml` workflow that
[feature 20](../20-ansible-lint-ci-in-common-ansible/problem.md) creates
in **Common-Ansible** (the Ansible controller repo, which already owns
the toolchain molecule needs), consumed by every repo that contains
roles.

## For laymen

Spell-checking a recipe tells you the words are spelled right; it does
not tell you the cake comes out edible. Our Ansible roles get the
spell-check (lint) on every change, but nobody is actually baking the
cake to confirm it works - that is what "molecule" does: it spins up a
throwaway machine, runs the role for real, and checks the result. Right
now that test exists but is never run automatically, and it does not even
work on the current setup. This change repairs the test and wires it into
the automatic checks, so a role that looks fine but behaves wrongly gets
caught before it ships.

## Background

- Each role carries molecule scenarios that use the Docker driver: a
  `default` scenario (apply the role, re-apply to prove idempotence,
  verify the resulting system state) and usually a `remove` scenario
  (apply, then tear down, then verify the artifacts are gone).
- Molecule is already installed in Common-Ansible's controller venv
  (`.venv/bin/molecule`), and the repo owns `ansible-core`, the pinned
  Galaxy collections, and the controller bootstrap.
- The `run-molecule-tests` skill drives a single scenario locally and
  notes molecule "is not part of `scripts/run-tests.sh` today; this skill
  is the only place it runs." CI confirms the same: nothing invokes it.
- Consumer repos (Infrastructure-Vm-Users, Infrastructure-GitHubRunners)
  consume Common-Ansible's substrate roles by short name; their molecule
  scenarios reference both the consumer's own roles and the substrate
  roles, so resolving short names in CI needs the Common-Ansible sibling
  on `ANSIBLE_ROLES_PATH`.

## The scenarios do not currently pass

Running a scenario surfaces two defects that block any CI adoption:

- **No Python on the target image.** The scenarios set
  `pre_build_image: true` against a bare `ubuntu:24.04`, which ships no
  `python3`. Converge dies at the first module with
  `/usr/bin/python3: not found` (rc 127). This reproduces identically in
  Common-Ansible's own `Tests/molecule/groups/default`, so the scenarios
  have effectively never run green here.
- **Fragile relative `roles_path`.** `molecule.yml` sets
  `roles_path: ../../../../roles`, which molecule resolves relative to its
  ephemeral run directory rather than the scenario directory; on a
  `/mnt/c` checkout it lands on a non-existent `/home/roles` and the role
  is "not found". An explicit absolute `ANSIBLE_ROLES_PATH` makes the role
  resolve, which is also what consumer short-name resolution needs.

Both must be fixed in the substrate scenarios before molecule can be a
gate, and the fix is a prerequisite, not an afterthought.

## Why this belongs in Common-Ansible

Molecule is Ansible-domain tooling, and unlike the dockerised
`ansible-lint` composite it cannot be a tech-agnostic black box: it drags
`ansible-core`, `molecule`, `molecule-plugins[docker]`, the pinned Galaxy
collections, the role source under test, and the Docker driver (running
molecule inside a container means docker-in-docker). Placing it in
Common-Automation would pull an entire language ecosystem into a repo
whose charter is to carry none ("outside any single language ecosystem
... without dragging tooling along").

Common-Ansible already owns exactly that toolchain - the controller venv,
`ansible-core`, the collection pins. The molecule CI workflow reusing
that controller is domain-correct and co-located with the thing it
needs. This mirrors [feature 20](../20-ansible-lint-ci-in-common-ansible/problem.md):
Ansible-domain CI is owned by the Ansible repo; Common-Automation stays
tech-agnostic.

## Solution approach

### Off-the-shelf survey - the test framework

| Option | Source / license | Fit | Notes |
| --- | --- | --- | --- |
| **molecule** + `molecule-plugins[docker]` | OSS, MIT, Ansible community | Purpose-built for role converge/idempotence/verify against a container; scenarios already authored | Keep - already adopted |
| `ansible-test` | OSS, GPL-3.0 | Built for collection sanity/integration, not standalone role scenario lifecycles | Wrong granularity |
| Testinfra / goss alone | OSS | Assertion layer only; no converge/idempotence lifecycle or driver management | Already available as molecule's verifier; not a replacement |
| Bare `ansible-playbook` + manual asserts | In-repo | Reinvents create/converge/idempotence/destroy orchestration | Rejected |

Decision: keep molecule; the scenarios exist and only need repair, not
replacement.

### Off-the-shelf survey - the target image / python fix

| Option | Fit | Notes |
| --- | --- | --- |
| `pre_build_image: false` (let molecule build a python-bearing image) | Molecule's standard fix; installs python into the build | Adds a build step per scenario |
| Pre-baked ansible-ready image (e.g. a `*-ansible` base) | Python + systemd present out of the box | New external image dependency to pin/trust |
| `prepare.yml` installs python via raw module | Keeps the bare image | Per-scenario prepare boilerplate |

The concrete choice is a plan-step decision; the requirement is only that
converge runs green on a clean container.

### Off-the-shelf survey - the CI host

| Option | Fit | Notes |
| --- | --- | --- |
| GitHub-hosted `ubuntu-latest` | Docker preinstalled; simplest | Default; chosen unless a repo overrides |
| Self-hosted runner | Needs the Docker daemon (feature 19 section 8) and tolerates docker-in-docker | Available via the same runner-selection variable `ci-yaml` uses |

### Chosen direction: fix the scenarios, add a reusable molecule workflow in Common-Ansible

Repair the substrate `molecule.yml` scenarios so converge runs green
(python on the target, robust roles path), then add molecule as a second
job in the `ci-ansible.yml` workflow feature 20 creates. The molecule job
is **path-gated** (only when `roles/**` or `Tests/molecule/**` change),
runs a **matrix** over `Tests/molecule/<role>/<scenario>/`, selects its
runner the same way `ci-yaml` does (input then variable then
`ubuntu-latest`), and reuses feature 20's Common-Ansible substrate
sibling checkout to put both the consumer's and the substrate's `roles/`
on `ANSIBLE_ROLES_PATH` so short-name roles resolve. Consumed by
Common-Ansible and the role-owning consumers (Infrastructure-Vm-Users,
Infrastructure-GitHubRunners).

## Relationship to feature 20

[Feature 20](../20-ansible-lint-ci-in-common-ansible/problem.md)
(ansible-lint) and this feature both move Ansible-domain CI into
Common-Ansible and both need the same substrate-sibling
`ANSIBLE_ROLES_PATH` wiring for short-name role resolution. Decided: the
two share **one** reusable workflow, `ci-ansible.yml`. Feature 20
establishes it (ansible-lint first, lighter, no container run) and lands
the shared sibling-checkout wiring; this feature adds molecule to the
same `ci-ansible.yml` as a second job, gated by path filter to the
role/scenario surfaces so it only runs when a role or scenario changes
(ansible-lint stays unconditional, auto-skipping when no Ansible content
exists). The sibling-checkout wiring is reused from feature 20, not
duplicated. ansible-lint first, molecule second.

## Constraints

- Master-only branches across all affected repos.
- Molecule scenarios stay with the role they test (substrate scenarios in
  Common-Ansible; consumer scenarios in the consumer repo); only the
  reusable workflow is centralised.
- The substrate-sibling `ANSIBLE_ROLES_PATH` wiring is single-sourced and
  shared with feature 20, not duplicated.
- Container cost is contained by path-gating and per-scenario matrix
  parallelism; the gate must not run on PRs that touch no role/scenario.
- README sections are earned per step and kept in the structured index.
- ASCII only; prose and comments wrap at the repo's column conventions.

## Risks and sequencing

- The scenarios currently fail converge, so the first green run is itself
  a deliverable; the image/python and roles-path fixes are prerequisites
  sequenced before the workflow is wired as a required check.
- Docker-in-docker on self-hosted runners is fragile; defaulting to the
  GitHub-hosted runner (Docker preinstalled) avoids it, with the
  runner-selection variable left as the override.
- Making molecule a required check while a scenario is flaky would block
  merges; the plan introduces it as non-blocking until proven green
  across all role scenarios, then promotes it.
- Consumer scenarios depend on the substrate sibling checkout; an
  ordering gap (substrate not yet on `master`) breaks short-name
  resolution, the same cross-repo ordering feature 19's Section 10 and
  feature 20 manage.

## Out of scope

- Authoring new molecule scenarios for roles that lack them (this feature
  runs and repairs the existing scenarios; coverage expansion is separate).
- The ansible-lint gate - that is
  [feature 20](../20-ansible-lint-ci-in-common-ansible/problem.md).
- Any change to Common-Automation's cross-cutting linters or their home.
- Replacing molecule or its docker driver.
