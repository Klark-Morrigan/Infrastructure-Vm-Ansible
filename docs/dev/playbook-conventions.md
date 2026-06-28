# Playbook conventions

Shared rationale for the operator-facing playbooks under `playbooks/`
([register-runners.yml](../../playbooks/register-runners.yml) and
[deregister-runners.yml](../../playbooks/deregister-runners.yml)). Each
playbook's header keeps only its per-playbook rationale (role order, what
it reconciles) and points here for the shared posture.

## Index

- [`hosts: vm_provisioner_hosts`](#hosts-vm_provisioner_hosts)
- [`gather_facts: true`](#gather_facts-true)
- [`any_errors_fatal: false`](#any_errors_fatal-false)
- [Tags mirror role names](#tags-mirror-role-names)
- [`acl` prerequisite for unprivileged become](#acl-prerequisite-for-unprivileged-become)
- [Role order lives in the playbook, not meta deps](#role-order-lives-in-the-playbook-not-meta-deps)

## `hosts: vm_provisioner_hosts`

The bash bridge (`ops/virtual-machines/_build-inventory.sh`) drops every host the
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
than silently mis-reconcile. The deregister direction is symmetric:
each remove-path role guards its own state (e.g. a missing service unit
is treated as already-removed) rather than assuming a sibling ran first.

## `acl` prerequisite for unprivileged become

The runner playbooks ([register-runners.yml](../../playbooks/register-runners.yml)
and [deregister-runners.yml](../../playbooks/deregister-runners.yml)) drive
roles that become an unprivileged service user: `runner_binary` downloads
the tarball as the runner user, and `runner_registration` runs `config.sh`
as the runner user (the actions/runner refuses to configure as root). When
Ansible becomes an unprivileged user from a non-root SSH login it grants
that user access to its temporary files via `setfacl`, which lives in the
`acl` package. A minimal Ubuntu install omits it; without it Ansible falls
back to an NFSv4-style `chmod A+user:<user>:rx:allow` that GNU coreutils
rejects, and every unprivileged-become task fails with "Failed to set
permissions on the temporary files Ansible needs to create when becoming an
unprivileged user".

Both per-VM plays therefore run a `pre_tasks` step
([tasks/_ensure-acl-present.yml](../../playbooks/tasks/_ensure-acl-present.yml))
that installs `acl`. It carries `tags: always` so it survives a narrowed
`--tags <role-name>` run - unlike the roles themselves, which deliberately
do not coordinate across tag scopes (see above), this prerequisite must
run whenever any of them does.

This only matters in production, where the SSH connection user is the
unprivileged deploy user. The molecule scenarios connect as root
(`ansible_user: root`), so Ansible chmods the temp files directly and skips
ACLs - which is why they pass without the package and cannot catch its
absence.

## Role order lives in the playbook, not meta deps

The play-level role list (or sequence of `import_role` tasks) is the
single source of truth for which roles run in which order. Roles'
`meta/main.yml` files intentionally do **not** carry inter-role
dependencies in either direction.

Reason: Ansible's meta dependencies always run the dep's
`tasks/main.yml` and ignore the entry role's `tasks_from` selector.
A meta dep like `runner_service -> runner_registration` in the register
direction would silently re-register a runner mid-teardown when the
deregister playbook imports `runner_service` with `tasks_from: remove`.

The only meta deps the roles do carry are direction-neutral helpers
(`runner_entry_resolve`) that set shared facts but do not own
playbook-level ordering.
