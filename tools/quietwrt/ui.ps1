function Show-QuietWrtStatus {
    param(
        $Status
    )

    $routerTime = if ($Status.PSObject.Properties['router_time'] -and -not [string]::IsNullOrWhiteSpace([string]$Status.router_time)) {
        [string]$Status.router_time
    } else {
        'unknown'
    }

    Write-Host ''
    Write-Host 'QuietWrt Status'
    Write-Host "  Installed: $(if ($Status.installed) { 'yes' } else { 'no' })"
    Write-Host "  Router time: $routerTime"

    $protection = if ($null -eq $Status.protection_enabled) {
        'unknown'
    } elseif ($Status.protection_enabled) {
        'enabled'
    } else {
        'disabled'
    }

    Write-Host "  Protection: $protection"
    Write-Host "  Enforcement ready: $(if ($Status.enforcement_ready) { 'yes' } else { 'no' })"
    Write-Host "  Always blocklist: $(if ($Status.always_enabled) { 'enabled' } else { 'disabled' })"

    foreach ($definition in (Get-QuietWrtScheduleDefinitions)) {
        Write-Host "  $($definition.StatusLabel): $(if ($Status.($definition.EnabledProperty)) { 'enabled' } else { 'disabled' })"
        Write-Host "  $($definition.ActiveLabel): $(if ($Status.($definition.ActiveProperty)) { 'yes' } else { 'no' })"

        $window = Get-QuietWrtScheduleWindow -Status $Status -ScheduleName $definition.Name
        if ($window) {
            $windowLabel = Get-QuietWrtScheduleLabel -ScheduleName $definition.Name -Window $window
            Write-Host "  $windowLabel window: $(Get-QuietWrtWindowSummary -Window $window)"
        }
    }

    Write-Host "  Always entries: $($Status.always_count)"
    foreach ($definition in (Get-QuietWrtScheduleDefinitions)) {
        if ($definition.CountProperty) {
            Write-Host "  $($definition.CountLabel): $($Status.($definition.CountProperty))"
        }
    }
    Write-Host "  Active rules: $($Status.active_rule_count)"
    Write-Host "  DNS intercept hardening: $(if ($Status.hardening.dns_intercept) { 'yes' } else { 'no' })"
    Write-Host "  DoT blocking hardening: $(if ($Status.hardening.dot_block) { 'yes' } else { 'no' })"
    Write-Host "  Overnight firewall rule present: $(if ($Status.hardening.overnight_rule) { 'yes' } else { 'no' })"

    foreach ($warning in @($Status.warnings)) {
        Write-Warning $warning
    }
}

function Get-QuietWrtMenuLines {
    param(
        $Status
    )

    return @(
        '1. Install/Update QuietWrt'
        "2. $(if ($Status.always_enabled) { 'Disable' } else { 'Enable' }) always-on blocklist"
        "3. $(if ($Status.workday_enabled) { 'Disable' } else { 'Enable' }) workday blocklist"
        "4. $(if ($Status.after_work_enabled) { 'Disable' } else { 'Enable' }) after-work blocklist"
        "5. $(if ($Status.password_vault_enabled) { 'Disable' } else { 'Enable' }) password vault blocklist"
        "6. $(if ($Status.overnight_enabled) { 'Disable' } else { 'Enable' }) overnight blocking"
        '7. Set workday window'
        '8. Set after-work window'
        '9. Set password vault window'
        '10. Set overnight window'
        '11. Backup all blocklists to this PC'
        '12. Restore latest backup'
        '0. Exit'
    )
}

function Show-QuietWrtMenu {
    param(
        $Status
    )

    Write-Host ''
    Write-Host 'Menu'
    foreach ($line in (Get-QuietWrtMenuLines -Status $Status)) {
        Write-Host "  $line"
    }
}

