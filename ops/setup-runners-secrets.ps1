<#
.SYNOPSIS
    Stores GitHubRunnersConfig in the local SecretStore vault by
    delegating to the Infrastructure-GitHubRunners setup script.

.DESCRIPTION
    Thin wrapper. The real validation and vault-write logic lives in
    Infrastructure-GitHubRunners\hyper-v\ubuntu\setup-secrets.ps1 -
    this file exists so the operator surface in this repo is
    discoverable (`ops/setup-runners-secrets.{ps1,bat}` sit next to
    the rest of `ops/`) without duplicating the schema validator and
    the Initialize-MicrosoftPowerShellSecretStoreVault call site.

    Both repos write to the same vault (`GitHubRunners`) and secret
    name (`GitHubRunnersConfig-<Suffix>`) - which is exactly what
    this repo's bash bridge in `ops/_run-playbook.sh` reads from when
    a wrapper declares it via `CA_EXTRA_VAULTS=GitHubRunners`. Forking
    the writer before the vault
    contract genuinely diverges would just create a second place to
    keep in lock-step with the first (same posture as
    `ops/setup-secrets.ps1` toward Vm-Users).

    A follow-up feature replaces this wrapper with a first-class
    implementation when the vault contract diverges (or
    Infrastructure-GitHubRunners is archived) - timing not
    pre-committed.

.PARAMETER ConfigFile
    Path to the GitHubRunnersConfig JSON file. Mutually exclusive
    with -ConfigJson. Forwarded verbatim to the GitHubRunners setup
    script.

.PARAMETER ConfigJson
    The runner config as a raw JSON string. Mutually exclusive with
    -ConfigFile. Forwarded verbatim.

.PARAMETER RequireVaultPassword
    When specified, the SecretStore vault requires a password each
    session. Recommended on shared or less-trusted machines.
    Forwarded verbatim.

.PARAMETER SecretSuffix
    Selects the lifecycle/environment label appended to the secret
    name (`GitHubRunnersConfig-<Suffix>`). Operator runs pass
    `Production`; ephemeral fixtures pass their own label. Forwarded
    verbatim.

.EXAMPLE
    pwsh ./ops/setup-runners-secrets.ps1 `
        -ConfigFile C:\private\runners-config.json `
        -SecretSuffix Production
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ConfigFile,

    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $ConfigJson,

    [Parameter()]
    [switch] $RequireVaultPassword,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail fast before resolving the sibling repo - a missing config file
# is the operator's typo, not a missing dependency, so surface that
# first with a path-named error.
if ($PSCmdlet.ParameterSetName -eq 'File' `
        -and -not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "ConfigFile not found: $ConfigFile"
}

# Sibling checkout convention: Infrastructure-GitHubRunners lives next
# to this repo under the same parent directory. Same lookup pattern
# `ops/setup-secrets.ps1` uses for Infrastructure-Vm-Users.
$repoRoot     = Split-Path -Parent $PSScriptRoot
$runnersPs1   = [IO.Path]::Combine(
    $repoRoot, '..',
    'Infrastructure-GitHubRunners', 'hyper-v', 'ubuntu', 'setup-secrets.ps1'
)

if (-not (Test-Path -LiteralPath $runnersPs1 -PathType Leaf)) {
    throw (
        "Infrastructure-GitHubRunners setup script not found at:`n" +
        "  $runnersPs1`n`n" +
        "This wrapper delegates the real work to the GitHubRunners " +
        "repo. Clone Infrastructure-GitHubRunners as a sibling " +
        "checkout next to this repo and re-run."
    )
}

# Forward only the params the delegate actually accepts. Splatting the
# whole $PSBoundParameters would pass through nothing extra today, but
# building the hashtable explicitly keeps the contract obvious if a
# future PowerShell common-parameter sneaks in.
$forward = @{ SecretSuffix = $SecretSuffix }
if ($PSCmdlet.ParameterSetName -eq 'File') { $forward.ConfigFile = $ConfigFile }
if ($PSCmdlet.ParameterSetName -eq 'Json') { $forward.ConfigJson = $ConfigJson }
if ($RequireVaultPassword)                 { $forward.RequireVaultPassword = $true }

& $runnersPs1 @forward
