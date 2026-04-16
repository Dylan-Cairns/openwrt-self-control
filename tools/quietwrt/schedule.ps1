function Set-QuietWrtToggleState {
    param(
        $Connection,
        [ValidateSet('always', 'workday', 'after_work', 'password_vault', 'overnight')]
        [string]$ToggleName,
        [bool]$Enabled
    )

    if (-not (Test-QuietWrtInstalled -Connection $Connection)) {
        throw 'QuietWrt is not installed on this router.'
    }

    $state = if ($Enabled) { 'on' } else { 'off' }
    Invoke-QuietWrtRemote -Connection $Connection -Command "/usr/bin/quietwrtctl set $ToggleName $state" -TimeoutSeconds 120 | Out-Null
    return Get-QuietWrtStatus -Connection $Connection
}

function Test-QuietWrtScheduleValue {
    param(
        [string]$Value
    )

    if ($Value -notmatch '^\d{4}$') {
        return $false
    }

    $hour = [int]$Value.Substring(0, 2)
    $minute = [int]$Value.Substring(2, 2)
    return $hour -ge 0 -and $hour -le 23 -and $minute -ge 0 -and $minute -le 59
}

function Format-QuietWrtScheduleValue {
    param(
        [string]$Value
    )

    if (-not (Test-QuietWrtScheduleValue -Value $Value)) {
        throw "Invalid QuietWrt schedule value: $Value"
    }

    return '{0}:{1}' -f $Value.Substring(0, 2), $Value.Substring(2, 2)
}

function Get-QuietWrtScheduleLabel {
    param(
        [string]$ScheduleName,
        $Window
    )

    if ($null -ne $Window) {
        $labelProperty = $Window.PSObject.Properties['label']
        if ($labelProperty -and -not [string]::IsNullOrWhiteSpace([string]$labelProperty.Value)) {
            return [string]$labelProperty.Value
        }
    }

    $definition = Get-QuietWrtScheduleDefinition -ScheduleName $ScheduleName
    if ($definition) {
        return $definition.Label
    }

    return [string]$ScheduleName
}

function Get-QuietWrtWindowSummary {
    param(
        $Window,
        [string]$Start,
        [string]$End
    )

    if ($null -ne $Window) {
        $summaryProperty = $Window.PSObject.Properties['summary']
        if ($summaryProperty -and -not [string]::IsNullOrWhiteSpace([string]$summaryProperty.Value)) {
            return [string]$summaryProperty.Value
        }

        $displayStartProperty = $Window.PSObject.Properties['display_start']
        $displayEndProperty = $Window.PSObject.Properties['display_end']
        $overnightProperty = $Window.PSObject.Properties['overnight']
        if (
            $displayStartProperty -and $displayEndProperty `
            -and -not [string]::IsNullOrWhiteSpace([string]$displayStartProperty.Value) `
            -and -not [string]::IsNullOrWhiteSpace([string]$displayEndProperty.Value)
        ) {
            $summary = "$($displayStartProperty.Value) to $($displayEndProperty.Value)"
            if ($overnightProperty -and [bool]$overnightProperty.Value) {
                return "$summary (overnight)"
            }

            return $summary
        }

        $startProperty = $Window.PSObject.Properties['start']
        $endProperty = $Window.PSObject.Properties['end']
        if ($startProperty) {
            $Start = [string]$startProperty.Value
        }
        if ($endProperty) {
            $End = [string]$endProperty.Value
        }
    }

    $summary = "$(Format-QuietWrtScheduleValue -Value $Start) to $(Format-QuietWrtScheduleValue -Value $End)"
    if ($Start -gt $End) {
        return "$summary (overnight)"
    }

    return $summary
}

function Get-QuietWrtScheduleWindow {
    param(
        $Status,
        [ValidateSet('workday', 'after_work', 'password_vault', 'overnight')]
        [string]$ScheduleName
    )

    if ($null -eq $Status) {
        return $null
    }

    $scheduleProperty = $Status.PSObject.Properties['schedule']
    if ($null -eq $scheduleProperty -or $null -eq $scheduleProperty.Value) {
        return $null
    }

    $windowProperty = $scheduleProperty.Value.PSObject.Properties[$ScheduleName]
    if ($null -eq $windowProperty) {
        return $null
    }

    return $windowProperty.Value
}

function Read-QuietWrtScheduleValue {
    param(
        [string]$Prompt
    )

    while ($true) {
        $value = (Read-Host -Prompt $Prompt).Trim()
        if (Test-QuietWrtScheduleValue -Value $value) {
            return $value
        }

        Write-Warning 'Enter a 4-digit military time in HHMM format, for example 1630.'
    }
}

function Set-QuietWrtScheduleState {
    param(
        $Connection,
        [ValidateSet('workday', 'after_work', 'password_vault', 'overnight')]
        [string]$ScheduleName,
        [string]$Start,
        [string]$End
    )

    if (-not (Test-QuietWrtInstalled -Connection $Connection)) {
        throw 'QuietWrt is not installed on this router.'
    }

    Invoke-QuietWrtRemote -Connection $Connection -Command "/usr/bin/quietwrtctl schedule $ScheduleName $Start $End" -TimeoutSeconds 120 | Out-Null
    return Get-QuietWrtStatus -Connection $Connection
}

function Update-QuietWrtScheduleWindow {
    param(
        $Connection,
        [ValidateSet('workday', 'after_work', 'password_vault', 'overnight')]
        [string]$ScheduleName,
        $Status
    )

    $currentWindow = Get-QuietWrtScheduleWindow -Status $Status -ScheduleName $ScheduleName
    $label = Get-QuietWrtScheduleLabel -ScheduleName $ScheduleName -Window $currentWindow

    if ($currentWindow) {
        Write-Host ''
        Write-Host "$label window: $(Get-QuietWrtWindowSummary -Window $currentWindow)"
    }

    $start = Read-QuietWrtScheduleValue -Prompt "$label start time (HHMM)"
    $end = Read-QuietWrtScheduleValue -Prompt "$label end time (HHMM)"

    if ($start -eq $end) {
        throw "$label start and end times must be different."
    }

    $summary = Get-QuietWrtWindowSummary -Start $start -End $end
    Write-Host ''
    Write-Host "$label window: $summary"

    $confirmation = Read-Host -Prompt 'Apply this schedule window? [y/N]'
    if ($confirmation -notin @('y', 'Y', 'yes', 'YES', 'Yes')) {
        throw 'Schedule update cancelled.'
    }

    return Set-QuietWrtScheduleState -Connection $Connection -ScheduleName $ScheduleName -Start $start -End $end
}
