# Problem: Consolidate ansible-lint CI into Common-Ansible

## Index

- [Summary](#summary)
- [For laymen](#for-laymen)
- [Background](#background)
- [What is changing](#what-is-changing)
- [Why this belongs in Common-Ansible](#why-this-belongs-in-common-ansible)
- [Solution approach](#solution-approach)
- [Relationship to feature 21](#relationship-to-feature-21)
- [Constraints](#constraints)
- [Risks and sequencing](#risks-and-sequencing)
- [Out of scope](#out-of-scope)

## Summary

`ansible-lint` runs today as a composite action in **Common-Automation**
(`.github/actions/ansible-lint`), invoked as the last step of the
reusable `ci-yaml.yml` workflow that every repo delegates to. But
ansible-lint targets a single-ecosystem surface - `playbooks/`,
`roles/`, `ansible.cfg` - that only the Ansible repos have. Common-
Automation's stated charter is the opposite: "Shared, tech-agnostic
GitHub Actions composite actions and reusable workflows ... outside any
single language ecosystem ... without dragging tooling along." An
Ansible-specific gate baked into the universal YAML workflow is a domain
leak: every PowerShell, .NET, and bash repo carries an Ansible step it
can never use, and the Ansible domain's CI lives apart from the Ansible
controller repo that owns the Ansible toolchain.

This feature moves the ansible-lint gate out of Common-Automation's
`ci-yaml.yml` into a reusable workflow owned by **Common-Ansible** (the
Ansible controller repo), consumed only by repos that actually contain
Ansible content. Common-Automation keeps only the cross-cutting linters
that nearly every repo has.

## For laymen

Think of Common-Automation as a shared toolbox every team borrows from -
but it is meant to hold only tools everyone uses (spell-checkers for
config files, that sort of thing). One Ansible-only tool got left in
that shared toolbox, so every team sees it even though only the Ansible
teams can use it. It quietly does nothing for the others, but it does not
belong there. This change moves that Ansible-only tool into the Ansible
team's own toolbox, where it lives next to the rest of the Ansible
machinery. Nothing about how Ansible code is checked changes - only where
the check is defined and who picks it up.

## Background

- Common-Automation hosts the org's reusable CI: the composite actions
  (`shellcheck-bash`, `yamllint`, `actionlint`, `action-validator`,
  `ansible-lint`, `test-bats`, ...) and the two reusable workflows
  `ci-yaml.yml` and `ci-bash.yml`. Its README opens by declaring it
  tech-agnostic and consumable by PowerShell, .NET, and future stacks
  without dragging tooling along.
- `ci-yaml.yml` runs four linters as sequential steps of one job:
  `yamllint`, `actionlint`, `action-validator`, then `ansible-lint`.
  Every consumer repo's thin `ci-yaml.yml` delegates to it with
  `uses: Klark-Morrigan/Common-Automation/.github/workflows/ci-yaml.yml@master`.
- The ansible-lint composite auto-skips when a repo has no `playbooks/`,
  `roles/`, or `ansible.cfg`, so at a non-Ansible repo it is a no-op
  skipped step, not wasted linting. It runs in its own pinned Docker
  image, so it drags no Ansible toolchain into Common-Automation's
  runtime.
- The remaining `ci-yaml` linters target surfaces nearly every repo has:
  `yamllint` (any YAML), `actionlint` / `action-validator` (GitHub
  Actions YAML). Those are genuinely cross-cutting; ansible-lint is the
  only step whose surface is single-ecosystem.
- Common-Ansible is "the Ansible controller repo": it already owns the
  Linux venv, `ansible-core`, the pinned Galaxy collections
  (`requirements.yml`), and the controller bootstrap. It is the home of
  the Ansible domain.

## What is changing

1. A new reusable workflow in Common-Ansible, `ci-ansible.yml`, carries
   the ansible-lint gate. This feature creates that workflow with
   ansible-lint as its first gate; [feature 21](../21-molecule-ci-in-common-ansible/problem.md)
   then adds `molecule` to the same `ci-ansible.yml` as a second,
   path-gated job. One Ansible-domain workflow, ansible-lint first,
   molecule second (see [Relationship to feature 21](#relationship-to-feature-21)).
2. The ansible-lint step is removed from Common-Automation's `ci-yaml.yml`,
   and the `ansible-lint` composite action is relocated (or re-homed) to
   Common-Ansible. Common-Automation is left with only the cross-cutting
   linters.
3. Every Ansible consumer repo (Common-Ansible itself,
   Infrastructure-Vm-Users, Infrastructure-GitHubRunners) is rewired: its
   thin workflow stops getting ansible-lint from `ci-yaml.yml` and starts
   consuming Common-Ansible's Ansible-domain workflow.
4. Non-Ansible repos simply stop carrying the (skipped) Ansible step.

## Why this belongs in Common-Ansible

The estate's two repo prefixes carry distinct meanings (see feature 19's
[Why Common-, not Infrastructure-](../19-common-ansible-extraction-and-toolchain-provisioning/problem.md#why-common--not-infrastructure)):
`Common-*` is reusable substrate, and within that, each Common- repo owns
one domain - Common-Automation owns tech-agnostic CI, Common-PowerShell
owns shared cmdlets, Common-Ansible owns the Ansible substrate.

ansible-lint is Ansible-domain tooling. Its correct owner is the repo
that owns the Ansible domain, which is Common-Ansible. It currently sits
in Common-Automation only because a dockerised, auto-skipping composite
is cheap to leave in the universal workflow - an ergonomic accident, not
a domain decision. The cross-cutting linters (`yamllint`, `actionlint`,
`action-validator`, `shellcheck`) stay in Common-Automation because their
surfaces are not tied to any one ecosystem; ansible-lint is the lone
exception, and this feature corrects it.

## Solution approach

### Off-the-shelf survey - the linter

The tool itself is not in question; the survey is recorded for
completeness.

| Option | Source / license | Fit | Notes |
| --- | --- | --- | --- |
| **ansible-lint** | OSS, GPL-3.0, Ansible community | The de-facto linter for playbooks/roles/ansible.cfg; production-profile gate already in use here | Keep - already adopted, no reason to switch |
| `yamllint` alone | OSS, GPL-3.0 | Catches YAML style only, none of the Ansible semantics (module misuse, deprecations, role-name rules) | Insufficient on its own; already retained for generic YAML |
| Custom rules | In-repo | Reinvents a mature ruleset | Rejected |

Decision: keep ansible-lint as the tool. The feature is about its
**placement**, not its replacement.

### Off-the-shelf survey - the placement

| Option | Fit | Cost | Notes |
| --- | --- | --- | --- |
| Status quo (Common-Automation `ci-yaml`) | Works mechanically via auto-skip | Domain leak: Ansible gate in every repo's universal workflow; violates the tech-agnostic charter | Rejected |
| **Reusable workflow in Common-Ansible** | Domain-correct: Ansible CI owned by the Ansible repo; non-Ansible repos drop the step | One extra reusable workflow + one extra PR-check row for Ansible repos; an extra cross-repo `uses:` | Chosen |
| Inline ansible-lint per Ansible repo | Removes the shared dependency | Re-duplicates the ruleset/pins across three repos; drift | Rejected - violates single-source-of-truth |

### Chosen direction: relocate ansible-lint to a Common-Ansible reusable workflow

ansible-lint moves into a reusable workflow owned by Common-Ansible and
consumed only by repos with Ansible content. The pinned ruleset stays
single-sourced (now in Common-Ansible), so the three Ansible repos share
one definition rather than forking it. Whether the relocated gate runs in
the controller venv (matching how the `lint-ansible` local skill runs it)
or keeps the dockerised composite is a plan-step decision; either way the
workflow's owner is Common-Ansible. Common-Automation is left strictly
tech-agnostic.

## Relationship to feature 21

This feature and [feature 21](../21-molecule-ci-in-common-ansible/problem.md)
(molecule CI) are companions: both move Ansible-domain CI into
Common-Ansible for the same charter reason, and both need the same
substrate-sibling wiring so a consumer's playbooks/roles resolve the
Common-Ansible substrate roles by short name in CI (the consumer repo
checks out Common-Ansible alongside and puts its `roles/` on
`ANSIBLE_ROLES_PATH`). Decided: the two share **one** reusable workflow,
`ci-ansible.yml`, not two. Feature 20 (the lighter of the pair - no
container test run) creates `ci-ansible.yml` with ansible-lint as its
first gate and establishes the shared sibling-checkout wiring; feature 21
adds molecule to the same workflow as a second, path-gated job and
supplies its scenario setup. ansible-lint first, molecule second.

## Constraints

- Master-only branches across all affected repos.
- The ansible-lint ruleset/version pins remain single-sourced (no
  per-repo fork); only their owning repo changes.
- Cross-repo blast radius: removing the step from Common-Automation's
  `ci-yaml.yml` and rewiring each Ansible consumer must land in an order
  that never leaves an Ansible repo without ansible-lint coverage on
  `master`.
- README sections are earned per step and kept in the structured index.
- ASCII only; prose and comments wrap at the repo's column conventions.

## Risks and sequencing

- An ordering hazard: if Common-Automation drops the step before the
  consumers consume the new Common-Ansible workflow, those repos lose
  ansible-lint coverage in the gap. The plan sequences the new workflow
  onto Common-Ansible's `master` and rewires consumers before the
  Common-Automation step is removed.
- A consumer that resolves substrate roles by short name will fail lint
  if the sibling checkout / `ANSIBLE_ROLES_PATH` wiring is absent; this is
  the same wiring feature 21 needs and must be shared, not duplicated.
- Removing the step from the shared `ci-yaml.yml` is a change to a
  contract every repo consumes; non-Ansible repos must be confirmed
  unaffected (they only lose a step that always skipped for them).

## Out of scope

- Replacing or reconfiguring the ansible-lint ruleset/profile (this is a
  relocation, not a rule change).
- The molecule CI gate - that is
  [feature 21](../21-molecule-ci-in-common-ansible/problem.md).
- Any change to the cross-cutting linters (`yamllint`, `actionlint`,
  `action-validator`, `shellcheck`) or their home in Common-Automation.
