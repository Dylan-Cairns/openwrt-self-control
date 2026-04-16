function Get-QuietWrtBackupFileNames {
    param(
        [string]$OutputDirectory,
        [datetime]$Timestamp = (Get-Date)
    )

    $suffix = $Timestamp.ToString('yyyy-MM-dd-HHmmss')

    return [pscustomobject]@{
        Always = Join-Path $OutputDirectory "quietwrt-always-$suffix.txt"
        Workday = Join-Path $OutputDirectory "quietwrt-workday-$suffix.txt"
        AfterWork = Join-Path $OutputDirectory "quietwrt-after-work-$suffix.txt"
        PasswordVault = Join-Path $OutputDirectory "quietwrt-password-vault-$suffix.txt"
    }
}

function Get-QuietWrtLatestBackupSelection {
    param(
        [string]$BackupDirectory = (Get-QuietWrtBackupDirectory)
    )

    $always = @()
    $workday = @()
    $afterWork = @()
    $passwordVault = @()

    if (Test-Path -LiteralPath $BackupDirectory) {
        $always = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter 'quietwrt-always-*.txt' | Sort-Object Name -Descending)
        $workday = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter 'quietwrt-workday-*.txt' | Sort-Object Name -Descending)
        $afterWork = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter 'quietwrt-after-work-*.txt' | Sort-Object Name -Descending)
        $passwordVault = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter 'quietwrt-password-vault-*.txt' | Sort-Object Name -Descending)
    }

    return [pscustomobject]@{
        Directory = $BackupDirectory
        Always = if ($always.Count -gt 0) { $always[0] } else { $null }
        Workday = if ($workday.Count -gt 0) { $workday[0] } else { $null }
        AfterWork = if ($afterWork.Count -gt 0) { $afterWork[0] } else { $null }
        PasswordVault = if ($passwordVault.Count -gt 0) { $passwordVault[0] } else { $null }
    }
}

function Backup-QuietWrtBlocklists {
    param(
        $Connection,
        [string]$OutputDirectory = (Get-QuietWrtBackupDirectory)
    )

    if (-not (Test-QuietWrtInstalled -Connection $Connection)) {
        throw 'QuietWrt is not installed on this router.'
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force

    $check = Invoke-QuietWrtRemote -Connection $Connection -Command @'
missing=0
for path in /etc/quietwrt/always-blocked.txt /etc/quietwrt/workday-blocked.txt /etc/quietwrt/after-work-blocked.txt /etc/quietwrt/password-vault-blocked.txt; do
  if [ ! -f "$path" ]; then
    echo "$path"
    missing=1
  fi
done
exit $missing
'@ -AllowFailure

    if ($check.ExitStatus -ne 0) {
        throw "QuietWrt backup source file is missing: $($check.Output)"
    }

    $destination = Get-QuietWrtBackupFileNames -OutputDirectory $OutputDirectory
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("quietwrt-backup-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempDir -Force

    try {
        Receive-QuietWrtSftpItem -Session $Connection.SftpSession -Path $script:QuietWrtRemotePaths.AlwaysListPath -Destination $tempDir | Out-Null
        Receive-QuietWrtSftpItem -Session $Connection.SftpSession -Path $script:QuietWrtRemotePaths.WorkdayListPath -Destination $tempDir | Out-Null
        Receive-QuietWrtSftpItem -Session $Connection.SftpSession -Path $script:QuietWrtRemotePaths.AfterWorkListPath -Destination $tempDir | Out-Null
        Receive-QuietWrtSftpItem -Session $Connection.SftpSession -Path $script:QuietWrtRemotePaths.PasswordVaultListPath -Destination $tempDir | Out-Null

        Move-Item -LiteralPath (Join-Path $tempDir 'always-blocked.txt') -Destination $destination.Always -Force
        Move-Item -LiteralPath (Join-Path $tempDir 'workday-blocked.txt') -Destination $destination.Workday -Force
        Move-Item -LiteralPath (Join-Path $tempDir 'after-work-blocked.txt') -Destination $destination.AfterWork -Force
        Move-Item -LiteralPath (Join-Path $tempDir 'password-vault-blocked.txt') -Destination $destination.PasswordVault -Force
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $destination
}

function Restore-QuietWrtBlocklists {
    param(
        $Connection,
        [string]$BackupDirectory = (Get-QuietWrtBackupDirectory)
    )

    if (-not (Test-QuietWrtInstalled -Connection $Connection)) {
        throw 'QuietWrt is not installed on this router.'
    }

    $selection = Get-QuietWrtLatestBackupSelection -BackupDirectory $BackupDirectory
    if ($null -eq $selection.Always -and $null -eq $selection.Workday -and $null -eq $selection.AfterWork -and $null -eq $selection.PasswordVault) {
        throw "No backup files were found in $BackupDirectory."
    }

    Write-Host ''
    Write-Host 'Restore from backups'
    if ($selection.Always) {
        Write-Host "  Always: $($selection.Always.Name)"
    }
    if ($selection.Workday) {
        Write-Host "  Workday: $($selection.Workday.Name)"
    }
    if ($selection.AfterWork) {
        Write-Host "  After work: $($selection.AfterWork.Name)"
    }
    if ($selection.PasswordVault) {
        Write-Host "  Password vault: $($selection.PasswordVault.Name)"
    }

    $confirmation = Read-Host -Prompt 'Restore these backup files to the router? [y/N]'
    if ($confirmation -notin @('y', 'Y', 'yes', 'YES', 'Yes')) {
        throw 'Restore cancelled.'
    }

    $remoteRoot = "/tmp/quietwrt-restore-$([guid]::NewGuid().ToString('N'))"
    Invoke-QuietWrtRemote -Connection $Connection -Command "mkdir -p $remoteRoot" -TimeoutSeconds 30 | Out-Null

    try {
        $restoreArgs = @()

        if ($selection.Always) {
            $remoteAlways = "$remoteRoot/$($selection.Always.Name)"
            Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $selection.Always.FullName -Destination $remoteRoot | Out-Null
            $restoreArgs += @('--always', $remoteAlways)
        }

        if ($selection.Workday) {
            $remoteWorkday = "$remoteRoot/$($selection.Workday.Name)"
            Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $selection.Workday.FullName -Destination $remoteRoot | Out-Null
            $restoreArgs += @('--workday', $remoteWorkday)
        }

        if ($selection.AfterWork) {
            $remoteAfterWork = "$remoteRoot/$($selection.AfterWork.Name)"
            Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $selection.AfterWork.FullName -Destination $remoteRoot | Out-Null
            $restoreArgs += @('--after-work', $remoteAfterWork)
        }

        if ($selection.PasswordVault) {
            $remotePasswordVault = "$remoteRoot/$($selection.PasswordVault.Name)"
            Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $selection.PasswordVault.FullName -Destination $remoteRoot | Out-Null
            $restoreArgs += @('--password-vault', $remotePasswordVault)
        }

        $command = '/usr/bin/quietwrtctl restore ' + ($restoreArgs -join ' ')
        Invoke-QuietWrtRemote -Connection $Connection -Command $command -TimeoutSeconds 120 | Out-Null
    } finally {
        Invoke-QuietWrtRemote -Connection $Connection -Command "rm -rf $remoteRoot" -TimeoutSeconds 30 -AllowFailure | Out-Null
    }

    return Get-QuietWrtStatus -Connection $Connection
}
