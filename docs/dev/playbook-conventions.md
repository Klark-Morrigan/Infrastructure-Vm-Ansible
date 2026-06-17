# Playbook conventions

Shared rationale for the operator-facing playbooks under `playbooks/`
([create-users.yml](../../playbooks/create-users.yml),
[remove-users.yml](../../playbooks/remove-users.yml),
[register-runners.yml](../../playbooks/register-runners.yml), and the
deregister-runners playbook landing under feature 09). Each playbook's
header keeps only its per-playbook rationale (role order, what it
reconciles) and points here for the shared posture.

## Index

- [`hosts: vm_provisioner_hosts`](#hosts-vm_provisioner_hosts)
- [`gather_facts: true`](#gather_facts-true)
- [`any_errors_fatal: false`](#any_errors_fatal-false)
- [Tags mirror role names](#tags-mirror-role-names)
- [Role order lives in the playbook, not meta deps](#role-order-lives-in-the-playbook-not-meta-deps)

## `hosts: vm_provisioner_hosts`

The bash bridge (`ops/_build-inventory.sh`) drops every host the
operator's `provisioner.json` declares into this group. Every
operator-facing playbook reconciles every provisioned VM by default;
operators scope down with `-l <vm>` when they want a subset.

## `gather_facts: true`

`ansible.builtin.user`, `ansible.builtin.systemd`, and the runner-role
shell tasks all consult facts (shell / home derivation for the user
module, distribution detection for the systemd module, kernel info for
some command modules). The per-host cost is one extra SSH round-trip
at play start - cheap insurance against fact-absent surprises mid-role.

## `any_errors_fatal: false`

The bridge's inventory can contain several VMs and one host being
temporarily offline should not strand the rest. Per-host failures
still surface in the recap; the play just does not abort the others.
Making this explicit (rather than relying on the Ansible default)
guards against a later edit silently flipping it via a play-level
`error_strategy` override.

## Tags mirror role names

Every `import_role` (or `roles:` entry) carries a `tags:` value equal
to the role name. Operators scope a partial run with
`--tags <role-name>` without having to learn the playbook layout.

Roles do not coordinate across tag scopes - skipping a role on the
register direction (e.g. `--tags runner_binary` only) leaves the next
role's preconditions unsatisfied, and the role will fail loudly rather
than silently mis-reconcile. The remove direction is symmetric:
skipping `users` while running `groups` hits the role's
non-empty-group skip path, which is the intended safety net.

## Role order lives in the playbook, not meta deps

The play-level role list (or sequence of `import_role` tasks) is the
single source of truth for which roles run in which order. Roles'
`meta/main.yml` files intentionally do **not** carry inter-role
dependencies in either direction.

Reason: Ansible's meta dependencies always run the dep's
`tasks/main.yml` and ignore the entry role's `tasks_from` selector.
A meta dep like `sudoers -> users` in the create-direction would
silently re-create users mid-teardown when the remove playbook
imports `sudoers` with `tasks_from: remove`. Symmetric trap for
runner roles vs. feature 09's deregister flow.

The only meta deps the roles do carry are direction-neutral helpers
(`vm_users_entry`, `runner_entry_resolve`) that set shared facts but
do not own playbook-level ordering.
