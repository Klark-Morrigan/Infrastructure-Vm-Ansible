#!/usr/bin/env bash
# Do not run directly. Dot-sourced by register-runners.sh and
# deregister-runners.sh (after imports/_log.sh, on which it depends for
# log_err). Defines require_gh_token; no top-level side effects.

# ---------------------------------------------------------------------------
# require_gh_token
#   Ensures GH_TOKEN is set and exported, then returns; exits the calling
#   script on failure. The GitHub PAT is supplied per-invocation and never
#   stored in a vault, so both runner entries (register / deregister) need
#   the same acquisition contract - hoisting it here keeps that contract in
#   one place rather than copied across the two wrappers.
#
#   Resolution order:
#     1. GH_TOKEN already in the environment -> use it (the unattended
#        escape hatch: the E2E agent and any `wsl -- ...` caller set it and
#        skip the prompt entirely). _run-playbook.sh's bridge forwards it
#        across the Git-Bash -> WSL hop via WSLENV.
#     2. No GH_TOKEN AND no controlling TTY -> fail fast. A `read` prompt
#        would otherwise block forever on input no automated caller can
#        answer; the explicit error names the env-var remedy.
#     3. No GH_TOKEN but a TTY is present -> prompt. -s keeps the token out
#        of terminal scrollback; -r keeps backslashes literal (some PATs
#        contain characters the line editor would otherwise re-interpret).
#        An empty entry is rejected.
#
#   The interactive (TTY) prompt branch is not reachable from a headless
#   test harness (bats stdin is never a TTY), so the bats suites cover the
#   preset and no-TTY branches and the prompt itself is verified manually.
# ---------------------------------------------------------------------------
require_gh_token() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        export GH_TOKEN
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_err 'GH_TOKEN must be set for unattended use (no TTY to prompt on).'
        echo '  When invoked via wsl, ensure GH_TOKEN is forwarded through WSLENV.' >&2
        exit 2
    fi

    read -rsp 'GitHub token: ' GH_TOKEN
    echo
    if [[ -z "${GH_TOKEN}" ]]; then
        log_err 'GitHub token required'
        exit 2
    fi
    export GH_TOKEN
}
