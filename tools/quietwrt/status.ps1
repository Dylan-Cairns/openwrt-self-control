function New-QuietWrtStatusPlaceholder {
    param(
        [bool]$Installed = $false
    )

    return [pscustomobject]@{
        installed = $Installed
        protection_enabled = $null
        enforcement_ready = $false
        always_enabled = $false
        workday_enabled = $false
        after_work_enabled = $false
        password_vault_enabled = $false
        overnight_enabled = $false
        workday_active = $false
        after_work_active = $false
        password_vault_active = $false
        overnight_active = $false
        always_count = 0
        workday_count = 0
        after_work_count = 0
        password_vault_count = 0
        active_rule_count = 0
        schedule = [pscustomobject]@{
            workday = $null
            after_work = $null
            password_vault = $null
            overnight = $null
        }
        hardening = [pscustomobject]@{
            dns_intercept = $false
            dot_block = $false
            overnight_rule = $false
        }
        warnings = @()
    }
}

function Complete-QuietWrtStatus {
    param(
        $Status
    )

    if ($null -eq $Status) {
        return New-QuietWrtStatusPlaceholder
    }

    $installedProperty = $Status.PSObject.Properties['installed']
    $merged = New-QuietWrtStatusPlaceholder -Installed ([bool]($installedProperty -and $installedProperty.Value))

    foreach ($property in $Status.PSObject.Properties) {
        $merged | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }

    $mergedSchedule = [pscustomobject]@{
        workday = $null
        after_work = $null
        password_vault = $null
        overnight = $null
    }

    $scheduleProperty = $Status.PSObject.Properties['schedule']
    if ($scheduleProperty -and $scheduleProperty.Value) {
        foreach ($property in $scheduleProperty.Value.PSObject.Properties) {
            $mergedSchedule | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    $merged.schedule = $mergedSchedule

    $mergedHardening = [pscustomobject]@{
        dns_intercept = $false
        dot_block = $false
        overnight_rule = $false
    }

    $hardeningProperty = $Status.PSObject.Properties['hardening']
    if ($hardeningProperty -and $hardeningProperty.Value) {
        foreach ($property in $hardeningProperty.Value.PSObject.Properties) {
            $mergedHardening | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    $merged.hardening = $mergedHardening

    $warningsProperty = $Status.PSObject.Properties['warnings']
    if ($warningsProperty -and $null -ne $warningsProperty.Value) {
        $merged.warnings = @($warningsProperty.Value)
    } else {
        $merged.warnings = @()
    }

    return $merged
}

function Test-QuietWrtCliPresent {
    param(
        $Connection
    )

    $result = Invoke-QuietWrtRemote -Connection $Connection -Command @'
if [ -x /usr/bin/quietwrtctl ]; then
  echo yes
else
  echo no
fi
'@

    return $result.Output -eq 'yes'
}

function ConvertFrom-QuietWrtKeyValueLines {
    param(
        [string]$Text
    )

    $map = @{}

    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $map[$parts[0]] = $parts[1]
        }
    }

    return $map
}

function Get-QuietWrtStatus {
    param(
        $Connection
    )

    if (-not (Test-QuietWrtCliPresent -Connection $Connection)) {
        return New-QuietWrtStatusPlaceholder
    }

    $result = Invoke-QuietWrtRemote -Connection $Connection -Command '/usr/bin/quietwrtctl status --json'

    try {
        return Complete-QuietWrtStatus -Status ($result.Output | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "quietwrtctl status --json returned invalid JSON: $($result.Output)"
    }
}

function Test-QuietWrtInstalled {
    param(
        $Connection
    )

    return [bool](Get-QuietWrtStatus -Connection $Connection).installed
}
