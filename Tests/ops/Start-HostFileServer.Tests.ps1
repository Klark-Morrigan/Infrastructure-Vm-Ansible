<#
.SYNOPSIS
    Pester suite for the two Windows-side host-file-server helpers the
    bridge invokes when a consumer opts into the host file server:
      - _start-host-file-server.ps1  (Start-HostFileServer)
      - _stop-host-file-server.ps1   (Stop-HostFileServer)

.DESCRIPTION
    Each helper has its own Context. Pester (not bats) because the
    surface is .NET-heavy: HttpListener, Get-NetIPAddress; mocking those
    from bats would require a pwsh.exe round-trip per assertion.

    HttpListener-bound contexts use 127.0.0.1 with a random high port
    and mock New-NetFirewallRule so the tests do not need full admin
    rights for firewall manipulation. Binding to a localhost prefix
    on a non-system port works under a normal user account on most
    Windows configurations.
#>

BeforeAll {
    # Suppress firewall-rule cmdlets so the test host does not need
    # the elevated rights real production would. Listener binding to
    # 127.0.0.1:<random> still works under a non-admin account.
    function New-NetFirewallRule    { param([Parameter(ValueFromRemainingArguments)] $rest) }
    function Remove-NetFirewallRule { param([Parameter(ValueFromRemainingArguments)] $rest) }
    function Get-NetIPAddress       { param([Parameter(ValueFromRemainingArguments)] $rest) }

    . "$PSScriptRoot\..\..\ops\virtual-machines\_start-host-file-server.ps1"
    . "$PSScriptRoot\..\..\ops\virtual-machines\_stop-host-file-server.ps1"
}

Describe 'Start-HostFileServer + Stop-HostFileServer' {

    BeforeAll {
        # Staging directory with two distinct files so the multi-file
        # contract is exercised (one file would not distinguish the
        # folder-based listener from the old single-file shape).
        $script:stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("hostfs-test-$([System.Guid]::NewGuid())")
        New-Item -Path $script:stagingDir -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $script:stagingDir 'tarball.tar.gz'), 'hello-tarball')
        [System.IO.File]::WriteAllText(
            (Join-Path $script:stagingDir 'sidecar.txt'),    'hello-sidecar')

        # Random high port plus retry: HttpListener.Start() throws an
        # opaque "the process cannot access the file" when http.sys
        # already owns the port (another listener, a stale URL ACL,
        # or a TCP socket in TIME_WAIT). Up to 20 tries makes the
        # test resilient to the collision without losing the random
        # spread that keeps parallel test runs apart.
        $script:server = $null
        $lastError     = $null
        for ($i = 0; $i -lt 20 -and -not $script:server; $i++) {
            $candidate = Get-Random -Minimum 50000 -Maximum 59999
            try {
                $script:server = Start-HostFileServer `
                    -StagingDir $script:stagingDir `
                    -HostIp     '127.0.0.1' `
                    -Port       $candidate
            } catch {
                $lastError = $_
            }
        }
        if (-not $script:server) {
            throw "Could not bind a free port after 20 attempts. Last error: $lastError"
        }
        $script:port = $script:server.Port
    }

    AfterAll {
        if ($script:server -and $script:server.Listener.IsListening) {
            $script:server.Listener.Stop()
            $script:server.PowerShell.Dispose()
            $script:server.Runspace.Dispose()
        }
        if ($script:stagingDir -and (Test-Path -LiteralPath $script:stagingDir)) {
            Remove-Item -LiteralPath $script:stagingDir -Recurse -Force
        }
    }

    It 'exposes BaseUrl with the configured host and port' {
        $script:server.BaseUrl | Should -Be "http://127.0.0.1:$($script:port)"
    }

    It 'records the staging directory on the handle' {
        $script:server.StagingDir | Should -Be $script:stagingDir
    }

    It 'serves an arbitrary file in the staging directory by its basename' {
        $response = Invoke-WebRequest `
            -Uri             "$($script:server.BaseUrl)/tarball.tar.gz" `
            -UseBasicParsing `
            -ErrorAction     Stop

        $response.StatusCode | Should -Be 200
        # Invoke-WebRequest returns Content as byte[] when no
        # Content-Type is set; decode for a readable comparison.
        $content = if ($response.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string]$response.Content
        }
        $content | Should -Be 'hello-tarball'
    }

    It 'serves a second file from the same staging directory without restarting' {
        # The multi-file contract: dropping additional files into
        # StagingDir while the listener is live makes them reachable
        # via their basename URLs. This is the case a future toolchain
        # delivery feature relies on.
        $response = Invoke-WebRequest `
            -Uri             "$($script:server.BaseUrl)/sidecar.txt" `
            -UseBasicParsing `
            -ErrorAction     Stop

        $response.StatusCode | Should -Be 200
        $content = if ($response.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string]$response.Content
        }
        $content | Should -Be 'hello-sidecar'
    }

    It 'returns 404 for a request whose basename is not in the staging directory' {
        $statusCode = $null
        try {
            Invoke-WebRequest `
                -Uri             "$($script:server.BaseUrl)/no-such-file.bin" `
                -UseBasicParsing `
                -ErrorAction     Stop | Out-Null
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        $statusCode | Should -Be 404
    }
}

Describe 'Start-HostFileServer parameter validation' {

    It 'throws when neither -HostIp nor -TargetVmIp is supplied' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("hostfs-noip-$([System.Guid]::NewGuid())")
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

        try {
            { Start-HostFileServer -StagingDir $tempDir -Port 0 } |
                Should -Throw -ExpectedMessage '*HostIp*TargetVmIp*'
        } finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }

    It 'throws when -StagingDir does not exist' {
        { Start-HostFileServer `
            -StagingDir 'C:\Does\Not\Exist\runner-cache' `
            -HostIp     '127.0.0.1' `
            -Port       0 } |
            Should -Throw -ExpectedMessage '*StagingDir*'
    }

    It 'throws when -StagingDir points at a file rather than a directory' {
        # Defensive: -PathType Container on the validator catches the
        # easy mistake of passing the tarball path directly (the shape
        # this script's predecessor took).
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("hostfs-file-$([System.Guid]::NewGuid()).bin")
        Set-Content -LiteralPath $tempFile -Value 'x'

        try {
            { Start-HostFileServer `
                -StagingDir $tempFile `
                -HostIp     '127.0.0.1' `
                -Port       0 } |
                Should -Throw -ExpectedMessage '*StagingDir*'
        } finally {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

Describe 'Stop-HostFileServer' {

    It 'is a no-op when the requested pid is no longer running' {
        # Pick a pid that is almost certainly free - the lowest user
        # pids are kernel-owned and Get-Process returns nothing for
        # them under a normal account.
        { Stop-HostFileServer -ProcessId 999999 } | Should -Not -Throw
    }

    It 'force-stops a live process and waits for it to exit' {
        # Launch a benign child that idles, then kill it via the
        # helper. WaitForExit() returns once the kernel reaps it.
        $idleProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
            -WindowStyle Hidden -PassThru

        try {
            Stop-HostFileServer -ProcessId $idleProc.Id

            # WaitForExit() inside the helper should have returned
            # synchronously - the process is guaranteed dead now.
            $idleProc.HasExited | Should -BeTrue
        } finally {
            if (-not $idleProc.HasExited) {
                Stop-Process -Id $idleProc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
