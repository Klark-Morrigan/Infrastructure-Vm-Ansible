<#
.SYNOPSIS
    Runs unit tests locally. Delegates to the shared runner in
    Common-PowerShell.

.DESCRIPTION
    Single source of truth for the Pester invocation lives in
    Common-PowerShell\.github\actions\run-unit-tests\Run-Tests.ps1 -
    the same script CI runs through the run-unit-tests composite
    action. Common-PowerShell is expected as a sibling checkout under
    the same parent directory.

.EXAMPLE
    .\Run-Tests.ps1

.EXAMPLE
    .\Run-Tests.ps1 -LogPath c:/tmp/p.log
#>

param(
    # Forwarded to the shared runner, which redirects every stream into this
    # file internally. Lets callers self-log with a bare call instead of
    # wrapping the invocation in an external *> redirect.
    [string] $LogPath,

    # Log-retention controls passed straight through; the shared runner owns
    # their default values, so they stay undeclared here (single source).
    [int]    $LogRetention,
    [string] $LogRetentionFilter
)

# Repo root is one level up now that this script lives under scripts\;
# Common-PowerShell is a sibling of the repo root, so two levels up from here.
$repoRoot = Split-Path -Parent $PSScriptRoot

# Pin TestsRoot to this repo, then forward whatever log params the caller
# actually passed. No [CmdletBinding()] here, so only the declared params can
# appear in $PSBoundParameters - common params cannot leak into the splat.
$forwarded = @{ TestsRoot = $repoRoot }
foreach ($bound in $PSBoundParameters.GetEnumerator()) {
    $forwarded[$bound.Key] = $bound.Value
}

& ([IO.Path]::Combine($repoRoot, '..', 'Common-PowerShell', '.github',
    'actions', 'run-unit-tests', 'Run-Tests.ps1')) @forwarded
