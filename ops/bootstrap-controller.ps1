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

    # Ensure PowerShell.Common is available before importing. Installed
    # on demand so a fresh host needs only this script (no separate
    # setup). Guarded with Get-Module to keep reruns fast.
    $commonModule = Get-Module -ListAvailable -Name PowerShell.Common |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $commonModule) {
        Install-Module PowerShell.Common -Scope CurrentUser -Force `
            -AllowClobber -ErrorAction Stop
    }
    Import-Module PowerShell.Common -ErrorAction Stop

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

    # Second stage runs inside WSL against the repo root.
    $bashScript = './ops/_bootstrap-controller-wsl.sh'
    Push-Location $RepoRoot
    try {
        & wsl -- $bashScript
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
