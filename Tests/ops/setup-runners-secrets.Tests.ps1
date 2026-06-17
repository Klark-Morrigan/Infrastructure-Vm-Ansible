BeforeAll {
    # The wrapper resolves the sibling repo via $PSScriptRoot/.., so
    # the tests stand up a throwaway directory tree shaped like the
    # real two-repo sibling layout and copy the wrapper into it:
    #
    #   <root>/
    #     Infrastructure-VM-Ansible/ops/setup-runners-secrets.ps1
    #     Infrastructure-GitHubRunners/hyper-v/ubuntu/setup-secrets.ps1
    #
    # The fake delegate is a tiny .ps1 that records its bound parameters
    # to a file (path supplied via env) so the wrapper's arg-forwarding
    # contract can be asserted without installing Common.PowerShell /
    # Infrastructure.Secrets.

    function New-FakeRepoLayout {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [switch] $WithGitHubRunnersSibling
        )

        $opsDir = Join-Path $Root 'Infrastructure-VM-Ansible/ops'
        New-Item -ItemType Directory -Path $opsDir -Force | Out-Null
        $wrapper = Join-Path $opsDir 'setup-runners-secrets.ps1'
        Copy-Item -Path "$PSScriptRoot\..\..\ops\setup-runners-secrets.ps1" `
                  -Destination $wrapper -Force

        if ($WithGitHubRunnersSibling) {
            $siblingDir = Join-Path $Root 'Infrastructure-GitHubRunners/hyper-v/ubuntu'
            New-Item -ItemType Directory -Path $siblingDir -Force | Out-Null
            $delegate = Join-Path $siblingDir 'setup-secrets.ps1'
            # The fake delegate records its bound parameters as a JSON
            # file at $env:FAKE_DELEGATE_LOG. The wrapper invokes it
            # with the splat hashtable, so binding by name is the
            # exact contract worth asserting.
            $body = @'
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')] [string] $ConfigFile,
    [Parameter(Mandatory, ParameterSetName = 'Json')] [string] $ConfigJson,
    [Parameter()]                                     [switch] $RequireVaultPassword,
    [Parameter(Mandatory)]                            [string] $SecretSuffix
)
$record = [ordered]@{
    ParameterSet         = $PSCmdlet.ParameterSetName
    ConfigFile           = $ConfigFile
    ConfigJson           = $ConfigJson
    RequireVaultPassword = [bool]$RequireVaultPassword
    SecretSuffix         = $SecretSuffix
}
$record | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $env:FAKE_DELEGATE_LOG -Encoding UTF8
'@
            Set-Content -LiteralPath $delegate -Value $body -Encoding UTF8
        }

        return $wrapper
    }
}

Describe 'ops/setup-runners-secrets.ps1' {

    BeforeEach {
        # TestDrive is a Pester-provided per-It scratch directory that
        # disappears after the test - perfect for the throwaway two-repo
        # layout we need. Each It gets its own clean root.
        $script:Root = (Join-Path $TestDrive ([guid]::NewGuid().Guid))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

        $script:DelegateLog = Join-Path $TestDrive "delegate-$([guid]::NewGuid().Guid).json"
        $env:FAKE_DELEGATE_LOG = $script:DelegateLog
    }

    AfterEach {
        Remove-Item Env:FAKE_DELEGATE_LOG -ErrorAction SilentlyContinue
    }

    Context 'sibling checkout missing' {

        It 'throws with a clear pointer when Infrastructure-GitHubRunners is not present' {
            $wrapper    = New-FakeRepoLayout -Root $script:Root
            $configPath = Join-Path $TestDrive 'runners.json'
            Set-Content -LiteralPath $configPath -Value '[]' -Encoding UTF8

            { & $wrapper -ConfigFile $configPath -SecretSuffix 'Test' } |
                Should -Throw -ExpectedMessage '*Infrastructure-GitHubRunners setup script not found*'
        }
    }

    Context 'ConfigFile path missing' {
        # The wrapper guards on ConfigFile before resolving the sibling
        # repo so the operator's typo surfaces as a path error rather
        # than the "sibling missing" error.

        It 'throws ConfigFile-not-found before reaching the sibling lookup' {
            $wrapper = New-FakeRepoLayout -Root $script:Root `
                                          -WithGitHubRunnersSibling
            $missing = Join-Path $TestDrive 'does-not-exist.json'

            { & $wrapper -ConfigFile $missing -SecretSuffix 'Test' } |
                Should -Throw -ExpectedMessage "*ConfigFile not found:*$missing*"

            # Delegate must not have run - the log file stays absent.
            Test-Path -LiteralPath $script:DelegateLog | Should -BeFalse
        }
    }

    Context 'sibling present, happy path' {

        It 'forwards -ConfigFile and -SecretSuffix to the delegate' {
            $wrapper    = New-FakeRepoLayout -Root $script:Root `
                                             -WithGitHubRunnersSibling
            $configPath = Join-Path $TestDrive 'runners.json'
            Set-Content -LiteralPath $configPath -Value '[]' -Encoding UTF8

            & $wrapper -ConfigFile $configPath -SecretSuffix 'Test'

            $record = Get-Content -LiteralPath $script:DelegateLog -Raw |
                ConvertFrom-Json
            $record.ParameterSet         | Should -Be 'File'
            $record.ConfigFile           | Should -Be $configPath
            $record.SecretSuffix         | Should -Be 'Test'
            $record.RequireVaultPassword | Should -Be $false
        }

        It 'forwards -ConfigJson when invoked via the Json parameter set' {
            $wrapper = New-FakeRepoLayout -Root $script:Root `
                                          -WithGitHubRunnersSibling

            & $wrapper -ConfigJson '[{"runnerName":"r1"}]' -SecretSuffix 'Test'

            $record = Get-Content -LiteralPath $script:DelegateLog -Raw |
                ConvertFrom-Json
            $record.ParameterSet | Should -Be 'Json'
            $record.ConfigJson   | Should -Be '[{"runnerName":"r1"}]'
            $record.SecretSuffix | Should -Be 'Test'
        }

        It 'forwards -RequireVaultPassword when supplied' {
            $wrapper    = New-FakeRepoLayout -Root $script:Root `
                                             -WithGitHubRunnersSibling
            $configPath = Join-Path $TestDrive 'runners.json'
            Set-Content -LiteralPath $configPath -Value '[]' -Encoding UTF8

            & $wrapper -ConfigFile $configPath -SecretSuffix 'Test' `
                       -RequireVaultPassword

            $record = Get-Content -LiteralPath $script:DelegateLog -Raw |
                ConvertFrom-Json
            $record.RequireVaultPassword | Should -Be $true
        }
    }
}
