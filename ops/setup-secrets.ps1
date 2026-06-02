<#
.SYNOPSIS
    Stores VmUsersConfig in the local SecretStore vault by delegating
    to the Infrastructure-Vm-Users setup script.

.DESCRIPTION
    Thin wrapper. The real validation and vault-write logic lives in
    Infrastructure-Vm-Users\hyper-v\ubuntu\setup-secrets.ps1 - this
    file exists so the operator surface in this repo is discoverable
    (`ops/setup-secrets.{ps1,bat}` sit next to the other ops entries)
    without duplicating the schema validator and the
    Initialize-MicrosoftPowerShellSecretStoreVault call site.

    Both repos write to the same vault (`VmUsers`) and secret name
    (`VmUsersConfig`) - which is exactly what this repo's bash bridge
    in `ops/_read-vault-config.sh` reads from. Forking the writer
    before the vault contract genuinely diverges would just create a
    second place that has to stay in lock-step with the first.

    A follow-up feature replaces this wrapper with a first-class
    implementation when the vault contract diverges (or Vm-Users is
    archived) - timing not pre-committed.

.PARAMETER ConfigFile
    Path to the VmUsersConfig JSON file. Forwarded verbatim to the
    Vm-Users setup script.

.EXAMPLE
    pwsh ./ops/setup-secrets.ps1 -ConfigFile C:\private\vm-users-config.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail fast before resolving the sibling repo - a missing config file
# is the operator's typo, not a missing dependency, so surface that
# first with a path-named error.
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "ConfigFile not found: $ConfigFile"
}

# Sibling checkout convention: Infrastructure-Vm-Users lives next to
# this repo under the same parent directory. Same lookup pattern as
# scripts/Run-Tests.ps1 uses for PowerShell-Common.
$repoRoot   = Split-Path -Parent $PSScriptRoot
$vmUsersPs1 = [IO.Path]::Combine(
    $repoRoot, '..',
    'Infrastructure-Vm-Users', 'hyper-v', 'ubuntu', 'setup-secrets.ps1'
)

if (-not (Test-Path -LiteralPath $vmUsersPs1 -PathType Leaf)) {
    throw (
        "Infrastructure-Vm-Users setup script not found at:`n" +
        "  $vmUsersPs1`n`n" +
        "This wrapper delegates the real work to the Vm-Users repo. " +
        "Clone Infrastructure-Vm-Users as a sibling checkout next to " +
        "this repo and re-run."
    )
}

# Forward verbatim. The Vm-Users script owns validation, module
# install, vault registration, and Set-Secret; any errors propagate
# through unchanged because $ErrorActionPreference = 'Stop' is in
# effect.
& $vmUsersPs1 -ConfigFile $ConfigFile
