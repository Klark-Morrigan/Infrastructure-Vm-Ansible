<#
.SYNOPSIS
    Resolves the latest actions/runner release version from GitHub.

.DESCRIPTION
    The Ansible bridge needs the version string before any role runs so
    it can stage the matching tarball for the host file server. Lifting
    the resolve here (instead of inside a controller-side pre-task)
    keeps the version a single source of truth per invocation: the
    bridge passes it down as the `runner_version` extra-var and no role
    re-resolves.

    Mirrors Resolve-RunnerVersion in Infrastructure-GitHubRunners so
    the contract (authenticated request, leading `v` stripped) stays
    aligned across both flows.

    The token is required: unauthenticated requests hit a 60/hour rate
    limit per IP, which is easy to exhaust in CI; authenticated
    requests get 5000/hour and the entry script already holds a PAT in
    memory.

    Wrapped in Resolve-RunnerVersion so Pester can dot-source the file
    without auto-invoking the body (same pattern as
    bootstrap-controller.ps1).
#>
[CmdletBinding()]
param(
    # Not Mandatory at the script-level param block so Pester can
    # dot-source this file without supplying a value; the function
    # below enforces Mandatory at its own boundary, and the top-level
    # invocation guard only fires when the file is run as a script.
    [string] $Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RunnerVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Token
    )

    $uri = 'https://api.github.com/repos/actions/runner/releases/latest'
    $headers = @{
        'Authorization' = "Bearer $Token"
        'User-Agent'    = 'Infrastructure-VM-Ansible'
        'Accept'        = 'application/vnd.github+json'
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
    }
    catch {
        # Re-throw with a token-shaped message when the failure is an
        # auth one so the operator triages the PAT first, not the
        # network. Other errors surface verbatim - the original
        # exception message is the most useful diagnostic.
        $status = $_.Exception.Response.StatusCode.value__ 2>$null
        if ($status -eq 401) {
            throw "Resolve-RunnerVersion: GitHub returned 401 - check the GH_TOKEN scopes."
        }
        throw
    }

    # tag_name is formatted as 'v2.317.0'; strip the leading 'v' so
    # the version can be used directly in filenames and URLs.
    $version = $response.tag_name -replace '^v', ''
    if (-not $version) {
        throw "Resolve-RunnerVersion: response had no tag_name."
    }

    $version
}

# Top-level invocation guard. $MyInvocation.InvocationName is '.' when
# the file is dot-sourced (tests) and the script's own path otherwise.
if ($MyInvocation.InvocationName -ne '.') {
    Resolve-RunnerVersion -Token $Token
}
