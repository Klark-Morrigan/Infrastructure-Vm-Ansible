BeforeAll {
    # Stub PowerShell.Common surface used by the script under test so
    # the tests do not need the real module installed. The script
    # dot-source path goes through Get-Module / Install-Module / Import-
    # Module / Invoke-ModuleInstall / Assert-Wsl2Ready - all of which
    # are mocked per test.
    function Assert-Wsl2Ready { }
    function Invoke-ModuleInstall { param([string] $ModuleName) }

    # wsl stub - $args avoids parameter-binding conflicts with the
    # '--' separator and the script path the bootstrap passes through.
    function wsl { $global:LASTEXITCODE = 0 }

    . "$PSScriptRoot\..\..\ops\bootstrap-controller.ps1"
}

Describe 'Invoke-BootstrapController' {

    BeforeEach {
        # Pretend PowerShell.Common is already installed so the install
        # branch never runs in tests. The script only installs when
        # Get-Module -ListAvailable returns nothing.
        Mock Get-Module {
            [PSCustomObject]@{ Name = 'PowerShell.Common'; Version = '6.0.0' }
        } -ParameterFilter { $ListAvailable -and $Name -eq 'PowerShell.Common' }

        Mock Install-Module { }
        Mock Import-Module { }

        # Default Invoke-ModuleInstall to a no-op so the existing WSL
        # gate cases reach Assert-Wsl2Ready as they did before this
        # bootstrap-installs-Infrastructure.Secrets step landed. The
        # dedicated cases below override this mock to assert call args
        # and propagation of throws.
        Mock Invoke-ModuleInstall { }
    }

    Context 'WSL2 is ready' {

        It 'invokes wsl with the bash bootstrap and propagates exit code 0' {
            Mock Assert-Wsl2Ready { }
            Mock wsl { $global:LASTEXITCODE = 0 }

            $code = Invoke-BootstrapController -RepoRoot $TestDrive

            $code | Should -Be 0
            Should -Invoke wsl -Times 1 -ParameterFilter {
                $args -contains './ops/bootstrap-controller.sh'
            }
        }

        It 'propagates non-zero exit code from the bash bootstrap' {
            Mock Assert-Wsl2Ready { }
            Mock wsl { $global:LASTEXITCODE = 42 }

            $code = Invoke-BootstrapController -RepoRoot $TestDrive

            $code | Should -Be 42
        }
    }

    Context 'WSL2 is not ready' {
    # ----------------------------------------------------------------
    # Assert-Wsl2Ready signals "install kicked off, reboot needed" by
    # throwing an error whose message starts with 'Wsl2NotReady: '.
    # The bootstrap treats that as a clean exit (return 0) with a
    # yellow message - reboot is the user's next step, not a failure.

        It 'returns 0 without invoking wsl when Assert-Wsl2Ready throws Wsl2NotReady' {
            Mock Assert-Wsl2Ready {
                throw 'Wsl2NotReady: please reboot'
            }
            Mock wsl { $global:LASTEXITCODE = 0 }

            $code = Invoke-BootstrapController -RepoRoot $TestDrive

            $code | Should -Be 0
            Should -Invoke wsl -Times 0
        }
    }

    Context 'Infrastructure.Secrets module install' {
    # ----------------------------------------------------------------
    # The bash bridge's _read-vault-config.sh imports
    # Infrastructure.Secrets inside its pwsh.exe call but does not
    # install it; the bootstrap is the single place that ensures the
    # module is on the host. Delegated to Invoke-ModuleInstall from
    # PowerShell.Common, which is itself idempotent and retry-wrapped.

        It 'calls Invoke-ModuleInstall once with ModuleName = Infrastructure.Secrets' {
            Mock Assert-Wsl2Ready { }
            Mock wsl { $global:LASTEXITCODE = 0 }

            $null = Invoke-BootstrapController -RepoRoot $TestDrive

            Should -Invoke Invoke-ModuleInstall -Times 1 -ParameterFilter {
                $ModuleName -eq 'Infrastructure.Secrets'
            }
        }

        It 'propagates exceptions from Invoke-ModuleInstall and does not reach Assert-Wsl2Ready' {
            Mock Invoke-ModuleInstall { throw 'PSGallery offline' }
            Mock Assert-Wsl2Ready { }
            Mock wsl { $global:LASTEXITCODE = 0 }

            { Invoke-BootstrapController -RepoRoot $TestDrive } |
                Should -Throw -ExpectedMessage '*PSGallery offline*'

            Should -Invoke Assert-Wsl2Ready -Times 0
            Should -Invoke wsl -Times 0
        }
    }

    Context 'Assert-Wsl2Ready throws an unrelated error' {

        It 'rethrows non-Wsl2NotReady errors' {
            Mock Assert-Wsl2Ready {
                throw 'something else broke'
            }
            Mock wsl { $global:LASTEXITCODE = 0 }

            { Invoke-BootstrapController -RepoRoot $TestDrive } |
                Should -Throw -ExpectedMessage '*something else broke*'

            Should -Invoke wsl -Times 0
        }
    }
}
