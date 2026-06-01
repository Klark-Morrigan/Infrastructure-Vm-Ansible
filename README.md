# Infrastructure-VM-Ansible

Ansible controller repo for reconciling OS groups, users, and sudoers on
provisioned VMs. Invoked from Windows via a PowerShell -> WSL bridge that
reads configuration from PowerShell SecretManagement vaults and dispatches
to `ansible-playbook` inside a Linux venv.

This stub is filled out properly in
[step 10](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md#step-10---readme-and-per-step-docs)
of the current feature. Design history and rationale live under
[docs/dev/implementation/](docs/dev/implementation/).

## Index

- [Current feature: 02 - groups, users, sudoers creation](docs/dev/implementation/02-groups-users-sudoers-creation/)
  - [Problem](docs/dev/implementation/02-groups-users-sudoers-creation/problem.md)
  - [Plan](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md)
