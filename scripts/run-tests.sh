#!/usr/bin/env bash
# Runs locally the same bash/bats/lint suite Common-Automation's ci-bash
# reusable workflow runs in CI. Single source of truth for the check
# logic lives in Common-Automation/scripts/run-tests.sh; this shim only
# points it at this repo via COMMON_AUTOMATION_TARGET_REPO. Common-Automation is
# expected as a sibling checkout under the same parent directory.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
common_automation_root="$(cd "${repo_root}/../Common-Automation" && pwd)"

COMMON_AUTOMATION_TARGET_REPO="${repo_root}" exec "${common_automation_root}/scripts/run-tests.sh"
