<#
.SYNOPSIS
    Runs unit tests locally. Delegates to the shared runner in
    PowerShell-Common.

.DESCRIPTION
    Single source of truth for the Pester invocation lives in
    PowerShell-Common\.github\actions\run-unit-tests\Run-Tests.ps1 -
    the same script CI runs through the run-unit-tests composite
    action. PowerShell-Common is expected as a sibling checkout under
    the same parent directory.

.EXAMPLE
    .\Run-Tests.ps1
#>

$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '..', 'PowerShell-Common', '.github', `
    'actions', 'run-unit-tests', 'Run-Tests.ps1')) -TestsRoot $repoRoot
