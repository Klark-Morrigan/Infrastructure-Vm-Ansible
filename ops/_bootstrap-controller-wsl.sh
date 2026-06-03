B#!/usr/bin/env bash
# Second-stage Ansible controller bootstrap. Runs inside WSL.
#
# Idempotent by design: reruns detect an existing venv at the expected
# Python version and skip creation. pip and ansible-galaxy are
# themselves idempotent against the pinned requirements files.
#
# Why a separate bash stage at all: wsl --install only runs from
# Windows; everything below this line is Linux territory and must run
# from inside the WSL distro. Keeping the split explicit avoids the
# fragile pattern of marshalling Linux state through PowerShell.

set -euo pipefail

# Python version the venv is expected to use. Bumping is deliberate;
# kept as a top-of-file constant so the comparison below is the single
# source of truth for the version contract.
readonly EXPECTED_PYTHON_MAJOR_MINOR="3"

# Anchor every path to the repo root so the script works regardless of
# the caller's working directory. Parameter expansion (rather than
# `dirname`) keeps the script working even when PATH is locked down
# enough that external utilities are unreachable, which matters for the
# bats harness that scrubs PATH to exercise the absent-tool branches.
script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

venv_dir="$repo_root/.venv"

# shellcheck source=ops/_ansible-env.sh
source "$script_dir/_ansible-env.sh"

# shellcheck source=ops/_ensure-apt-command.sh
source "$script_dir/_ensure-apt-command.sh"

# ---------------------------------------------------------------------------
# 1. Python availability. python3 plus the ensurepip module are the
#    foundation for everything below - if either is absent, the rest of
#    the bootstrap has nothing to land on.
#
# Two presence checks, not one. Ubuntu 24.04 ships python3 in the base
# image but ships ensurepip *only* via the version-specific
# python3.12-venv package (pulled in by the python3-venv metapackage).
# A single `command -v python3` check returns 0 immediately and never
# installs the venv package; `python3 -m venv --help` also returns 0
# (the venv module itself is in stdlib) - so the only honest probe is
# `python3 -c 'import ensurepip'`, which fails iff python3.X-venv is
# absent.
# ---------------------------------------------------------------------------
ensure_apt_command python3 python3 python3-venv

if ! python3 -c 'import ensurepip' 2>/dev/null; then
    # python3 binary is present but ensurepip is missing. Direct sudo
    # apt-get rather than via ensure_apt_command: the helper probes
    # `command -v <name>`, which only matches PATH-resolvable binaries,
    # not Python modules. python3-venv is a metapackage on Ubuntu and
    # resolves to the right python3.X-venv (e.g. python3.12-venv on
    # Noble); we install both names to cover the case where the
    # metapackage is absent on a minimal image.
    echo "Installing python3-venv (binary alone is not enough; ensurepip missing) ..."
    if ! (command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1); then
        echo "ensurepip missing and sudo/apt-get unavailable. Install it with: sudo apt-get update && sudo apt-get install -y python3-venv" >&2
        exit 1
    fi
    sudo apt-get update
    sudo apt-get install -y python3-venv
    if ! python3 -c 'import ensurepip' 2>/dev/null; then
        echo "python3-venv install completed but ensurepip still missing - inspect apt output above." >&2
        exit 1
    fi
fi

# jq is required by the bash bridge (run-playbook.sh) for vault-payload
# validation and inventory generation. The WSL Ubuntu default image does
# not ship jq, so install-or-hint via the same helper used for python3.
ensure_apt_command jq jq

# ---------------------------------------------------------------------------
# 2. Venv create-or-reuse. The existence check pairs with a version
#    probe so a stale venv (wrong Python major.minor) is recreated
#    rather than silently reused.
# ---------------------------------------------------------------------------
needs_create=1
if [[ -x "$venv_dir/bin/python" ]]; then
    actual_major="$("$venv_dir/bin/python" -c 'import sys; print(sys.version_info[0])')"
    if [[ "$actual_major" == "$EXPECTED_PYTHON_MAJOR_MINOR" ]]; then
        needs_create=0
    fi
fi

if [[ "$needs_create" -eq 1 ]]; then
    echo "Creating Python venv at $venv_dir ..."
    python3 -m venv "$venv_dir"
fi

# ---------------------------------------------------------------------------
# 3. Pip dependencies. --upgrade keeps already-installed packages on
#    their pins (no-op when current) while still picking up changes
#    after a requirements.txt bump.
# ---------------------------------------------------------------------------
"$venv_dir/bin/pip" install --upgrade pip >/dev/null
"$venv_dir/bin/pip" install -r requirements.txt

# ---------------------------------------------------------------------------
# 4. Galaxy collections. --force-with-deps ensures the pinned versions
#    win when an older copy is already cached locally; the install
#    target is the default repo-local collections/ path (gitignored)
#    that ansible-playbook discovers automatically when invoked from
#    the repo root.
# ---------------------------------------------------------------------------
"$venv_dir/bin/ansible-galaxy" collection install -r requirements.yml --force-with-deps

# ---------------------------------------------------------------------------
# 5. pwsh.exe presence. The bash bridge in step 3 invokes pwsh.exe to
#    read secrets from the Windows-side vault, so a controller without
#    it cannot run the playbooks regardless of how green the rest of
#    the bootstrap looks. Fail here, not later.
# ---------------------------------------------------------------------------
if ! command -v pwsh.exe >/dev/null 2>&1; then
    echo "pwsh.exe not reachable from WSL. Install PowerShell 7+ on the Windows host so the vault bridge can read SecretManagement secrets." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Summary - one-line confirmation each, so a successful run shows
#    exactly what got pinned without dumping pip's full freeze output.
# ---------------------------------------------------------------------------
echo ""
echo "Controller bootstrap complete:"
echo "  Python : $("$venv_dir/bin/python" --version)"
echo "  Ansible: $("$venv_dir/bin/ansible" --version | head -n 1)"
echo "  pwsh.exe: reachable"
echo "  jq     : $(jq --version)"
