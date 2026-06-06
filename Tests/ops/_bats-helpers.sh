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

_bats_init_temp() {
    _bats_resolve_bash
    TEST_TMP="$(mktemp -d -t "${1}.XXXXXX")"
}

_bats_cleanup_temp() {
    rm -rf "${TEST_TMP}"
}
