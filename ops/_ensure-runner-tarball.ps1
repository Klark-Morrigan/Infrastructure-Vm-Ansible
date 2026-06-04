<#
.SYNOPSIS
    Ensures the actions/runner tarball for a given version is present
    in a Windows-side cache directory.

.DESCRIPTION
    Idempotent download helper. The Ansible bridge stages the tarball
    on the Windows side once per invocation, then serves it to every
    target VM through the host file server. Caching across runs avoids
    a 200+ MB re-download every time the operator re-invokes
    register-runners; the cache lives under `$LOCALAPPDATA\Temp` so
    Windows' own temp-file housekeeping eventually reclaims it.

    Stale-version cleanup before downloading keeps the cache from
    growing without bound while still being safe to share with parallel
    invocations - each version lands in its own filename.

    Mirrors Invoke-RunnerTarballEnsure in Infrastructure.GitHub so the
    file-on-disk contract (filename pattern, byte content) stays
    aligned across both flows.

    Wrapped in Invoke-RunnerTarballEnsure so Pester can dot-source the
    file without auto-invoking the body.
#>
[CmdletBinding()]
param(
    # Not Mandatory at script-level so Pester can dot-source this
    # file without supplying values; the inner function enforces
    # Mandatory at its own boundary.
    [string] $Version,

    # Optional override for tests; production callers let the helper
    # pick the conventional $LOCALAPPDATA path so the cache shares
    # location with every other repo's runner cache.
    [string] $CacheDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RunnerTarballEnsure {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Version,

        [string] $CacheDir
    )

    if (-not $CacheDir) {
        $cacheRoot = $env:LOCALAPPDATA
        if (-not $cacheRoot) {
            throw "Invoke-RunnerTarballEnsure: -CacheDir not supplied and `$env:LOCALAPPDATA is empty."
        }
        $CacheDir = Join-Path $cacheRoot 'Temp\runner-cache'
    }

    $tarName   = "actions-runner-linux-x64-${Version}.tar.gz"
    $localPath = Join-Path $CacheDir $tarName

    if (Test-Path -LiteralPath $localPath) {
        # Cache hit. Returning the existing path keeps the bridge
        # idempotent across re-runs.
        return $localPath
    }

    # Cache miss. Purge any stale actions-runner-*.tar.gz files first
    # so the cache directory does not grow unboundedly when version
    # bumps land.
    New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null
    Get-ChildItem -Path $CacheDir -Filter 'actions-runner-*.tar.gz' `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $tarUrl = "https://github.com/actions/runner/releases/download/" +
              "v${Version}/${tarName}"

    # -UseBasicParsing for parity with Windows PowerShell 5 where the
    # default parser tries to instantiate IE - irrelevant here but
    # cheap insurance against running this from a cross-version
    # toolchain.
    Invoke-WebRequest -Uri $tarUrl -OutFile $localPath -UseBasicParsing

    if (-not (Test-Path -LiteralPath $localPath)) {
        throw "Invoke-RunnerTarballEnsure: download produced no file at $localPath."
    }
    if ((Get-Item -LiteralPath $localPath).Length -le 0) {
        throw "Invoke-RunnerTarballEnsure: downloaded file is empty: $localPath."
    }

    $localPath
}

if ($MyInvocation.InvocationName -ne '.') {
    $boundArgs = @{ Version = $Version }
    if ($PSBoundParameters.ContainsKey('CacheDir')) {
        $boundArgs['CacheDir'] = $CacheDir
    }
    Invoke-RunnerTarballEnsure @boundArgs
}
