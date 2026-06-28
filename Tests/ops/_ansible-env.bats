#!/usr/bin/env bats
# Tests for ops/_ansible-env.sh - the cfg-mirror env exporter the bridge and
# bootstrap source. Scope here is the one branch this helper carries: how
# ANSIBLE_ROLES_PATH composes with and without a consumer_root. Its other
# exports are static one-to-one mirrors of ansible.cfg with no branching, so
# they are verified by inspection against the cfg, not exercised here.
#
# The helper is sourced (not run) so the assertions read the exported var
# directly; bats runs each @test in its own process, so the sourced exports
# do not leak between tests.
# Run with: bats Tests/ops/_ansible-env.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_ansible-env.sh"

@test "ANSIBLE_ROLES_PATH is the substrate roles/ alone when no consumer_root is set" {
    # The substrate's own flows (the retained runner fork, bootstrap, the
    # bats suite) leave consumer_root unset and must see the unchanged path.
    repo_root="/substrate"
    unset consumer_root
    # shellcheck disable=SC1090  # path computed at runtime
    source "${SCRIPT}"
    [ "${ANSIBLE_ROLES_PATH}" = "/substrate/roles" ]
}

@test "a consumer_root leads ANSIBLE_ROLES_PATH with the substrate roles/ appended" {
    # A consumer that owns roles resolves its own by short name first, with
    # the substrate roles/ still reachable for reusable substrate roles.
    repo_root="/substrate"
    consumer_root="/consumer"
    # shellcheck disable=SC1090  # path computed at runtime
    source "${SCRIPT}"
    [ "${ANSIBLE_ROLES_PATH}" = "/consumer/roles:/substrate/roles" ]
}
