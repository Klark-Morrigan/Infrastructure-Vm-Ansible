<#
.SYNOPSIS
    Starts an HTTP file server on the Hyper-V host that serves files
    from a staging directory to target VMs over the internal switch.

.DESCRIPTION
    Lifts the body of Start-VmFileServer + Add-VmFileServerFile
    (Infrastructure.HyperV) so the Ansible bridge can stage the runner
    tarball Windows-side and let the target VMs fetch it directly,
    bypassing the NAT-bound github.com path. Same bind algorithm: pick
    the host adapter whose IP shares a /24 with the target VM. Same
    multi-file serving: any file present in -StagingDir is served by
    its basename, 404 otherwise.

    Stand-alone script (not a dot-sourced module function) because the
    bridge invokes it via `pwsh.exe -File ...` and parses the two
    output lines:

        BASE_URL=http://<host-ip>:<port>
        PID=<process-id>

    The script then blocks until killed so the listener stays alive
    for as long as ansible-playbook needs it. The bridge captures the
    PID and hands it to _stop-host-file-server.ps1 in its EXIT trap.

    Wrapped in Start-HostFileServer so Pester can call the function
    directly without auto-invoking the blocking outer body.
#>
[CmdletBinding()]
param(
    # Directory whose files are served. Not Mandatory at script-level
    # so Pester can dot-source this file without supplying a value;
    # the inner function enforces Mandatory at its own boundary.
    [string] $StagingDir,

    # Either -TargetVmIp (production - derive host IP via /24 match)
    # or -HostIp (tests - bind to a known address) must be supplied
    # when the script is invoked as a top-level file.
    [string] $TargetVmIp,
    [string] $HostIp,

    [int] $Port = 8745
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VmSwitchHostIp {
    <#
    .SYNOPSIS
        Returns the host's IP on the same /24 as the target VM.

    .DESCRIPTION
        Mirrors Get-VmSwitchHostIp in Infrastructure.HyperV. Used to
        select the Hyper-V internal switch adapter when the VM's IP is
        the only thing the caller knows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $VmIpAddress
    )

    # Derive the /24 prefix from the VM address so we can match the
    # host adapter that sits on the same subnet (the Hyper-V internal
    # switch adapter).
    $parts  = $VmIpAddress -split '\.'
    $prefix = "$($parts[0]).$($parts[1]).$($parts[2])."

    $hostIp = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress.StartsWith($prefix) -and
            $_.IPAddress -ne $VmIpAddress
        } |
        Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $hostIp) {
        throw "No host adapter found on the same /24 as '$VmIpAddress' (prefix '$prefix')."
    }

    $hostIp
}

function Start-HostFileServer {
    <#
    .SYNOPSIS
        Starts the HttpListener and serves files from $StagingDir by
        their basename.

    .DESCRIPTION
        Returns a server handle (PSCustomObject with BaseUrl,
        Listener, Runspace, PowerShell, FirewallRuleName) so the
        outer script can echo BASE_URL/PID and tests can verify state
        + tear down explicitly.

        Multi-file serving: the listener probes Test-Path against
        Join-Path $StagingDir <basename>; on hit it streams the
        bytes, on miss it returns 404. Mirrors the Infrastructure-
        HyperV listener so a future toolchain delivery feature can
        stage many payloads (JDK, .NET SDK, agent binaries) in the
        same dir without touching this script.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string] $StagingDir,

        [string] $TargetVmIp,
        [string] $HostIp,

        [int] $Port = 8745
    )

    if (-not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
        throw "Start-HostFileServer: -StagingDir is not an existing directory: $StagingDir"
    }

    if (-not $HostIp) {
        if (-not $TargetVmIp) {
            throw "Start-HostFileServer: either -HostIp or -TargetVmIp is required."
        }
        $HostIp = Get-VmSwitchHostIp -VmIpAddress $TargetVmIp
    }

    # Open the firewall before the listener starts so no connection
    # is accepted before the rule is in place (defence in depth - the
    # rule is what controls which hosts can reach the port on the
    # internal switch).
    #
    # Remove-then-Create makes the call idempotent across re-invocations:
    # the bridge's stop helper only kills the listener process and
    # leaves the rule behind (so the next start sees it as a duplicate-
    # name conflict). The remove is best-effort so a fresh host with no
    # prior rule does not surface an error here.
    $firewallRuleName = "VmAnsibleFileServer-$Port"
    Remove-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $firewallRuleName `
        -Name        $firewallRuleName `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   $Port `
        -Action      Allow | Out-Null

    $listener = [System.Net.HttpListener]::new()
    $prefix   = "http://${HostIp}:${Port}/"
    $listener.Prefixes.Add($prefix)
    $listener.Start()

    # Isolated runspace so the outer thread can keep printing and
    # then sleep. The serve loop exits when Listener.Stop() makes
    # GetContext() throw.
    $ps       = [powershell]::Create()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $ps.Runspace = $runspace

    $null = $ps.AddScript({
        param($Listener, $StagingDir)
        while ($true) {
            try {
                $ctx = $Listener.GetContext()
            } catch {
                # Listener.Stop() raises here - intended exit signal,
                # not an error.
                break
            }
            $req      = $ctx.Request
            $resp     = $ctx.Response
            # Strip the leading slash to obtain a bare filename. The
            # listener prefix is "<host>:<port>/" so any request URL
            # canonicalises into a path rooted at /; the trim yields
            # the basename clients used.
            $fileName = $req.Url.LocalPath.TrimStart('/')
            $filePath = Join-Path $StagingDir $fileName
            if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                $info                 = [System.IO.FileInfo]::new($filePath)
                $resp.StatusCode      = 200
                $resp.ContentLength64 = $info.Length
                $stream = [System.IO.File]::OpenRead($filePath)
                $stream.CopyTo($resp.OutputStream)
                $stream.Dispose()
            } else {
                $resp.StatusCode = 404
            }
            $resp.OutputStream.Close()
        }
    })
    $null = $ps.AddParameters(@{
        Listener   = $listener
        StagingDir = $StagingDir
    })
    $null = $ps.BeginInvoke()

    [PSCustomObject]@{
        HostIp           = $HostIp
        Port             = $Port
        BaseUrl          = "http://${HostIp}:${Port}"
        StagingDir       = $StagingDir
        Listener         = $listener
        Runspace         = $runspace
        PowerShell       = $ps
        FirewallRuleName = $firewallRuleName
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $StagingDir) {
        throw "_start-host-file-server.ps1: -StagingDir is required."
    }

    $serverArgs = @{
        StagingDir = $StagingDir
        Port       = $Port
    }
    if ($TargetVmIp) { $serverArgs['TargetVmIp'] = $TargetVmIp }
    if ($HostIp)     { $serverArgs['HostIp']     = $HostIp }

    $server = Start-HostFileServer @serverArgs

    # Bridge contract: BASE_URL first, PID second, each on its own line
    # so a simple `while read` loop in bash can capture both before the
    # script blocks. $PID is this pwsh process - the same process the
    # bridge will hand to _stop-host-file-server.ps1.
    Write-Output "BASE_URL=$($server.BaseUrl)"
    Write-Output "PID=$PID"

    # Block until killed. The listener runs in a background runspace,
    # so the foreground only needs to stay alive; Start-Sleep -Seconds
    # is interruptible by Stop-Process -Force.
    while ($true) { Start-Sleep -Seconds 3600 }
}
