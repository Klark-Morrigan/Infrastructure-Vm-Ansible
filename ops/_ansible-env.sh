#!/usr/bin/env bash
# Sourced helper. Exports ANSIBLE_CONFIG pointing at the repo-root
# ansible.cfg so every Ansible-family invocation in the repo honours
# the same settings.
#
# Why it exists at all - the world-writable trap:
#
# The repo lives on a /mnt/c drvfs mount. Windows ACLs do not map to
# Linux mode bits; drvfs surfaces every file as mode 0777. Ansible's
# config loader treats a world-writable directory containing
# ansible.cfg as a config-injection risk and *silently ignores* the
# cfg, falling back to defaults. The fallback flips
# host_key_checking=False to True (breaking SSH to fresh VMs at the
# first connection) and drops interpreter_python=auto_silent (extra
# per-host warnings). Operators see a working bootstrap, then a
# baffling mid-playbook SSH hang.
#
# Pointing ANSIBLE_CONFIG at an explicit file path bypasses the
# directory-discovery check: the operator is saying "I trust this
# specific file" rather than letting Ansible search the cwd. The
# settings then apply as written.
#
# Why a separate sourced helper - both the bootstrap stage
# (_bootstrap-controller-wsl.sh) and the per-playbook bridge
# (_run-playbook.sh) need the same export. Keeping the rationale in
# one file means a future tweak (e.g. moving ansible.cfg, or switching
# to a wrapper script) touches one place; consumers `source` this and
# move on.
#
# Contract: caller must have set `repo_root` to the repo's root
# directory (absolute path) before sourcing this file. The `:?` test
# below fails with a clear error if it has not.

: "${repo_root:?_ansible-env.sh: caller must set 'repo_root' before sourcing}"
export ANSIBLE_CONFIG="${repo_root}/ansible.cfg"
