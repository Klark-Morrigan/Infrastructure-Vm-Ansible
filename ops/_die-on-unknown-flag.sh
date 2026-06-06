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
#           *) _die_on_unknown_flag <script-name> "$1" ;;
#       esac
#   done
_die_on_unknown_flag() {
    local script_name="$1"
    local arg="$2"

    echo "${script_name}: unknown argument: ${arg}" >&2
    usage
    exit 2
}
