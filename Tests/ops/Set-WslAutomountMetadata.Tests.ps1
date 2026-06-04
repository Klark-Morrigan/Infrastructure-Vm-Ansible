BeforeAll {
    # wsl stub. The function calls wsl in three shapes:
    #   1. wsl [-d X] -- cat /etc/wsl.conf      (read)
    #   2. wsl [-d X] -- bash -c '<printf|tee>' (write)
    #   3. wsl --shutdown                       (restart)
    # Per-It Mocks replace this with case-specific behaviour.
    function wsl { $global:LASTEXITCODE = 0 }

    . "$PSScriptRoot\..\..\ops\_set-wsl-automount-metadata.ps1"
}

Describe 'Set-WslAutomountMetadata' {

    Context 'metadata already present in [automount]' {

        It 'no-ops when metadata is already configured' {
            # Read returns a wsl.conf that already has the option;
            # no write, no shutdown.
            Mock wsl {
                $global:LASTEXITCODE = 0
                return "[automount]`noptions = `"metadata,umask=22,fmask=11`"`n"
            } -ParameterFilter { $args -contains 'cat' }

            { Set-WslAutomountMetadata } | Should -Not -Throw

            # No bash -c invocation (write) and no --shutdown.
            Should -Invoke wsl -Times 0 `
                -ParameterFilter { $args -contains 'bash' }
            Should -Invoke wsl -Times 0 `
                -ParameterFilter { $args -contains '--shutdown' }
        }
    }

    Context 'no [automount] section at all' {
        # The append branch: wsl.conf either does not exist or has no
        # [automount] header. Function writes the snippet and restarts WSL.

        It 'appends the snippet and shuts WSL down when wsl.conf is empty' {
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') { return '' }
            }

            { Set-WslAutomountMetadata } | Should -Not -Throw

            # Both the bash write and the global shutdown must fire.
            Should -Invoke wsl -Times 1 `
                -ParameterFilter { $args -contains 'bash' }
            Should -Invoke wsl -Times 1 `
                -ParameterFilter { $args -contains '--shutdown' }
        }

        It 'passes -d plus the distro name to the read and write calls when DistroName is supplied' {
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') { return '' }
            }

            Set-WslAutomountMetadata -DistroName 'Ubuntu-24.04'

            Should -Invoke wsl -Times 1 `
                -ParameterFilter {
                    ($args -contains '-d') -and
                    ($args -contains 'Ubuntu-24.04') -and
                    ($args -contains 'cat')
                }
            Should -Invoke wsl -Times 1 `
                -ParameterFilter {
                    ($args -contains '-d') -and
                    ($args -contains 'Ubuntu-24.04') -and
                    ($args -contains 'bash')
                }
        }

        It 'does NOT pass -d to wsl --shutdown even when DistroName is supplied' {
            # --shutdown is global; passing -d is meaningless and a
            # regression here would silently stop only one distro.
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') { return '' }
            }

            Set-WslAutomountMetadata -DistroName 'Ubuntu-24.04'

            Should -Invoke wsl -Times 1 `
                -ParameterFilter {
                    ($args -contains '--shutdown') -and
                    (-not ($args -contains '-d'))
                }
        }

        It 'throws when the bash write fails' {
            # sudo refused, tee failed, etc. The thrown message must
            # surface the exit code so the operator can triage.
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') { return '' }
                if ($args -contains 'bash') { $global:LASTEXITCODE = 7 }
            }

            { Set-WslAutomountMetadata } |
                Should -Throw -ExpectedMessage '*exit 7*'
        }

        It 'throws when wsl --shutdown fails after a successful write' {
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') { return '' }
                if ($args -contains '--shutdown') { $global:LASTEXITCODE = 4 }
            }

            { Set-WslAutomountMetadata } |
                Should -Throw -ExpectedMessage '*wsl --shutdown*exit 4*'
        }
    }

    Context '[automount] present but missing metadata' {
        # The refusal branch: an existing [automount] block (perhaps
        # configured for Docker or by another repo) must not be silently
        # rewritten or duplicated. The function throws with remediation
        # text directing the operator at a manual edit.

        It 'throws without writing or shutting down' {
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') {
                    return "[automount]`noptions = `"umask=22`"`n"
                }
            }

            { Set-WslAutomountMetadata } |
                Should -Throw -ExpectedMessage "*[automount]*"

            Should -Invoke wsl -Times 0 `
                -ParameterFilter { $args -contains 'bash' }
            Should -Invoke wsl -Times 0 `
                -ParameterFilter { $args -contains '--shutdown' }
        }

        It 'mentions the named distro in the thrown message when DistroName is supplied' {
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') {
                    return "[automount]`noptions = `"umask=22`"`n"
                }
            }

            { Set-WslAutomountMetadata -DistroName 'my-distro' } |
                Should -Throw -ExpectedMessage "*my-distro*"
        }

        It 'does not match metadata when it appears under a different section' {
            # Defensive: a `metadata` token under [interop] (or anywhere
            # outside [automount]) must NOT satisfy the metadata-present
            # check, otherwise the function would no-op on an
            # unconfigured automount block.
            Mock wsl {
                $global:LASTEXITCODE = 0
                if ($args -contains 'cat') {
                    return "[interop]`nmetadata = true`n[automount]`noptions = `"umask=22`"`n"
                }
            }

            { Set-WslAutomountMetadata } |
                Should -Throw -ExpectedMessage "*[automount]*"
        }
    }
}
