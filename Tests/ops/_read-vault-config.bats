#!/usr/bin/env bats
# Tests for ops/_read-vault-config.sh - the vault reader. Boundary
# under test: pwsh.exe (stubbed on the synthetic PATH). Every other
# behaviour - BOM strip, CR normalisation, JSON validation, error
# messages - is in-process and tested directly.
# Run with: bats Tests/ops/_read-vault-config.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_read-vault-config.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    # Capture bash and jq before overriding PATH - the script under
    # test needs jq (its only non-stub external dep) and the test
    # harness needs an absolute bash path because the Alpine bats
    # image lacks bash under /bin or /usr/bin.
    _bats_init_temp readVaultCfg
    JQ_BIN="$(command -v jq)"

    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"

    # Default pwsh.exe stub - treats every invocation as a black box
    # and prints whatever the test has seeded into PWSH_STUB_FILE.
    # The script under test currently calls Get-InfrastructureSecret
    # via Import-Module Infrastructure.Secrets;
    # Use-MicrosoftPowerShellSecretStoreProvider, but the stub does
    # not care which cmdlet pwsh would run - the test surface is the
    # bytes coming back, not the command string.
    cat >"${STUBS}/pwsh.exe" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${PWSH_STUB_FILE:-}" && -f "${PWSH_STUB_FILE}" ]]; then
    cat "${PWSH_STUB_FILE}"
fi
exit "${PWSH_STUB_EXIT:-0}"
STUB
    chmod +x "${STUBS}/pwsh.exe"

    # Synthetic PATH: only stubs + whatever was needed before the
    # override (jq path injected directly so the script under test
    # finds it even when the host's jq is outside /usr/bin).
    export PATH="${STUBS}:$(dirname "${JQ_BIN}"):/usr/bin:/bin"
    export PWSH_STUB_FILE="${TEST_TMP}/pwsh.out"
    export PWSH_STUB_EXIT=0
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when given fewer than two args" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]

    run "${BASH_BIN}" "${SCRIPT}" VaultOnly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "prints the validated JSON payload on stdout for a valid pwsh response" {
    printf '%s' '{"foo":"bar"}' > "${PWSH_STUB_FILE}"
    run "${BASH_BIN}" "${SCRIPT}" VaultX SecretY
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"foo":"bar"}' ]
}

@test "strips a leading UTF-8 BOM before JSON validation" {
    # Without stripping, jq rejects the BOM. The script must remove it
    # so downstream consumers see clean JSON.
    printf '\xEF\xBB\xBF%s' '{"foo":"bar"}' > "${PWSH_STUB_FILE}"
    run "${BASH_BIN}" "${SCRIPT}" VaultX SecretY
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"foo":"bar"}' ]
}

@test "normalises CRLF line endings from pwsh.exe output" {
    # pwsh.exe always emits CRLF on Windows; a stray CR byte breaks
    # jq's leniency in some shells, so the script strips them.
    printf '{"foo":"bar"}\r\n' > "${PWSH_STUB_FILE}"
    run "${BASH_BIN}" "${SCRIPT}" VaultX SecretY
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"foo":"bar"}' ]
}

@test "fails with vault and secret named when payload is empty" {
    : > "${PWSH_STUB_FILE}"
    run "${BASH_BIN}" "${SCRIPT}" VaultX SecretY
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"empty payload"* ]]
    [[ "${output}" == *"VaultX/SecretY"* ]]
}

@test "fails with vault and secret named when payload is malformed JSON" {
    printf '%s' 'not-json-at-all' > "${PWSH_STUB_FILE}"
    run "${BASH_BIN}" "${SCRIPT}" VaultX SecretY
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not valid JSON"* ]]
    [[ "${output}" == *"VaultX/SecretY"* ]]
}

@test "fails with vault and secret named when pwsh.exe exits non-zero" {
    PWSH_STUB_EXIT=1 run "${BASH_BIN}" "${SCRIPT}" VaultX SecretY
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VaultX/SecretY"* ]]
}
