#!/usr/bin/env bash
# Runs locally the same bash/bats/lint suite GitHub-Common's ci-bash
# reusable workflow runs in CI. Single source of truth for the check
# logic lives in GitHub-Common/scripts/run-tests.sh; this shim only
# points it at this repo via GHCOMMON_TARGET_REPO. GitHub-Common is
# expected as a sibling checkout under the same parent directory.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
ghcommon_root="$(cd "${repo_root}/../GitHub-Common" && pwd)"

GHCOMMON_TARGET_REPO="${repo_root}" exec "${ghcommon_root}/scripts/run-tests.sh"
