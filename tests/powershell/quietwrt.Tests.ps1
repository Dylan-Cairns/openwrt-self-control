$scriptPath = Join-Path $PSScriptRoot '..\..\tools\quietwrt.ps1'
. $scriptPath

Describe 'QuietWrt PowerShell CLI' {
    It 'renders menu lines that reflect current toggle states' {
        $status = [pscustomobject]@{
            always_enabled = $true
            workday_enabled = $false
            after_work_enabled = $true
            overnight_enabled = $true
        }

        $lines = Get-QuietWrtMenuLines -Status $status

        $lines[0] | Should Be '1. Install/Update QuietWrt'
        $lines[1] | Should Be '2. Disable always-on blocklist'
        $lines[2] | Should Be '3. Enable workday blocklist'
        $lines[3] | Should Be '4. Disable after-work blocklist'
        $lines[4] | Should Be '5. Disable overnight blocking'
        $lines[8] | Should Be '9. Backup all blocklists to this PC'
        $lines[9] | Should Be '10. Restore latest backup'
    }

    It 'prompts for the router password using visible input when none is supplied' {
        Mock Read-Host { 'pasted-secret' } -ParameterFilter { $Prompt -eq 'Router password for root' }

        $credential = New-QuietWrtCredential -UserName 'root'

        $credential.UserName | Should Be 'root'
        $credential.GetNetworkCredential().Password | Should Be 'pasted-secret'
        Assert-MockCalled Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -eq 'Router password for root' }
    }

    It 'returns a not-installed placeholder when quietwrtctl is absent' {
        Mock Test-QuietWrtCliPresent { $false }

        $status = Get-QuietWrtStatus -Connection ([pscustomobject]@{})

        $status.installed | Should Be $false
        $status.enforcement_ready | Should Be $false
        $status.after_work_enabled | Should Be $false
    }

    It 'renders placeholder status without schedule property errors' {
        Mock Write-Host { }
        Mock Write-Warning { }

        { Show-QuietWrtStatus -Status (New-QuietWrtStatusPlaceholder) } | Should Not Throw
    }

    It 'preserves schedule and enforcement readiness from quietwrtctl status output' {
        Mock Test-QuietWrtCliPresent { $true }
        Mock Invoke-QuietWrtRemote {
            [pscustomobject]@{
                ExitStatus = 0
                Output = '{"installed":true,"protection_enabled":false,"enforcement_ready":false,"always_enabled":true,"workday_enabled":false,"after_work_enabled":true,"overnight_enabled":true,"workday_active":false,"after_work_active":true,"overnight_active":false,"always_count":1,"workday_count":0,"after_work_count":1,"active_rule_count":2,"schedule":{"workday":{"start":"0400","end":"1630","display_start":"04:00","display_end":"16:30","overnight":false},"after_work":{"start":"1630","end":"1900","display_start":"16:30","display_end":"19:00","overnight":false},"overnight":{"start":"1900","end":"0400","display_start":"19:00","display_end":"04:00","overnight":true}},"hardening":{"dns_intercept":true,"dot_block":true,"overnight_rule":true},"warnings":["AdGuard Home protection is disabled."]}'
                Raw = $null
            }
        }

        $status = Get-QuietWrtStatus -Connection ([pscustomobject]@{})

        $status.enforcement_ready | Should Be $false
        $status.protection_enabled | Should Be $false
        $status.schedule.after_work.start | Should Be '1630'
        $status.after_work_active | Should Be $true
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

    It 'formats schedule windows and marks overnight ranges' {
        (Get-QuietWrtWindowSummary -Start '1630' -End '1900') | Should Be '16:30 to 19:00'
        (Get-QuietWrtWindowSummary -Start '1900' -End '0400') | Should Be '19:00 to 04:00 (overnight)'
    }

    It 'dispatches the after-work toggle menu action to the router control plane' {
        $status = [pscustomobject]@{
            always_enabled = $true
            workday_enabled = $true
            after_work_enabled = $true
            overnight_enabled = $true
        }
        $updatedStatus = [pscustomobject]@{
            installed = $true
            always_enabled = $true
            workday_enabled = $true
            after_work_enabled = $false
            overnight_enabled = $true
            protection_enabled = $true
            workday_active = $false
            after_work_active = $false
            overnight_active = $false
            always_count = 1
            workday_count = 0
            after_work_count = 0
            active_rule_count = 1
            schedule = [pscustomobject]@{}
            hardening = [pscustomobject]@{
                dns_intercept = $true
                dot_block = $true
                overnight_rule = $true
            }
            warnings = @()
        }

        Mock Set-QuietWrtToggleState { $updatedStatus } -ParameterFilter { $ToggleName -eq 'after_work' -and $Enabled -eq $false }
        Mock Show-QuietWrtStatus { }

        $result = Invoke-QuietWrtMenuSelection -Selection '4' -Connection ([pscustomobject]@{}) -Status $status -BackupDirectory $TestDrive

        $result.Status.after_work_enabled | Should Be $false
        Assert-MockCalled Set-QuietWrtToggleState -Times 1 -Exactly
    }

    It 'dispatches install/update from the menu and returns the updated status' {
        $status = New-QuietWrtStatusPlaceholder
        $updatedStatus = [pscustomobject]@{
            installed = $true
            always_enabled = $true
            workday_enabled = $true
            after_work_enabled = $true
            overnight_enabled = $true
            protection_enabled = $true
            workday_active = $false
            after_work_active = $true
            overnight_active = $false
            always_count = 2
            workday_count = 3
            after_work_count = 4
            active_rule_count = 9
            schedule = [pscustomobject]@{}
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

    It 'prompts validates confirms and applies a schedule update' {
        $status = [pscustomobject]@{
            schedule = [pscustomobject]@{
                overnight = [pscustomobject]@{
                    start = '1900'
                    end = '0400'
                }
            }
        }
        $updatedStatus = [pscustomobject]@{ installed = $true }

        $script:startReads = 0
        Mock Read-Host {
            $script:startReads += 1
            if ($script:startReads -eq 1) { return '2500' }
            return '1930'
        } -ParameterFilter { $Prompt -eq 'Overnight start time (HHMM)' }
        Mock Read-Host { '0500' } -ParameterFilter { $Prompt -eq 'Overnight end time (HHMM)' }
        Mock Read-Host { 'y' } -ParameterFilter { $Prompt -eq 'Apply this schedule window? [y/N]' }
        Mock Write-Warning { }
        Mock Set-QuietWrtScheduleState { $updatedStatus } -ParameterFilter { $ScheduleName -eq 'overnight' -and $Start -eq '1930' -and $End -eq '0500' }

        $result = Update-QuietWrtScheduleWindow -Connection ([pscustomobject]@{}) -ScheduleName 'overnight' -Status $status

        $result.installed | Should Be $true
        Assert-MockCalled Write-Warning -Times 1 -Exactly
        Assert-MockCalled Set-QuietWrtScheduleState -Times 1 -Exactly
    }

    It 'creates timestamped backup filenames' {
        $names = Get-QuietWrtBackupFileNames -OutputDirectory 'C:\temp' -Timestamp ([datetime]'2026-04-10T08:09:10')

        $names.Always | Should Be 'C:\temp\quietwrt-always-2026-04-10-080910.txt'
        $names.Workday | Should Be 'C:\temp\quietwrt-workday-2026-04-10-080910.txt'
        $names.AfterWork | Should Be 'C:\temp\quietwrt-after-work-2026-04-10-080910.txt'
    }

    It 'selects the newest backup file for each list type' {
        $null = New-Item -ItemType Directory -Path $TestDrive -Force
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-always-2026-04-09-080910.txt') -Value 'a'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-always-2026-04-10-080910.txt') -Value 'b'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-workday-2026-04-08-080910.txt') -Value 'c'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-workday-2026-04-11-080910.txt') -Value 'd'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-after-work-2026-04-07-080910.txt') -Value 'e'
        Set-Content -LiteralPath (Join-Path $TestDrive 'quietwrt-after-work-2026-04-12-080910.txt') -Value 'f'

        $selection = Get-QuietWrtLatestBackupSelection -BackupDirectory $TestDrive

        $selection.Always.Name | Should Be 'quietwrt-always-2026-04-10-080910.txt'
        $selection.Workday.Name | Should Be 'quietwrt-workday-2026-04-11-080910.txt'
        $selection.AfterWork.Name | Should Be 'quietwrt-after-work-2026-04-12-080910.txt'
    }

    It 'throws if a backup source file is missing on the router' {
        Mock Test-QuietWrtInstalled { $true }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 1; Output = '/etc/quietwrt/after-work-blocked.txt'; Raw = $null } }

        { Backup-QuietWrtBlocklists -Connection ([pscustomobject]@{}) -OutputDirectory $TestDrive } | Should Throw 'missing'
    }

    It 'downloads all blocklists and saves them with timestamped names' {
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
            if ($Path -eq '/etc/quietwrt/after-work-blocked.txt') {
                Set-Content -LiteralPath (Join-Path $Destination 'after-work-blocked.txt') -Value 'after.example' -NoNewline
            }
        }

        $paths = Backup-QuietWrtBlocklists -Connection ([pscustomobject]@{ SftpSession = [pscustomobject]@{} }) -OutputDirectory $TestDrive

        $paths.AfterWork | Should Be $expected.AfterWork
        (Get-Content -LiteralPath $paths.Always -Raw) | Should Be 'always.example'
        (Get-Content -LiteralPath $paths.Workday -Raw) | Should Be 'workday.example'
        (Get-Content -LiteralPath $paths.AfterWork -Raw) | Should Be 'after.example'
    }

    It 'restores the newest available backups to the router after confirmation' {
        $alwaysPath = Join-Path $TestDrive 'quietwrt-always-2026-04-10-080910.txt'
        $workdayPath = Join-Path $TestDrive 'quietwrt-workday-2026-04-11-080910.txt'
        $afterWorkPath = Join-Path $TestDrive 'quietwrt-after-work-2026-04-12-080910.txt'
        Set-Content -LiteralPath $alwaysPath -Value 'always.example' -NoNewline
        Set-Content -LiteralPath $workdayPath -Value 'workday.example' -NoNewline
        Set-Content -LiteralPath $afterWorkPath -Value 'after.example' -NoNewline

        $updatedStatus = [pscustomobject]@{
            installed = $true
            always_enabled = $true
            workday_enabled = $true
            after_work_enabled = $true
            overnight_enabled = $true
            protection_enabled = $true
            workday_active = $false
            after_work_active = $true
            overnight_active = $false
            always_count = 1
            workday_count = 1
            after_work_count = 1
            active_rule_count = 3
            schedule = [pscustomobject]@{}
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
                AfterWork = Get-Item -LiteralPath $afterWorkPath
            }
        }
        Mock Read-Host { 'y' }
        Mock Send-QuietWrtSftpItem { }
        Mock Invoke-QuietWrtRemote { [pscustomobject]@{ ExitStatus = 0; Output = ''; Raw = $null } }
        Mock Get-QuietWrtStatus { $updatedStatus }

        $status = Restore-QuietWrtBlocklists -Connection ([pscustomobject]@{ SftpSession = [pscustomobject]@{} }) -BackupDirectory $TestDrive

        $status.installed | Should Be $true
        Assert-MockCalled Send-QuietWrtSftpItem -Times 3 -Exactly
        Assert-MockCalled Invoke-QuietWrtRemote -Times 1 -ParameterFilter { $Command -match '^mkdir -p /tmp/quietwrt-restore-' }
        Assert-MockCalled Invoke-QuietWrtRemote -Times 1 -ParameterFilter { $Command -match 'quietwrtctl restore --always ' -and $Command -match '--workday ' -and $Command -match '--after-work ' }
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
