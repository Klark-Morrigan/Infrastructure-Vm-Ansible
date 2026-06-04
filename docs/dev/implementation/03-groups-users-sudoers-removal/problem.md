# Problem: Remove OS Groups, Users, and Sudoers via Ansible

## Index

- [Context](#context)
- [What Is Changing](#what-is-changing)
  - [Inputs (consumed, not redefined)](#inputs-consumed-not-redefined)
  - [Role: sudoers (remove)](#role-sudoers-remove)
  - [Role: users (remove)](#role-users-remove)
  - [Role: groups (remove)](#role-groups-remove)
  - [Entry point: remove-users playbook](#entry-point-remove-users-playbook)
  - [Operator entry point in this repo](#operator-entry-point-in-this-repo)
  - [Archive Infrastructure-Vm-Users](#archive-infrastructure-vm-users)
- [Why Now](#why-now)
- [Affected Components](#affected-components)
- [Out of Scope](#out-of-scope)
- [Open Questions](#open-questions)

---

## Context

`Infrastructure-Vm-Users/hyper-v/ubuntu/remove-users.ps1` deletes every
declared user and group from each reachable VM. Removal is a deliberate
operator action — Vm-Users does not auto-remove on config drop, because
silently deleting a user when a config entry vanishes is too easy to do
by accident.

Feature 02 of this repo migrated the create/update path to Ansible. This
feature migrates the symmetric removal path. The two are split into
separate features for one reason only: removal is the destructive path,
and bundling it with create would have meant designing destructive
semantics on top of an unproven controller pattern. With feature 02 shipped
and the controller validated, removal can be designed on its own merits.

The vault contract is unchanged. `VmUsersConfig` is still the declared
desired state; running this playbook reinterprets that same config as
"remove the entries listed here," which matches today's
`remove-users.ps1` semantics exactly.

---

## What Is Changing

### Inputs (consumed, not redefined)

Same inputs as feature 02 — inventory derived from `VmProvisionerConfig`,
admin password from the same vault, `VmUsersConfig` parsed into extra-vars.
No new vault entries and no new schema fields.

### Role: sudoers (remove)

Runs **first**, before user removal, so that an interrupted run never
leaves a sudoers file pointing at a user that has been deleted (which is
harmless but confusing).

| Decision | Value |
|----------|-------|
| Module | `ansible.builtin.file` with `state: absent` |
| Target | `/etc/sudoers.d/{username}` for every declared user |
| Absence | Not an error (matches today). |

### Role: users (remove)

Runs second.

| Decision | Value |
|----------|-------|
| Module | `ansible.builtin.user` with `state: absent`, `remove: yes` |
| Effect | Equivalent to `userdel -r` — deletes the account and its home directory. |
| Implicit primary group | Removed automatically by `userdel` when the group has the same name as the user and no remaining members. |
| Absence | Not an error. |

### Role: groups (remove)

Runs **last**, after all declared users for the VM are gone.

| Decision | Value |
|----------|-------|
| Module | `ansible.builtin.group` with `state: absent` |
| Non-empty group | When a group still has members (e.g. a user not in this config joined it), the group is **skipped with a warning**, not forcibly removed. Matches today's "warned and skipped rather than forcing deletion" guarantee — protects against deleting a group an operator added by hand. |
| Absence | Not an error. |

The non-empty-group skip is the only piece in this feature that requires
glue beyond a stock module call: a small pre-check task (`getent group X`,
then conditional skip) wraps the `group: state=absent` invocation. The
glue lives in `roles/groups` (extending the role from feature 02) rather
than in a separate role, so groups logic stays in one place.

### Entry point: remove-users playbook

`playbooks/remove-users.yml` imports the roles in order:
`sudoers (remove)` -> `users (remove)` -> `groups (remove)`.

The reversal vs. feature 02's create order (groups, users, sudoers) is
deliberate: dependency direction is opposite for teardown — sudoers files
reference users, users reference groups, so each layer is removed only
after its dependents are gone.

Hosts that are unreachable are skipped with a warning, not a failure —
same posture as feature 02.

### Operator entry point in this repo

Same pattern as feature 02 — bash entry point, no PowerShell wrapper:

| New script | Lang | Purpose |
|------------|------|---------|
| `scripts/remove-users.sh` | bash | One-line wrapper invoking `./scripts/run-playbook.sh playbooks/remove-users.yml`. Operators run it from inside WSL, or from Windows as `wsl ./scripts/remove-users.sh`. |

`Infrastructure-Vm-Users` is **not modified** while this feature is in
development — its `remove-users.ps1` keeps working in parallel, available
as a fallback during validation.

A confirmation prompt is **not** added. Today's `remove-users.ps1` does
not prompt either, and the destructive intent is already in the script
name and the operator's choice to invoke it.

### Archive Infrastructure-Vm-Users

This is the final step of feature 03 and happens **after** the new
removal path is validated. Up to this point Vm-Users has been completely
untouched by the migration; both create and remove paths exist twice (in
Vm-Users and in this repo) and operators can validate the new ones
against the old ones.

The archive step is a one-shot:

1. Final commit on `Infrastructure-Vm-Users`: README replaced by a pointer
   to `Infrastructure-VM-Ansible` and the relevant feature folders. The
   PowerShell scripts are left in the final commit, not deleted — they
   remain readable in the archived repo as historical reference.
2. Archive the repo on GitHub. History, issues, and PRs are preserved;
   the URL still resolves.

After this, the only repos in the migration set still active are
`Infrastructure-VM-Ansible` (new home), `Infrastructure-Vm-Provisioner`
(unchanged so far), and `Infrastructure-GitHubRunners` (a later
migration target).

---

## Why Now

- Feature 02 validated the controller pattern against the create path;
  removal can now be built on a proven foundation rather than co-designed
  with it.
- The PowerShell removal script duplicates roughly the same surface as the
  create script (one path per resource), so the deletion of imperative
  PowerShell yields a comparable simplification.
- Symmetric coverage matters before Infrastructure-Vm-Users can be
  archived. Leaving removal in PowerShell while create is in Ansible would
  mean Vm-Users has to live forever; archiving requires both paths covered
  by the new repo.

---

## Affected Components

```mermaid
graph TD
    subgraph Vaults ["Vaults (unchanged)"]
        PV["VmProvisioner vault"]
        UV["VmUsers vault"]
    end

    subgraph Entry ["Infrastructure-VM-Ansible operator entry (new, this feature)"]
        SH["scripts/remove-users.sh\n(bash, calls bridge)"]
    end

    subgraph Bridge ["Infrastructure-VM-Ansible substrate (built in feature 02, consumed here)"]
        BR["bash bridge + jq-generated inventory"]
    end

    subgraph Roles ["Infrastructure-VM-Ansible feature 03 (new)"]
        SR["roles/sudoers (remove)"]
        UR["roles/users (remove)"]
        GR["roles/groups (remove)\n+ non-empty-group skip"]
        PB["playbooks/remove-users.yml"]
    end

    subgraph Guest ["VM"]
        OS["/etc/sudoers.d/*, /etc/passwd,\n/etc/group, /home/*"]
    end

    PV -.->|"read at runtime"| BR
    UV -.->|"read at runtime"| BR
    SH --> BR
    BR --> PB
    PB --> SR
    PB --> UR
    PB --> GR
    SR --> OS
    UR --> OS
    GR --> OS
```

Sequence with one group still in use by an out-of-config user:

```mermaid
sequenceDiagram
    participant Op as Operator
    participant Sh as remove-users.sh
    participant Br as run-playbook.sh
    participant Ans as ansible-playbook
    participant Vm as VM

    Op->>Sh: wsl ./scripts/remove-users.sh
    Sh->>Br: run-playbook.sh remove-users.yml
    Br->>Ans: ansible-playbook ... --extra-vars @file
    Ans->>Vm: sudoers absent: ok (already gone)
    Ans->>Vm: user u-actions-runner: userdel -r
    Ans->>Vm: user u-runner-deploy: userdel -r
    Ans->>Vm: group u-actions-runner: getent shows out-of-config member
    Ans->>Vm: skip with warning (group kept)
    Ans-->>Br: exit 0 (warning recorded)
    Br-->>Sh: exit 0
    Sh-->>Op: exit 0
```

---

## Out of Scope

- **Removing users that are no longer in `VmUsersConfig` but still exist
  on the VM.** That is "drift removal" and is a different posture from
  "remove what is declared here." Vm-Users has deliberately never done
  this, and the rationale survives the migration — silently deleting a
  user just because its config entry was edited out is too dangerous.
  Operators who want a user gone declare it in config and run
  `remove-users.yml`.
- **Home-directory backup before deletion.** `userdel -r` deletes the
  home dir. Operators who want a backup do it before invoking removal.
- **Force-removing a non-empty group.** The skip-with-warning behaviour
  is the contract. A future `--force` flag would be additive and is not
  needed for this feature.
- **A confirmation prompt in the entry point.** Out of scope by design —
  see the entry point section above.
- **Migrating Infrastructure-GitHubRunners.** That repo continues to read
  `VmUsersConfig` from the `VmUsers` vault as before; this feature does
  not change the vault or the consumer. The runners migration is its own
  later feature.

---

## Open Questions

1. Should the non-empty-group skip log the names of the unexpected
   members, or just the count? Names are more useful for operators
   diagnosing why a group survived; counts are quieter. Current
   proposal: log the names (small list, high diagnostic value).
2. Should removal of a user that owns running processes (rare for the
   service accounts this repo manages, but possible) attempt to kill
   them first, or fail loudly? `userdel` with `-r` will refuse if the
   user is logged in or has running processes; today's PowerShell
   behaviour is to surface the error and continue with the next user.
   Current proposal: preserve that — fail one user, continue the rest,
   non-zero exit at the end.
3. Should `remove-users.yml` accept a `--limit` / `--tags` shape that
   removes only sudoers (leaving the user) or only the user (leaving
   sudoers)? Useful for partial rollback during a failed deploy.
   Current proposal: defer — the create/remove split already covers
   the common cases, and partial-removal use cases are speculative.
