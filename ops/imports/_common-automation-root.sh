#!/usr/bin/env bash
# Resolves the Common-Automation repo root - the single place the ops/
# cross-repo adapters (imports/_log.sh, imports/_to-windows-path.sh) learn
# where the sibling repo lives, so the "where is Common-Automation" knowledge
# is not re-derived per adapter or per script.
#
# Guarded so sourcing several adapters in one script resolves the root only
# once, and a caller that already set common_automation_root keeps its
# value. COMMON_AUTOMATION_ROOT overrides the sibling-checkout default for
# the bats suites (CI has no real sibling). The relative fallback walks three
# levels up: ops/imports -> ops -> repo root -> c:\a_Code, then into the
# Common-Automation sibling. The plain assignment (not `: "${x:=...}"`)
# observes the cd's exit status rather than masking it (shellcheck SC2312).
if [[ -z "${common_automation_root:-}" ]]; then
    # shellcheck disable=SC2034  # consumed by the adapter shims that source this
    common_automation_root="${COMMON_AUTOMATION_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../../../Common-Automation" && pwd)}"
fi
