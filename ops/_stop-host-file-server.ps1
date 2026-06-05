<#
.SYNOPSIS
    Stops a host file server started by _start-host-file-server.ps1.

.DESCRIPTION
    Idempotent stop helper. The Ansible bridge installs this as the
    EXIT trap so the listener always dies, even if ansible-playbook
    itself fails. Killing the pwsh process the listener runs inside is
    sufficient: the runspace dies with the process, the firewall rule
    is recreated next run with the same name, and the HttpListener
    releases its http.sys reservation on process exit.

    Wrapped in Stop-HostFileServer so Pester can dot-source the file
    without auto-invoking the body.
#>
[CmdletBinding()]
param(
    # Not Mandatory at script-level so Pester can dot-source this
    # file without supplying a value; the inner function enforces
    # Mandatory at its own boundary. `Pid` is a PowerShell automatic
    # variable so the parameter is named `ProcessId` with `Pid` as an
    # alias for callers that prefer the shorter name.
    [Alias('Pid')]
    [Nullable[int]] $ProcessId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-HostFileServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $ProcessId
    )

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        # The listener has already exited (the trap may have fired
        # twice, or the bridge crashed and Windows reaped the
        # process). Treat as success - there is nothing left to do.
        Write-Host "  Stop-HostFileServer: pid $ProcessId not running - already stopped." `
            -ForegroundColor DarkGray
        return
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    $proc.WaitForExit()
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($null -eq $ProcessId) {
        throw "_stop-host-file-server.ps1: -ProcessId is required."
    }
    Stop-HostFileServer -ProcessId $ProcessId
}
