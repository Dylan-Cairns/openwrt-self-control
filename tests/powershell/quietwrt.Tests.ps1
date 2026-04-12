$scriptPath = Join-Path $PSScriptRoot '..\..\tools\quietwrt.ps1'
. $scriptPath

Describe 'QuietWrt PowerShell CLI' {
    It 'renders menu lines that reflect current toggle states' {
        $status = [pscustomobject]@{
            always_enabled = $true
            workday_enabled = $false
            overnight_enabled = $true
        }

        $lines = Get-QuietWrtMenuLines -Status $status

        $lines[0] | Should Be '1. Install/Update QuietWrt'
        $lines[1] | Should Be '2. Disable always-on blocklist'
        $lines[2] | Should Be '3. Enable workday blocklist'
        $lines[3] | Should Be '4. Disable overnight blocking'
        $lines[4] | Should Be '5. Backup both blocklists to this PC'
        $lines[5] | Should Be '6. Restore latest backup'
    }

    It 'returns a not-installed placeholder when quietwrtctl is absent' {
        Mock Test-QuietWrtCliPresent { $false }

        $status = Get-QuietWrtStatus -Connection ([pscustomobject]@{})

        $status.installed | Should Be $false
        $status.mode | Should Be 'not_installed'
        $status.enforcement_ready | Should Be $false
    }

    It 'preserves the enforcement readiness flag from quietwrtctl status output' {
        Mock Test-QuietWrtCliPresent { $true }
        Mock Invoke-QuietWrtRemote {
            [pscustomobject]@{
                ExitStatus = 0
                Output = '{"installed":true,"mode":"always_only","mode_label":"Always only","scheduled_mode":"always_only","protection_enabled":false,"enforcement_ready":false,"always_enabled":true,"workday_enabled":false,"overnight_enabled":true,"always_count":1,"workday_count":0,"active_rule_count":1,"hardening":{"dns_intercept":true,"dot_block":true,"overnight_rule":true},"warnings":["AdGuard Home protection is disabled."]}'
                Raw = $null
            }
        }

        $status = Get-QuietWrtStatus -Connection ([pscustomobject]@{})

        $status.enforcement_ready | Should Be $false
        $status.protection_enabled | Should Be $false
    }

    It 'throws when quietwrtctl status returns invalid json' {
        Mock Test-QuietWrtCliPresent { $true }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 0; Output = 'not-json'; Raw = $null } }

        { Get-QuietWrtStatus -Connection ([pscustomobject]@{}) } | Should Throw 'invalid JSON'
    }

    It 'throws a clear error when ssh session creation fails' {
        Mock Import-QuietWrtDependencies { }
        Mock New-QuietWrtSshSession { throw 'boom' }

        $credential = New-Object System.Management.Automation.PSCredential(
            'root',
            (ConvertTo-SecureString 'secret' -AsPlainText -Force)
        )

        { Connect-QuietWrtRouter -RouterHost '192.168.8.1' -RouterUser 'root' -RouterPort 22 -Credential $credential } | Should Throw 'Could not connect'
    }

    It 'dispatches the workday toggle menu action to the router control plane' {
        $status = [pscustomobject]@{
            always_enabled = $true
            workday_enabled = $true
            overnight_enabled = $true
        }
        $updatedStatus = [pscustomobject]@{
            installed = $true
            always_enabled = $true
            workday_enabled = $false
            overnight_enabled = $true
            mode_label = 'Always only'
            protection_enabled = $true
            always_count = 1
            workday_count = 0
            active_rule_count = 1
            hardening = [pscustomobject]@{
                dns_intercept = $true
                dot_block = $true
                overnight_rule = $true
            }
            warnings = @()
        }

        Mock Set-QuietWrtToggleState { $updatedStatus } -ParameterFilter { $ToggleName -eq 'workday' -and $Enabled -eq $false }
        Mock Show-QuietWrtStatus { }

        $result = Invoke-QuietWrtMenuSelection -Selection '3' -Connection ([pscustomobject]@{}) -Status $status -BackupDirectory $TestDrive

        $result.Status.workday_enabled | Should Be $false
        Assert-MockCalled Set-QuietWrtToggleState -Times 1 -Exactly
    }

    It 'dispatches install/update from the menu and returns the updated status' {
        $status = New-QuietWrtStatusPlaceholder
        $updatedStatus = [pscustomobject]@{
            installed = $true
            always_enabled = $true
            workday_enabled = $true
            overnight_enabled = $true
            mode_label = 'Always + Workday'
            protection_enabled = $true
            always_count = 2
            workday_count = 3
            active_rule_count = 5
            hardening = [pscustomobject]@{
                dns_intercept = $true
                dot_block = $true
                overnight_rule = $false
            }
            warnings = @()
        }

        Mock Install-QuietWrtOnRouter { $updatedStatus }
        Mock Show-QuietWrtStatus { }

        $result = Invoke-QuietWrtMenuSelection -Selection '1' -Connection ([pscustomobject]@{}) -Status $status -BackupDirectory $TestDrive

        $result.Status.installed | Should Be $true
        Assert-MockCalled Install-QuietWrtOnRouter -Times 1 -Exactly
    }

    It 'creates timestamped backup filenames' {
        $names = Get-QuietWrtBackupFileNames -OutputDirectory 'C:\temp' -Timestamp ([datetime]'2026-04-10T08:09:10')

        $names.Always | Should Be 'C:\temp\quietwrt-always-2026-04-10-080910.txt'
        $names.Workday | Should Be 'C:\temp\quietwrt-workday-2026-04-10-080910.txt'
    }

    It 'selects the newest backup file for each list type' {
        $null = New-Item -ItemType Directory -Path $TestDrive -Force
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-always-2026-04-09-080910.txt') -Value 'a'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-always-2026-04-10-080910.txt') -Value 'b'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-workday-2026-04-08-080910.txt') -Value 'c'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-workday-2026-04-11-080910.txt') -Value 'd'

        $selection = Get-QuietWrtLatestBackupSelection -BackupDirectory $TestDrive

        $selection.Always.Name | Should Be 'quietwrt-always-2026-04-10-080910.txt'
        $selection.Workday.Name | Should Be 'quietwrt-workday-2026-04-11-080910.txt'
    }

    It 'throws if a backup source file is missing on the router' {
        Mock Test-QuietWrtInstalled { $true }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 1; Output = '/etc/quietwrt/workday-blocked.txt'; Raw = $null } }

        { Backup-QuietWrtBlocklists -Connection ([pscustomobject]@{}) -OutputDirectory $TestDrive } | Should Throw 'missing'
    }

    It 'downloads both blocklists and saves them with timestamped names' {
        $now = [datetime]'2026-04-10T08:09:10'
        $expected = Get-QuietWrtBackupFileNames -OutputDirectory $TestDrive -Timestamp $now

        Mock Test-QuietWrtInstalled { $true }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 0; Output = ''; Raw = $null } }
        Mock Get-QuietWrtBackupFileNames { $expected }
        Mock Receive-QuietWrtSftpItem {
            param($Session, $Path, $Destination)
            if ($Path -eq '/etc/quietwrt/always-blocked.txt') {
                Set-Content -LiteralPath (Join-Path $Destination 'always-blocked.txt') -Value 'always.example' -NoNewline
            }
            if ($Path -eq '/etc/quietwrt/workday-blocked.txt') {
                Set-Content -LiteralPath (Join-Path $Destination 'workday-blocked.txt') -Value 'workday.example' -NoNewline
            }
        }

        $paths = Backup-QuietWrtBlocklists -Connection ([pscustomobject]@{ SftpSession = [pscustomobject]@{} }) -OutputDirectory $TestDrive

        $paths.Always | Should Be $expected.Always
        $paths.Workday | Should Be $expected.Workday
        (Get-Content -LiteralPath $paths.Always -Raw) | Should Be 'always.example'
        (Get-Content -LiteralPath $paths.Workday -Raw) | Should Be 'workday.example'
    }

    It 'restores the newest available backups to the router after confirmation' {
        $alwaysPath = Join-Path $TestDrive 'quietwrt-always-2026-04-10-080910.txt'
        $workdayPath = Join-Path $TestDrive 'quietwrt-workday-2026-04-11-080910.txt'
        Set-Content -LiteralPath $alwaysPath -Value 'always.example' -NoNewline
        Set-Content -LiteralPath $workdayPath -Value 'workday.example' -NoNewline

        $updatedStatus = [pscustomobject]@{
            installed = $true
            always_enabled = $true
            workday_enabled = $true
            overnight_enabled = $true
            mode_label = 'Always + Workday'
            protection_enabled = $true
            always_count = 1
            workday_count = 1
            active_rule_count = 2
            hardening = [pscustomobject]@{
                dns_intercept = $true
                dot_block = $true
                overnight_rule = $false
            }
            warnings = @()
        }

        Mock Test-QuietWrtInstalled { $true }
        Mock Get-QuietWrtLatestBackupSelection {
            [pscustomobject]@{
                Directory = $TestDrive
                Always = Get-Item -LiteralPath $alwaysPath
                Workday = Get-Item -LiteralPath $workdayPath
            }
        }
        Mock Read-Host { 'y' }
        Mock Send-QuietWrtSftpItem { }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 0; Output = ''; Raw = $null } }
        Mock Get-QuietWrtStatus { $updatedStatus }

        $status = Restore-QuietWrtBlocklists -Connection ([pscustomobject]@{ SftpSession = [pscustomobject]@{} }) -BackupDirectory $TestDrive

        $status.installed | Should Be $true
        Assert-MockCalled Send-QuietWrtSftpItem -Times 2 -Exactly
        Assert-MockCalled Invoke-QuietWrtRemote -Times 1 -ParameterFilter { $Command -match '^mkdir -p /tmp/quietwrt-restore-' }
        Assert-MockCalled Invoke-QuietWrtRemote -Times 1 -ParameterFilter { $Command -match 'quietwrtctl restore --always ' -and $Command -match '--workday ' }
    }

    It 'uploads the router payload over sftp and stages it into the final paths' {
        $payloadRoot = Join-Path $TestDrive 'payload'
        $moduleDir = Join-Path $payloadRoot 'quietwrt'
        $null = New-Item -ItemType Directory -Path $moduleDir -Force
        $cgiPath = Join-Path $payloadRoot 'quietwrt.cgi'
        $cliPath = Join-Path $payloadRoot 'quietwrtctl.lua'
        $initPath = Join-Path $payloadRoot 'quietwrt.init'
        Set-Content -LiteralPath $cgiPath -Value '#!/usr/bin/lua'
        Set-Content -LiteralPath $cliPath -Value '#!/usr/bin/lua'
        Set-Content -LiteralPath $initPath -Value '#!/bin/sh'
        Set-Content -LiteralPath (Join-Path $moduleDir 'app.lua') -Value 'return {}'

        Mock Get-QuietWrtPayload {
            [pscustomobject]@{
                Cgi = $cgiPath
                Cli = $cliPath
                InitScript = $initPath
                ModuleDir = $moduleDir
            }
        }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 0; Output = ''; Raw = $null } }
        Mock Send-QuietWrtSftpItem { }

        Upload-QuietWrtPayload -Connection ([pscustomobject]@{ SftpSession = [pscustomobject]@{}; SshSession = [pscustomobject]@{} })

        Assert-MockCalled Send-QuietWrtSftpItem -Times 1 -Exactly -ParameterFilter { $Path -eq $cgiPath }
        Assert-MockCalled Send-QuietWrtSftpItem -Times 1 -Exactly -ParameterFilter { $Path -eq $cliPath }
        Assert-MockCalled Send-QuietWrtSftpItem -Times 1 -Exactly -ParameterFilter { $Path -eq $initPath }
        Assert-MockCalled Send-QuietWrtSftpItem -Times 1 -Exactly -ParameterFilter { $Path -eq $moduleDir }
        Assert-MockCalled Invoke-QuietWrtRemote -Times 1 -Exactly -ParameterFilter { $Command -match '^\s*rm -rf /tmp/quietwrt-upload\s+mkdir -p /tmp/quietwrt-upload\s*$' }
        Assert-MockCalled Invoke-QuietWrtRemote -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 120 -and $Command -match 'cp /tmp/quietwrt-upload/quietwrt.init /etc/init.d/quietwrt' }
    }
}
