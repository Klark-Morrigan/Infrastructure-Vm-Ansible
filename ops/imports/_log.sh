#!/usr/bin/env bash
# Cross-repo adapter: imports the shared logger (log_info / log_warn /
# log_err) from Common-Automation (scripts/log.sh, which owns the colour
# single source of truth via colors.sh). Sourcing this is how every ops/
# script pulls in the logger on a stable in-repo path while the cross-repo
# location stays resolved in one place. See _common-automation-root.sh for
# how the repo root is found and overridden under test.
# shellcheck source=ops/imports/_common-automation-root.sh
source "${BASH_SOURCE[0]%/*}/_common-automation-root.sh"
# shellcheck source=/dev/null
source "${common_automation_root}/scripts/log.sh"
