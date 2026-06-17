<#
.SYNOPSIS
    Defines Set-WslAutomountMetadata. Dot-sourced by bootstrap-controller.ps1.

.DESCRIPTION
    Extracted from bootstrap-controller.ps1 so the gate logic has its
    own file and its own dedicated Pester suite. Kept inside ops/
    rather than promoted to Common.PowerShell because the only known
    consumer is the bootstrap on this repo; promoting it module-side
    would require a version bump on every consumer and a permanent
    public-API surface. Re-evaluate the promotion when a second
    consumer materialises.

    The function itself is documented inline below.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-WslAutomountMetadata {
    <#
    .SYNOPSIS
        Idempotently enables the `metadata` mount option for /mnt/* in
        the targeted WSL distro's /etc/wsl.conf.

    .DESCRIPTION
        Without `metadata`, WSL's drvfs surfaces every Windows file
        under /mnt/c (and friends) as Linux mode 0777. Ansible's
        config loader treats world-writable directories as a config-
        injection risk and refuses to load ansible.cfg from one (the
        "ignoring it as an ansible.cfg source" warning at every play
        start); the same applies to any other Linux tool that
        sanity-checks directory perms before reading a config (pip,
        ssh, git). Adding `metadata,umask=22,fmask=11` to [automount]
        in /etc/wsl.conf makes /mnt/c mount with 0755 dirs / 0766
        files instead, which clears those checks so ansible.cfg
        loads normally and _ansible-env.sh becomes a safety-net
        rather than the load-bearing config.

        Mount options only apply when the distro starts, so a write
        is followed by `wsl --shutdown`; the next wsl invocation
        (the bash bootstrap) restarts the distro under the corrected
        mount.

        Three branches keep the function idempotent and conservative:
          * [automount] section already contains `metadata` -> no-op.
          * No [automount] section -> append the snippet, shutdown.
          * [automount] section without `metadata` -> throw. Refuses
            to silently append a duplicate section or rewrite an
            option string the operator may have put there for another
            tool (Docker, other repos).

    .PARAMETER DistroName
        Name of the WSL distro to configure. When omitted, the system
        default distro is used - same target a bare `wsl --`
        invocation would hit. Pass the name explicitly when the
        caller will go on to use `wsl -d <DistroName> --` and wants
        the wsl.conf write to land in the same target.
    #>
    [CmdletBinding()]
    param(
        [string] $DistroName
    )

    # WSL CLI args shared by every per-distro invocation. -d is
    # prepended when the caller pinned a distro so the read and write
    # land in the same one. --shutdown deliberately omits -d (it is
    # global; pinning would silently stop only one distro).
    $wslPrefix = @()
    if ($DistroName) {
        $wslPrefix += @('-d', $DistroName)
    }

    # Read without sudo. wsl.conf is conventionally mode 0644.
    # 2>$null swallows the "no such file" stderr when the distro
    # ships without a wsl.conf at all (rare on modern WSL, but
    # happens).
    $existing = (& wsl @wslPrefix -- cat /etc/wsl.conf 2>$null | Out-String)
    if ($null -eq $existing) { $existing = '' }

    # (?ms): multiline + dotall. The section probe matches a literal
    # [automount] header anchored to a line start; the metadata probe
    # additionally requires `metadata` to appear within the section
    # body (delimited by the next `[` or end-of-string), so `metadata`
    # showing up under a different section does not satisfy the check.
    $hasAutomountSection    = $existing -match '(?m)^\s*\[automount\]\s*$'
    $hasMetadataInAutomount = $existing -match '(?ms)\[automount\][^\[]*\bmetadata\b'

    if ($hasMetadataInAutomount) {
        Write-Host (
            '  /etc/wsl.conf [automount] already contains metadata ' +
            '- skipping.') -ForegroundColor DarkGray
        return
    }

    if ($hasAutomountSection) {
        $targetLabel = if ($DistroName) { "distro '$DistroName'" } else { 'the default WSL distro' }
        throw (
            "/etc/wsl.conf in $targetLabel already has an [automount] " +
            "section that does not include 'metadata' in its options. " +
            "Refusing to append a second [automount] section. Edit the " +
            "file by hand to add metadata,umask=22,fmask=11 (alongside " +
            "any existing options), then run 'wsl --shutdown' and " +
            "re-invoke the caller.")
    }

    Write-Host 'Configuring /etc/wsl.conf [automount] (sudo prompt) ...' `
        -ForegroundColor Cyan

    # bash -c with single-outer-quotes keeps every char inside literal
    # to PowerShell. printf builds the three lines (blank separator,
    # section header, options line) without here-doc fragility; tee -a
    # is the conventional sudo-write pattern.
    $bashCmd =
        'printf "%s\n" "" "[automount]" "options = \"metadata,umask=22,fmask=11\""' +
        ' | sudo tee -a /etc/wsl.conf > /dev/null'
    & wsl @wslPrefix -- bash -c $bashCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to append [automount] config to /etc/wsl.conf (exit $LASTEXITCODE)."
    }

    Write-Host '  Restarting WSL so the new mount options take effect ...' `
        -ForegroundColor Cyan
    & wsl --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed (exit $LASTEXITCODE)."
    }
    Write-Host '  [OK] /mnt/c will mount non-world-writable on next WSL launch.' `
        -ForegroundColor Green
}
