function Get-QuietWrtRepoRoot {
    return $script:QuietWrtRepoRoot
}

function Get-QuietWrtBackupDirectory {
    return (Join-Path (Get-QuietWrtRepoRoot) 'backups')
}

function Get-QuietWrtScheduleDefinitions {
    return @(
        [pscustomobject]@{
            Name = 'workday'
            Label = 'Workday'
            StatusLabel = 'Workday blocklist'
            EnabledProperty = 'workday_enabled'
            ActiveProperty = 'workday_active'
            ActiveLabel = 'Workday active now'
            CountProperty = 'workday_count'
            CountLabel = 'Workday entries'
        }
        [pscustomobject]@{
            Name = 'after_work'
            Label = 'After work'
            StatusLabel = 'After work blocklist'
            EnabledProperty = 'after_work_enabled'
            ActiveProperty = 'after_work_active'
            ActiveLabel = 'After work active now'
            CountProperty = 'after_work_count'
            CountLabel = 'After work entries'
        }
        [pscustomobject]@{
            Name = 'password_vault'
            Label = 'Password vault'
            StatusLabel = 'Password vault blocklist'
            EnabledProperty = 'password_vault_enabled'
            ActiveProperty = 'password_vault_active'
            ActiveLabel = 'Password vault active now'
            CountProperty = 'password_vault_count'
            CountLabel = 'Password vault entries'
        }
        [pscustomobject]@{
            Name = 'overnight'
            Label = 'Overnight'
            StatusLabel = 'Overnight blocking'
            EnabledProperty = 'overnight_enabled'
            ActiveProperty = 'overnight_active'
            ActiveLabel = 'Overnight active now'
            CountProperty = $null
            CountLabel = $null
        }
    )
}

function Get-QuietWrtScheduleDefinition {
    param(
        [string]$ScheduleName
    )

    foreach ($definition in (Get-QuietWrtScheduleDefinitions)) {
        if ($definition.Name -eq $ScheduleName) {
            return $definition
        }
    }

    return $null
}

function Get-QuietWrtPayload {
    $repoRoot = Get-QuietWrtRepoRoot
    $payload = [ordered]@{
        Cgi = Join-Path $repoRoot 'app\quietwrt.cgi'
        Cli = Join-Path $repoRoot 'app\quietwrtctl.lua'
        InitScript = Join-Path $repoRoot 'app\quietwrt.init'
        ModuleDir = Join-Path $repoRoot 'app\quietwrt'
    }

    foreach ($path in $payload.Values) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "QuietWrt payload file is missing: $path"
        }
    }

    return [pscustomobject]$payload
}
