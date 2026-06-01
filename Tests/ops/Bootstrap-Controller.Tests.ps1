BeforeAll {
    # Stub PowerShell.Common surface used by the script under test so
    # the tests do not need the real module installed. The script
    # dot-source path goes through Get-Module / Install-Module / Import-
    # Module / Assert-Wsl2Ready - all of which are mocked per test.
    function Assert-Wsl2Ready { }

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
