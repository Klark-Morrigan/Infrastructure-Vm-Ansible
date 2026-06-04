<#
.SYNOPSIS
    Bootstraps the Ansible controller environment on a Windows host.

.DESCRIPTION
    Two-stage bootstrap. This PowerShell stage runs on Windows and only
    handles the parts that cannot be done from inside WSL:

      1. Ensures WSL2 is installed and a distro is registered via
         Assert-Wsl2Ready from PowerShell.Common. The `Wsl2NotReady:`
         message-prefix contract is the agreed handoff for the
         reboot-required path.
      2. Invokes the second-stage bash bootstrap inside WSL, which
         creates the Python venv, installs Ansible, and pulls the
         pinned Galaxy collections.

    The logic is wrapped in Invoke-BootstrapController so unit tests
    can dot-source this file and invoke the function directly. The
    top-level script invocation (the `if` guard below) only runs when
    the file is executed, not when it is dot-sourced - that distinction
    is what keeps `exit` calls out of the test runner process.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set-WslAutomountMetadata lives in its own file so its logic and its
# Pester suite can be edited without churning this entry point. Kept
# in-repo (not promoted to PowerShell.Common) because the bootstrap is
# its only known consumer; promote when a second one appears.
. "$PSScriptRoot\_set-wsl-automount-metadata.ps1"

function Invoke-BootstrapController {
    <#
    .SYNOPSIS
        Runs the controller bootstrap. Returns the exit code the script
        should propagate.
    #>
    [CmdletBinding()]
    param(
        # Repo root used to anchor the wsl invocation. Defaulted to the
        # script's parent so the script works regardless of the
        # caller's working directory; parameterised so tests can point
        # it at a scratch dir.
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )

    # Ensure PowerShell.Common >= 6.2.0 is available before importing.
    # Installed on demand so a fresh host needs only this script (no
    # separate setup). Guarded with Get-Module to keep reruns fast.
    #
    # The 6.2.0 floor is the first version that ships Assert-WslHasBash,
    # which the bash-gate block below calls; an older 6.x sitting in
    # CurrentUser's module path would otherwise pass the "any version
    # installed" check and the Assert-WslHasBash call would fail with
    # `The term 'Assert-WslHasBash' is not recognized` halfway through
    # bootstrap.
    $requiredCommonVersion = [Version]'6.2.0'
    $commonModule = Get-Module -ListAvailable -Name PowerShell.Common |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $commonModule -or $commonModule.Version -lt $requiredCommonVersion) {
        Install-Module PowerShell.Common -MinimumVersion $requiredCommonVersion `
            -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module PowerShell.Common -MinimumVersion $requiredCommonVersion `
        -ErrorAction Stop

    # Infrastructure.Secrets is the wrapper the bash bridge's
    # _read-vault-config.sh imports inside its pwsh.exe call. The
    # bridge runs unattended once per playbook, so adding an
    # install-if-missing dance per-invocation would be slow and chatty;
    # lift the install into the bootstrap instead. Invoke-ModuleInstall
    # is itself idempotent and retry-wrapped for PSGallery blips, so no
    # extra branching is needed at this call site. PowerShell.Common is
    # auto-loaded as Infrastructure.Secrets's RequiredModules dep;
    # SecretManagement and SecretStore bootstrap themselves on first
    # call to Use-MicrosoftPowerShellSecretStoreProvider.
    Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets'

    # WSL2 gate. The Wsl2NotReady: prefix is the contract documented
    # in Assert-Wsl2Ready's help; treat it as a clean exit with a
    # reboot hint rather than a hard failure - the user has to reboot
    # before the downstream wsl -- invocation can succeed anyway.
    try {
        Assert-Wsl2Ready
    }
    catch {
        if ($_.Exception.Message -match '^Wsl2NotReady: ') {
            Write-Host (
                $_.Exception.Message -replace '^Wsl2NotReady: ',''
            ) -ForegroundColor Yellow
            return 0
        }
        throw
    }

    # Bash-on-default-distro gate. Assert-Wsl2Ready only proves WSL is
    # up and a distro is registered; it does not look inside the distro.
    # Docker Desktop installs a minimal `docker-desktop` distro with no
    # bash and silently sets it as the WSL default, so a bare `wsl --`
    # call hitting `#!/usr/bin/env bash` would fail mid-bootstrap with
    # `env: can't execute 'bash': No such file or directory`. Catching
    # the WslMissingBash: prefix here surfaces a named remediation hint
    # (install Ubuntu, set as default) rather than letting the bash
    # bridge fail later with a less obvious error.
    try {
        Assert-WslHasBash
    }
    catch {
        if ($_.Exception.Message -match '^WslMissingBash: ') {
            Write-Host (
                $_.Exception.Message -replace '^WslMissingBash: ',''
            ) -ForegroundColor Yellow
            return 1
        }
        throw
    }

    # /mnt/c perm gate. Runs after the WSL/bash gates (so we know the
    # default distro is sane) and before the second-stage bash
    # bootstrap (so the bash bootstrap and subsequent ansible-playbook
    # runs see the corrected 0755 dirs instead of 0777). Idempotent;
    # a second bootstrap run after the first finds 'metadata' already
    # in the config and no-ops without sudo.
    Set-WslAutomountMetadata

    # Second stage runs inside WSL against the repo root.
    #
    # `| Out-Host`, not bare `& wsl -- ...`: the outer script ends with
    # `exit (Invoke-BootstrapController)`, which wraps the function call
    # in a subexpression. Subexpressions collect the function's entire
    # pipeline output before passing it to `exit`. Bare `& wsl -- ...`
    # sends every stdout line of the bash script into that pipeline -
    # the integer return value is the last element, exit consumes that,
    # and every line of pip / ansible-galaxy / summary output is silently
    # discarded. Piping to Out-Host writes the wsl stream directly to
    # the host's display, bypassing the pipeline; only the return value
    # flows up to `exit`. $LASTEXITCODE is set by the native command and
    # is unaffected by the Out-Host cmdlet downstream.
    $bashScript = './ops/_bootstrap-controller-wsl.sh'
    Push-Location $RepoRoot
    try {
        & wsl -- $bashScript | Out-Host
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

# Top-level invocation guard. $MyInvocation.InvocationName is '.' when
# the file is dot-sourced (the test-loading path) and the script's own
# path otherwise. Skipping the call under dot-source keeps `exit` out
# of the Pester runner process.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-BootstrapController)
}