function Invoke-QuietWrtMenuSelection {
    param(
        [string]$Selection,
        $Connection,
        $Status,
        [string]$BackupDirectory = (Get-QuietWrtBackupDirectory)
    )

    switch ($Selection) {
        '1' {
            $updatedStatus = Install-QuietWrtOnRouter -Connection $Connection
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '2' {
            $updatedStatus = Set-QuietWrtToggleState -Connection $Connection -ToggleName 'always' -Enabled (-not [bool]$Status.always_enabled)
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '3' {
            $updatedStatus = Set-QuietWrtToggleState -Connection $Connection -ToggleName 'workday' -Enabled (-not [bool]$Status.workday_enabled)
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '4' {
            $updatedStatus = Set-QuietWrtToggleState -Connection $Connection -ToggleName 'after_work' -Enabled (-not [bool]$Status.after_work_enabled)
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '5' {
            $updatedStatus = Set-QuietWrtToggleState -Connection $Connection -ToggleName 'password_vault' -Enabled (-not [bool]$Status.password_vault_enabled)
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '6' {
            $updatedStatus = Set-QuietWrtToggleState -Connection $Connection -ToggleName 'overnight' -Enabled (-not [bool]$Status.overnight_enabled)
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '7' {
            $updatedStatus = Update-QuietWrtScheduleWindow -Connection $Connection -ScheduleName 'workday' -Status $Status
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '8' {
            $updatedStatus = Update-QuietWrtScheduleWindow -Connection $Connection -ScheduleName 'after_work' -Status $Status
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '9' {
            $updatedStatus = Update-QuietWrtScheduleWindow -Connection $Connection -ScheduleName 'password_vault' -Status $Status
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '10' {
            $updatedStatus = Update-QuietWrtScheduleWindow -Connection $Connection -ScheduleName 'overnight' -Status $Status
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '11' {
            $backupPaths = Backup-QuietWrtBlocklists -Connection $Connection -OutputDirectory $BackupDirectory
            Write-Host ''
            Write-Host 'Saved backups:'
            Write-Host "  $($backupPaths.Always)"
            Write-Host "  $($backupPaths.Workday)"
            Write-Host "  $($backupPaths.AfterWork)"
            Write-Host "  $($backupPaths.PasswordVault)"
            return [pscustomobject]@{
                Continue = $true
                Status = $Status
                BackupPaths = $backupPaths
            }
        }
        '12' {
            $updatedStatus = Restore-QuietWrtBlocklists -Connection $Connection -BackupDirectory $BackupDirectory
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '0' {
            return [pscustomobject]@{
                Continue = $false
                Status = $Status
                BackupPaths = $null
            }
        }
        default {
            throw "Unknown menu selection: $Selection"
        }
    }
}

function Start-QuietWrtCli {
    Import-QuietWrtDependencies

    $routerHost = Read-Host -Prompt "Router host [$DefaultRouterHost]"
    if ([string]::IsNullOrWhiteSpace($routerHost)) {
        $routerHost = $DefaultRouterHost
    }

    $routerUser = Read-Host -Prompt "Router username [$DefaultRouterUser]"
    if ([string]::IsNullOrWhiteSpace($routerUser)) {
        $routerUser = $DefaultRouterUser
    }

    $credential = New-QuietWrtCredential -UserName $routerUser
    $connection = $null

    try {
        $connection = Connect-QuietWrtRouter -RouterHost $routerHost -RouterUser $routerUser -RouterPort $DefaultRouterPort -Credential $credential
        $status = Get-QuietWrtStatus -Connection $connection
        Show-QuietWrtStatus -Status $status

        while ($true) {
            Show-QuietWrtMenu -Status $status
            $selection = Read-Host -Prompt 'Choose an option'

            try {
                $result = Invoke-QuietWrtMenuSelection -Selection $selection -Connection $connection -Status $status -BackupDirectory (Get-QuietWrtBackupDirectory)
                $status = $result.Status

                if (-not $result.Continue) {
                    break
                }
            } catch {
                Write-Error $_
            }
        }
    } finally {
        Disconnect-QuietWrtRouter -Connection $connection
    }
}
