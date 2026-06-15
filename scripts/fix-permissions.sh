#!/usr/bin/env bash
# Re-stages +x on every tracked *.sh in this repo missing it. The
# canonical fix engine lives in Common-Automation; this shim only points
# it at this repo via COMMON_AUTOMATION_TARGET_REPO. Common-Automation is expected
# as a sibling checkout under the same parent directory.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
common_automation_root="$(cd "${repo_root}/../Common-Automation" && pwd)"

COMMON_AUTOMATION_TARGET_REPO="${repo_root}" exec "${common_automation_root}/scripts/fix-permissions.sh"
