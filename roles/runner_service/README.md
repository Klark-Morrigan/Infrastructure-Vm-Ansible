# Role: runner_service

Reconciles the systemd service for a self-hosted GitHub Actions runner.
Third role applied by
[`playbooks/register-runners.yml`](../../playbooks/register-runners.yml)
(once that playbook lands in step 6); runs after
[`runner_registration`](../runner_registration/README.md) (which lays
`config.sh` + `.runner` on disk - both are required for `svc.sh install`
to succeed) and is the last step before the runner reports online to
GitHub.

## Index

- [Var contract](#var-contract)
- [Register direction](#register-direction)
- [Idempotence guarantees](#idempotence-guarantees)
- [Tests](#tests)
- [Rationale](#rationale)

## Var contract

The role reads one extra-var:

- `github_runners_config` - the verbatim `GitHubRunnersConfig-<Suffix>`
  JSON array. The host slice is derived by the
  [`runner_entry_resolve`](../runner_entry_resolve/README.md) meta
  dependency into the shared `vm_runner_entries` fact. Per-entry
  shape consumed by this role:

  ```yaml
  vmName: ubuntu-01-ci             # selector (matched on host)
  runnerName: ubuntu-01-ci-a       # also the dir name and unit suffix
  runnerUsername: u-actions-runner # passed to svc.sh install as the
                                   # service user
  ```

  Other entry fields (`deployUsername`, `githubUrl`, `runnerLabels`,
  `ipAddress`) are consumed by other roles, not by this role.

The role expects `/opt/runners/<runnerName>/` to already contain a
functional actions/runner extraction (laid by `runner_binary`) plus a
registered `.runner` marker (laid by `runner_registration`). It does
not validate either - the corresponding modules would surface a clear
error if `svc.sh` were absent or `config.sh --unattended` had not
already run.

## Register direction

For every entry in `vm_runner_entries`, the role drives four phases:

1. **Unit probe.** `systemctl list-unit-files --no-legend
   'actions.runner.*<runnerName>.service'` piped through
   `awk '{print $1}' | head -n1`. Captures the matching unit name on
   stdout (or empty if no unit is installed yet). The glob filters by
   the `runnerName` suffix only - parsing `<owner>-<repo>` out of
   `githubUrl` to pin the prefix would just duplicate work the next
   probe and the systemd module both no-op when the unit is correctly
   named.
2. **`svc.sh install` (when the probe stdout is empty).** Runs as root
   via `become: true` because `svc.sh` writes the unit file under
   `/etc/systemd/system`. The runner service user owns the runner
   directory tree (`runner_binary`'s ownership posture) so `svc.sh`
   itself is owner-readable; only the unit-file write needs root.
   Argument: the entry's `runnerUsername`, which `svc.sh` bakes into
   the unit's `User=` line.
3. **Enable + start.** `ansible.builtin.systemd` with `state: started`,
   `enabled: true`. A second probe runs between the install branch and
   this task so the unit name is in scope on both code paths
   (already-installed and just-installed).
4. **`systemctl is-active` re-check.** One `command` per entry capturing
   stdout (with `failed_when: false`), followed by an `assert` per
   entry checking `stdout == 'active'`. The split exists so the failure
   message can name the unit and point at
   `journalctl -u <unit> --no-pager -n 200` instead of surfacing a raw
   non-zero `rc` from the command itself.

The is-active re-check mirrors the existing `Test-RunnerServiceActive`
in the PowerShell flow: `ansible.builtin.systemd` reports `started`
even when the unit went active then immediately crashed (the module
observes the start transition only), so the explicit re-check is the
contract that catches a service that fails its first work cycle.

## Idempotence guarantees

- Re-running with the same `vm_runner_entries` and a healthy fleet
  (every unit installed, enabled, started, and active) reports
  `changed: 0` across the role - the probe and re-probe tasks are
  `changed_when: false`, the install branch's `when` skips because the
  probe stdout is non-empty, the systemd task reports `ok` for
  already-enabled+started units, and the is-active capture is also
  `changed_when: false`.
- The role never stops, disables, or removes a unit. Tearing a
  registered runner down is the deregister flow's job (feature 09's
  `remove` direction on this role).
- A new entry added to `vm_runner_entries` between runs reconciles only
  the new entry; existing healthy entries skip the install branch and
  the systemd task reports `ok`.

## Tests

[`Tests/molecule/runner_service/default/`](../../Tests/molecule/runner_service/default/)
exercises the role inside a systemd-enabled Ubuntu 24.04 container:

- **Install branch.** Entry with `/opt/runners/<name>/` pre-seeded but
  no installed unit - `svc.sh install` runs, the unit becomes active,
  the is-active re-check passes.
- **Already-installed + active.** Entry with the unit already
  enabled+started - the install branch skips, the systemd task reports
  `changed: 0`, the re-check passes.
- **Already-installed + stopped.** Entry with the unit enabled but
  stopped - the install branch skips, the systemd task starts the
  service, the re-check passes.
- **Re-converge.** A second pass against the post-converge state
  reports `changed: 0` across every task in the role.
- **Selector negative.** An entry on a different `vmName` does not
  leak onto the host under test (covered transitively by the
  [`runner_entry_resolve`](../runner_entry_resolve/README.md)
  scenario; the runner_service scenario also asserts no
  `actions.runner.*leak*.service` exists after converge).

The container runs `systemd` as PID 1 (the prepare step installs the
package if the image flavour ships without it) so the `systemd`
module, `systemctl list-unit-files`, and `systemctl is-active` all
behave as they would on a real VM. A stub `svc.sh` in each runner
directory writes a `Type=oneshot RemainAfterExit=yes` unit with
`ExecStart=/bin/true` - active without a long-lived process, which is
all the role's reconcile contract observes.

## Rationale

Three roles instead of one keeps each external surface in its own
file: this role owns the systemd surface end-to-end, `runner_binary`
owns the file-server / unarchive surface, `runner_registration` owns
the GitHub API surface. A molecule scenario for any one of them can
stub the others' surfaces without dragging the full register flow
into fixture territory.

The two-probe shape (probe, install-when-empty, re-probe, then
enable+start) is more verbose than threading the install-branch's
output into a Jinja conditional but is also more obvious: a reader
sees that the systemd task has the unit name regardless of whether
the install branch fired, and the re-probe cost is trivial against
the install cost. Mirrors the same "stat then act" idiom
`runner_binary` uses for its cache + extract guards.

Splitting the is-active capture and the assert (rather than using
`failed_when: stdout != 'active'` on a single task) is what lets the
failure message render
`journalctl -u <unit> --no-pager -n 200` with the unit name
substituted. A bare `failed_when` would surface the command's
`rc != 0` with no operator hint; the explicit assert keeps the
debugging path one line away from the failure.
