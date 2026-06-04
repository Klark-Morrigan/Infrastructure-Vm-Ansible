#!/usr/bin/env bash
# Sourced helper. Exports the ANSIBLE_* env vars that mirror every
# setting in the repo's ansible.cfg, so every Ansible-family
# invocation in the repo behaves as the cfg dictates - even though
# Ansible itself refuses to load that cfg.
#
# Why this is necessary - the world-writable trap:
#
# The repo lives on a /mnt/c drvfs mount. Windows ACLs do not map to
# Linux mode bits; drvfs surfaces every file as mode 0777. Ansible's
# config loader treats a world-writable directory containing
# ansible.cfg as a config-injection risk and *silently ignores* the
# cfg, falling back to compiled-in defaults. The fallback flips
# host_key_checking from False to True (breaking SSH to fresh VMs at
# the first connection), drops interpreter_python=auto_silent (extra
# per-host warnings), and resets roles_path to its defaults (so
# `roles: [{ role: groups }]` in playbooks/create-users.yml fails
# with "role 'groups' was not found" because Ansible only looks
# under playbooks/roles/, ~/.ansible/roles/, etc. - never under the
# repo-root roles/ directory where this project keeps them).
#
# Three things to know about the workaround:
#
# 1. `ANSIBLE_CONFIG=<path>` does NOT bypass the check. The safety
#    check applies to the directory containing the cfg, not just the
#    discovery process. Pointing the env var at /mnt/c/.../ansible.cfg
#    triggers the same "ignoring it as an ansible.cfg source" warning
#    and Ansible still loads compiled-in defaults.
#
# 2. There is no public Ansible flag to suppress the check. Internal
#    `_enable_dangerous_config` is not exposed via env var or CLI.
#
# 3. ANSIBLE_<NAME> env vars are honoured *unconditionally* - they
#    bypass the cfg loader entirely. Setting them directly is the
#    only path that survives the drvfs mount.
#
# Consequence: every setting in ../ansible.cfg has a matching export
# below. ansible.cfg is retained as the human-readable documentation
# of intent (and a fallback for any tool that happens to find it on
# a non-drvfs path); this helper is what the bridge and bootstrap
# actually consume. Keep the two in lockstep - a future cfg tweak
# must come with a matching export here, and vice versa.
#
# Why a separate sourced helper - both the bootstrap stage
# (_bootstrap-controller-wsl.sh) and the per-playbook bridge
# (_run-playbook.sh) need the same exports. Keeping the rationale
# and the cfg-mirror in one file means a future tweak touches one
# place; consumers `source` this and move on.
#
# Contract: caller must have set `repo_root` to the repo's root
# directory (absolute path) before sourcing this file. The `:?` test
# below fails with a clear error if it has not.

: "${repo_root:?_ansible-env.sh: caller must set 'repo_root' before sourcing}"

# Mirror of ../ansible.cfg [defaults] - one export per cfg key.
# Absolute paths anchored at $repo_root so the values are independent
# of the caller's cwd.

# Mirrors `roles_path = roles`. Repo-local roles live under
# ${repo_root}/roles/, not under playbooks/roles/ - so the default
# search path (<playbook_dir>/roles:~/.ansible/roles:...) misses them.
export ANSIBLE_ROLES_PATH="${repo_root}/roles"

# Mirrors `host_key_checking = False`. VMs are short-lived and their
# IPs come from the VmProvisioner vault, not from user input - there
# is no static known_hosts to compare against and prompting would
# break unattended runs.
export ANSIBLE_HOST_KEY_CHECKING=False

# Mirrors `interpreter_python = auto_silent`. Lets Ansible pick the
# remote Python without printing a per-host warning. Target VMs are
# Ubuntu cloud images where auto_silent resolves cleanly.
export ANSIBLE_PYTHON_INTERPRETER=auto_silent

# Mirrors `retry_files_enabled = False`. Keeps *.retry noise out of
# the repo root. The .gitignore already excludes them, but disabling
# generation entirely is cleaner than relying on the ignore.
export ANSIBLE_RETRY_FILES_ENABLED=False

# Mirrors `ssh_args` from ../ansible.cfg [ssh_connection]. E2E
# provisions fresh VMs at recycled IPs; without
# UserKnownHostsFile=/dev/null, a key recorded on one run breaks
# every subsequent connection at the same IP with "REMOTE HOST
# IDENTIFICATION HAS CHANGED", because StrictHostKeyChecking=no
# silently accepts unknown hosts but still rejects changed ones.
# Pointing the known_hosts file at /dev/null makes every connection
# look like first-contact. -C, ControlMaster, and ControlPersist
# preserve Ansible's upstream defaults (connection multiplexing) so
# we extend rather than replace.
export ANSIBLE_SSH_ARGS="-C -o ControlMaster=auto -o ControlPersist=60s -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
