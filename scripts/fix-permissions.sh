#!/usr/bin/env bash
# Re-stages +x on every tracked *.sh in this repo missing it. The
# canonical fix engine lives in GitHub-Common; this shim only points
# it at this repo via GHCOMMON_TARGET_REPO. GitHub-Common is expected
# as a sibling checkout under the same parent directory.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
ghcommon_root="$(cd "${repo_root}/../GitHub-Common" && pwd)"

GHCOMMON_TARGET_REPO="${repo_root}" exec "${ghcommon_root}/scripts/fix-permissions.sh"
