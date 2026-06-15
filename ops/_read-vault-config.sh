#!/usr/bin/env bash
# Reads a JSON-valued secret from a PowerShell SecretManagement vault
# via pwsh.exe on the Windows host and prints the validated payload on
# stdout. Stdout-only output keeps the script composable with $(...)
# capture and shell redirection.
#
# Single responsibility: vault read + payload validation. No tmpdir,
# no inventory generation, no extra-vars composition - those live in
# sibling scripts and the run-playbook.sh orchestrator wires them all
# together. Splitting along these lines means each piece can be
# unit-tested against only its own external boundary (this one needs
# a stubbed pwsh.exe; the pure-transform siblings need none).
#
# Why pwsh.exe from inside WSL: SecretManagement and the SecretStore
# vault are Windows-side state owned by the operator's Windows user
# profile. WSL has no path to that profile other than round-tripping
# through pwsh.exe; reimplementing the vault read in Linux is not on
# the table.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Argument validation. Both vault and secret are required - guessing
#    either is worse than failing fast.
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    echo "usage: _read-vault-config.sh <vault-name> <secret-name>" >&2
    exit 2
fi

readonly VAULT_NAME="$1"
readonly SECRET_NAME="$2"

# ---------------------------------------------------------------------------
# 2. Vault read via pwsh.exe. Goes through the Infrastructure.Secrets
#    wrapper (Get-InfrastructureSecret) per problem.md - the bridge
#    does not call Get-Secret directly, so a future provider swap
#    touches only that one wrapper. Import-Module pulls in
#    Infrastructure.Secrets (and auto-loads Common.PowerShell, declared
#    in its RequiredModules); Use-MicrosoftPowerShellSecretStoreProvider
#    bootstraps SecretManagement + SecretStore on first call and is
#    idempotent on subsequent ones. The bootstrap (step 7) has already
#    installed Infrastructure.Secrets; the bridge does not install it
#    here to keep per-invocation cost low.
#
#    NoProfile + NonInteractive cut startup cost and prevent any
#    accidental prompt from hanging an unattended run. Out-String
#    forces the payload to a single string regardless of how the
#    provider represents it. 2>&1 keeps pwsh's own error messages in
#    the captured output so the failure branch can surface them.
# ---------------------------------------------------------------------------
if ! raw="$(pwsh.exe -NoProfile -NonInteractive -Command \
    "Import-Module Infrastructure.Secrets; \
     Use-MicrosoftPowerShellSecretStoreProvider; \
     Get-InfrastructureSecret -VaultName '${VAULT_NAME}' -SecretName '${SECRET_NAME}' | Out-String" \
    2>&1)"; then
    echo "_read-vault-config.sh: pwsh.exe failed reading ${VAULT_NAME}/${SECRET_NAME}: ${raw}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Normalise. pwsh.exe emits CRLF; jq sees the CR as a byte and a
#    leading UTF-8 BOM (invisible to humans, hard error to jq) is a
#    common pwsh quirk. Both need to be gone before validation.
# ---------------------------------------------------------------------------
raw="${raw//$'\r'/}"
raw="$(printf '%s' "${raw}" | sed '1s/^\xEF\xBB\xBF//')"

# Out-String tacks on trailing newlines; strip them so the JSON
# validator sees exactly the document the producer wrote.
raw="${raw%$'\n'}"
raw="${raw%$'\n'}"

# ---------------------------------------------------------------------------
# 4. Validation. Empty payload and malformed JSON both fail here with
#    the vault/secret in the message, so a downstream consumer never
#    has to parse this script's stderr to know what broke.
# ---------------------------------------------------------------------------
if [[ -z "${raw}" ]]; then
    echo "_read-vault-config.sh: empty payload for ${VAULT_NAME}/${SECRET_NAME}" >&2
    exit 1
fi

if ! printf '%s' "${raw}" | jq empty >/dev/null 2>&1; then
    echo "_read-vault-config.sh: payload for ${VAULT_NAME}/${SECRET_NAME} is not valid JSON" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Emit. printf without a trailing newline so a consumer redirecting
#    to a file gets exactly the JSON document, byte-for-byte.
# ---------------------------------------------------------------------------
printf '%s' "${raw}"
