#!/usr/bin/env bash
# Sourced library. Provides the `ensure_apt_command` helper used by the
# WSL-side bootstrap to lift a bare presence check into a presence-or-
# install gate. Lives as its own file so multiple bootstrap stages (and
# future operator entries that need the same shape) reuse one
# implementation instead of repeating the apt dance.
#
# Sourced, not executed - the helper exits the caller's process on
# failure, which is the desired fail-fast behaviour from inside a
# bootstrap pipeline.

# ensure_apt_command <cmd> <pkg> [pkg...]
#
# Idempotent presence-or-install gate. If <cmd> is already on PATH,
# no-op. Otherwise attempt a single
# `sudo apt-get update && sudo apt-get install -y <pkgs>` and re-check;
# if either prerequisite (sudo, apt-get) is absent or the install
# itself fails, print the fix-it hint and exit 1. Apt retries and
# network resilience are the operator's call (rerun the bootstrap),
# not this helper's.
ensure_apt_command() {
    local cmd="$1"
    shift
    local pkgs=("$@")

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        if sudo apt-get update && sudo apt-get install -y "${pkgs[@]}"; then
            hash -r  # drop bash's command lookup cache so the re-check sees the new binary
            if command -v "$cmd" >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    echo "$cmd not found in WSL. Install it with: sudo apt-get update && sudo apt-get install -y ${pkgs[*]}" >&2
    exit 1
}
