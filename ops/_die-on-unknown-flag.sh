#!/usr/bin/env bash
# Shared `case "$1" in ... *) ...` orphan branch for every per-script
# arg parser in ops/. Five scripts share the same three lines (echo
# error naming the offending arg, call the local usage(), exit 2);
# extracting them keeps the message format locked across the surface
# the bats suites assert against ("unknown argument").
#
# Sourced (not exec'd) so the function exits the calling script on
# failure - matching the inline behaviour it replaces. Requires the
# caller to have defined a `usage()` function before invoking; every
# *.sh under ops/ already does.
#
# Caller pattern:
#   while [[ $# -gt 0 ]]; do
#       case "$1" in
#           --known-flag) ... ;;
#           *) _die_on_unknown_flag "$1" ;;
#       esac
#   done
#
# The script name in the message is supplied by the shared logger
# (BASH_SOURCE[-1]), so callers no longer pass it - one fewer thing to
# keep in sync across the five arg parsers.
# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"

_die_on_unknown_flag() {
    local arg="$1"

    log_err "unknown argument: ${arg}"
    usage
    exit 2
}
