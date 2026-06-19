#!/usr/bin/env bash
# Shared fixtures for every Tests/ops/*.bats file. Sourced from each
# *.bats with:
#   source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"
#
# Two reasons the absolute-bash + mktemp+rm-rf skeleton lives here
# rather than being duplicated per file:
#   - BASH_BIN: every script under ops/ is invoked via "${BASH_BIN}"
#     rather than `bash` so the test harness survives an Alpine bats
#     image whose PATH does not include /bin/bash. Capturing it once
#     at the helper layer keeps every bats file robust to the
#     harness's PATH shape.
#   - TEST_TMP: every bats file allocates a scratch dir for its
#     fixtures and cleans it up in teardown(). One init+cleanup pair
#     means a change to the cleanup convention (e.g. add an `rm -f`
#     trap for nested mounts) lands in one place.
#
# Caller patterns:
#   setup() {
#       _bats_init_temp <prefix>        # sets BASH_BIN, TEST_TMP
#       <caller-specific vars>          # PROV="${TEST_TMP}/foo.json"
#   }
#   teardown() {
#       _bats_cleanup_temp              # rm -rf "${TEST_TMP}"
#   }
#
# For files that need BASH_BIN but no scratch dir (e.g. pure stdin ->
# stdout transforms whose tests do not touch the filesystem), call
# _bats_resolve_bash directly and skip _bats_init_temp /
# _bats_cleanup_temp.

_bats_resolve_bash() {
    # shellcheck disable=SC2034 # consumed by sourcing bats files
    BASH_BIN="$(command -v bash)"
}

# Stand up a fake COMMON_AUTOMATION_ROOT containing the cross-repo shell
# helpers ops/ scripts source at runtime - currently scripts/log.sh, the
# shared logger every ops/ script pulls in via the _log.sh resolver shim.
# CI checks out no Common-Automation sibling (the bash workflow is the
# reusable one FROM Common-Automation, run against this repo), so each bats
# that runs an ops/ script must reconstruct what that script sources. The
# logger stub is self-contained (no colors.sh dependency) and reproduces
# the real logger's no-colour output byte-for-byte - which is exactly what
# the real logger emits under a non-TTY test stream - so log assertions
# hold against either.
_bats_install_common_automation_stub() {
    local root="$1"
    mkdir -p "${root}/scripts"
    cat >"${root}/scripts/log.sh" <<'STUB'
#!/usr/bin/env bash
# Test stub for Common-Automation/scripts/log.sh - the [ts] LEVEL <script>:
# stderr format, minus colour, with no cross-repo colors.sh dependency.
_log_emit() {
    local level="$1"
    shift 2
    printf '[%s] %-5s %s: %s\n' \
        "$(date +%H:%M:%S)" "${level}" \
        "${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]##*/}" "$*" >&2
}
log_info() { _log_emit INFO  x "$*"; }
log_warn() { _log_emit WARN  x "$*"; }
log_err()  { _log_emit ERROR x "$*"; }
STUB
}

_bats_init_temp() {
    _bats_resolve_bash
    TEST_TMP="$(mktemp -d -t "${1}.XXXXXX")"
    # Every ops/ script sources the shared logger through the _log.sh shim,
    # which resolves COMMON_AUTOMATION_ROOT. Point it at a reconstructed
    # stub under TEST_TMP so in-place and transplanted scripts both find it.
    # Bats that build their own COMMON_AUTOMATION_ROOT for other helpers
    # (e.g. the _to-windows-path stub) reuse this very path, so the stubs
    # coexist in one root.
    # shellcheck disable=SC2034 # consumed by sourcing bats files
    COMMON_AUTOMATION_ROOT="${TEST_TMP}/Common-Automation"
    export COMMON_AUTOMATION_ROOT
    _bats_install_common_automation_stub "${COMMON_AUTOMATION_ROOT}"
}

_bats_cleanup_temp() {
    rm -rf "${TEST_TMP}"
}
