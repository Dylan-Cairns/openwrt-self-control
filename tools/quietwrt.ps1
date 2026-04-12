[CmdletBinding()]
param(
    [string]$DefaultRouterHost = '192.168.8.1',
    [string]$DefaultRouterUser = 'root',
    [int]$DefaultRouterPort = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QuietWrtScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

$script:QuietWrtRepoRoot = Split-Path -Parent $script:QuietWrtScriptRoot
$script:QuietWrtRemotePaths = [ordered]@{
    UploadRoot = '/tmp/quietwrt-upload'
    CgiPath = '/www/cgi-bin/quietwrt'
    CliPath = '/usr/bin/quietwrtctl'
    InitPath = '/etc/init.d/quietwrt'
    ModuleDir = '/usr/lib/lua/quietwrt'
    AlwaysListPath = '/etc/quietwrt/always-blocked.txt'
    WorkdayListPath = '/etc/quietwrt/workday-blocked.txt'
}

function Import-QuietWrtDependencies {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        throw "Posh-SSH is required. Install it with: Install-Module -Name Posh-SSH -Scope CurrentUser"
    }

    Import-Module Posh-SSH -ErrorAction Stop
}

function Get-QuietWrtRepoRoot {
    return $script:QuietWrtRepoRoot
}

function Get-QuietWrtBackupDirectory {
    return (Join-Path (Get-QuietWrtRepoRoot) 'backups')
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

function New-QuietWrtCredential {
    param(
        [string]$UserName = 'root',
        [securestring]$Password
    )

    if (-not $Password) {
        $Password = Read-Host -Prompt "Router password for $UserName" -AsSecureString
    }

    return [pscredential]::new($UserName, $Password)
}

function Connect-QuietWrtRouter {
    param(
        [string]$RouterHost,
        [string]$RouterUser,
        [int]$RouterPort = 22,
        [pscredential]$Credential
    )

    Import-QuietWrtDependencies

    $sshSession = $null
    $sftpSession = $null

    try {
        $sshSession = @(New-QuietWrtSshSession -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential)[0]
        $sftpSession = @(New-QuietWrtSftpSession -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential)[0]

        return [pscustomobject]@{
            Host = $RouterHost
            User = $RouterUser
            Port = $RouterPort
            Credential = $Credential
            SshSession = $sshSession
            SftpSession = $sftpSession
        }
    } catch {
        if ($sftpSession) {
            try {
                Remove-QuietWrtSftpSession -Session $sftpSession | Out-Null
            } catch {
            }
        }

        if ($sshSession) {
            try {
                Remove-QuietWrtSshSession -Session $sshSession | Out-Null
            } catch {
            }
        }

        throw "Could not connect to $RouterHost over SSH: $($_.Exception.Message)"
    }
}

function Disconnect-QuietWrtRouter {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $Connection
    )

    if (-not $Connection) {
        return
    }

    if ($Connection.SftpSession) {
        try {
            Remove-QuietWrtSftpSession -Session $Connection.SftpSession | Out-Null
        } catch {
        }
    }

    if ($Connection.SshSession) {
        try {
            Remove-QuietWrtSshSession -Session $Connection.SshSession | Out-Null
        } catch {
        }
    }
}

function New-QuietWrtSshSession {
    param(
        [string]$RouterHost,
        [int]$RouterPort,
        [pscredential]$Credential
    )

    return New-SSHSession -ComputerName $RouterHost -Port $RouterPort -Credential $Credential -AcceptKey -ErrorAction Stop
}

function New-QuietWrtSftpSession {
    param(
        [string]$RouterHost,
        [int]$RouterPort,
        [pscredential]$Credential
    )

    return New-SFTPSession -ComputerName $RouterHost -Port $RouterPort -Credential $Credential -AcceptKey -ErrorAction Stop
}

function Remove-QuietWrtSshSession {
    param(
        $Session
    )

    return Remove-SSHSession -SSHSession $Session
}

function Remove-QuietWrtSftpSession {
    param(
        $Session
    )

    return Remove-SFTPSession -SFTPSession $Session
}

function Invoke-QuietWrtSshCommand {
    param(
        $Session,
        [string]$Command,
        [int]$TimeoutSeconds
    )

    return Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut $TimeoutSeconds -ErrorAction Stop
}

function Send-QuietWrtSftpItem {
    param(
        $Session,
        [string]$Path,
        [string]$Destination
    )

    return Set-SFTPItem -SFTPSession $Session -Path $Path -Destination $Destination -Force
}

function Receive-QuietWrtSftpItem {
    param(
        $Session,
        [string]$Path,
        [string]$Destination
    )

    return Get-SFTPItem -SFTPSession $Session -Path $Path -Destination $Destination -Force
}

function Invoke-QuietWrtRemote {
    param(
        $Connection,
        [string]$Command,
        [int]$TimeoutSeconds = 60,
        [switch]$AllowFailure
    )

    $result = @(Invoke-QuietWrtSshCommand -Session $Connection.SshSession -Command $Command -TimeoutSeconds $TimeoutSeconds)[0]
    $output = ''

    if ($null -ne $result.Output) {
        $output = (($result.Output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    }

    if (-not $AllowFailure -and $result.ExitStatus -ne 0) {
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = 'The remote command did not return an error message.'
        }

        throw "Remote command failed with exit code $($result.ExitStatus): $output"
    }

    return [pscustomobject]@{
        ExitStatus = $result.ExitStatus
        Output = $output
        Raw = $result
    }
}

function New-QuietWrtStatusPlaceholder {
    param(
        [bool]$Installed = $false
    )

    return [pscustomobject]@{
        installed = $Installed
        mode = if ($Installed) { 'unknown' } else { 'not_installed' }
        mode_label = if ($Installed) { 'Unknown' } else { 'Not installed' }
        scheduled_mode = if ($Installed) { 'unknown' } else { 'not_installed' }
        protection_enabled = $null
        enforcement_ready = $false
        always_enabled = $false
        workday_enabled = $false
        overnight_enabled = $false
        always_count = 0
        workday_count = 0
        active_rule_count = 0
        hardening = [pscustomobject]@{
            dns_intercept = $false
            dot_block = $false
            overnight_rule = $false
        }
        warnings = @()
    }
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
        return $result.Output | ConvertFrom-Json -ErrorAction Stop
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

function Get-QuietWrtPreflight {
    param(
        $Connection
    )

    $result = Invoke-QuietWrtRemote -Connection $Connection -Command @'
if [ -f /etc/openwrt_release ]; then
  . /etc/openwrt_release
  echo "openwrt_present=1"
  echo "openwrt_id=${DISTRIB_ID:-}"
  echo "openwrt_release=${DISTRIB_RELEASE:-}"
else
  echo "openwrt_present=0"
fi

if [ -f /etc/glversion ] || [ -d /usr/share/gl ]; then
  echo "glinet_present=1"
else
  echo "glinet_present=0"
fi

if [ -f /etc/AdGuardHome/config.yaml ]; then
  echo "adguard_config_present=1"
else
  echo "adguard_config_present=0"
fi

timezone="$(uci -q get system.@system[0].zonename)"
if [ -z "$timezone" ]; then
  timezone="$(uci -q get system.@system[0].timezone)"
fi

if [ -n "$timezone" ]; then
  echo "timezone_present=1"
  echo "timezone=$timezone"
else
  echo "timezone_present=0"
fi

if [ -x /etc/init.d/adguardhome ]; then
  echo "adguard_init_present=1"
else
  echo "adguard_init_present=0"
fi
'@

    $details = ConvertFrom-QuietWrtKeyValueLines -Text $result.Output
    $hardFailures = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $checklist = New-Object System.Collections.Generic.List[string]

    if ($details.openwrt_present -ne '1') {
        $hardFailures.Add('This router does not look like an OpenWrt system over SSH.')
    }

    if ($details.adguard_config_present -ne '1') {
        $hardFailures.Add('AdGuard Home config is missing at /etc/AdGuardHome/config.yaml.')
    }

    if ($details.timezone_present -ne '1') {
        $hardFailures.Add('Router timezone is not configured. QuietWrt scheduling depends on local router time.')
    }

    if ($details.glinet_present -ne '1') {
        $warnings.Add('Could not confirm GL.iNet-specific firmware markers over SSH. Continue only if this is the expected GL.iNet environment.')
    }

    if ($details.adguard_init_present -ne '1') {
        $warnings.Add('Could not confirm the AdGuard Home init script at /etc/init.d/adguardhome.')
    }

    $checklist.Add('Confirm the router is in Router mode in the GL.iNet admin UI.')
    $checklist.Add('Confirm AdGuard Home is enabled in the GL.iNet admin UI.')
    $checklist.Add('Confirm Override DNS Settings for All Clients is enabled.')
    $checklist.Add('Confirm IPv6 is disabled.')

    return [pscustomobject]@{
        Passed = ($hardFailures.Count -eq 0)
        Details = [pscustomobject]$details
        HardFailures = $hardFailures.ToArray()
        Warnings = $warnings.ToArray()
        Checklist = $checklist.ToArray()
    }
}

function Show-QuietWrtPreflight {
    param(
        $Preflight
    )

    Write-Host ''
    Write-Host 'Preflight'
    Write-Host "  OpenWrt: $($Preflight.Details.openwrt_id) $($Preflight.Details.openwrt_release)"

    if ($Preflight.Details.timezone) {
        Write-Host "  Timezone: $($Preflight.Details.timezone)"
    }

    foreach ($warning in $Preflight.Warnings) {
        Write-Warning $warning
    }

    if ($Preflight.Checklist.Count -gt 0) {
        Write-Host '  Manual checklist:'
        foreach ($item in $Preflight.Checklist) {
            Write-Host "    - $item"
        }
    }

    if (-not $Preflight.Passed) {
        foreach ($failure in $Preflight.HardFailures) {
            Write-Error $failure
        }
    }
}

function Upload-QuietWrtPayload {
    param(
        $Connection
    )

    $payload = Get-QuietWrtPayload
    $remotePaths = $script:QuietWrtRemotePaths

    Invoke-QuietWrtRemote -Connection $Connection -Command @"
rm -rf $($remotePaths.UploadRoot)
mkdir -p $($remotePaths.UploadRoot)
"@ | Out-Null

    Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $payload.Cgi -Destination $remotePaths.UploadRoot | Out-Null
    Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $payload.Cli -Destination $remotePaths.UploadRoot | Out-Null
    Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $payload.InitScript -Destination $remotePaths.UploadRoot | Out-Null
    Send-QuietWrtSftpItem -Session $Connection.SftpSession -Path $payload.ModuleDir -Destination $remotePaths.UploadRoot | Out-Null

    Invoke-QuietWrtRemote -Connection $Connection -TimeoutSeconds 120 -Command @"
set -e
mkdir -p /www/cgi-bin /usr/bin /etc/init.d $($remotePaths.ModuleDir)
cp $($remotePaths.UploadRoot)/quietwrt.cgi $($remotePaths.CgiPath)
cp $($remotePaths.UploadRoot)/quietwrtctl.lua $($remotePaths.CliPath)
cp $($remotePaths.UploadRoot)/quietwrt.init $($remotePaths.InitPath)
cp $($remotePaths.UploadRoot)/quietwrt/*.lua $($remotePaths.ModuleDir)/
chmod 755 $($remotePaths.CgiPath) $($remotePaths.CliPath) $($remotePaths.InitPath)
rm -rf $($remotePaths.UploadRoot)
"@ | Out-Null
}

function Install-QuietWrtOnRouter {
    param(
        $Connection
    )

    $preflight = Get-QuietWrtPreflight -Connection $Connection
    Show-QuietWrtPreflight -Preflight $preflight

    if (-not $preflight.Passed) {
        throw ('Router preflight failed: ' + ($preflight.HardFailures -join ' '))
    }

    Upload-QuietWrtPayload -Connection $Connection
    Invoke-QuietWrtRemote -Connection $Connection -Command '/usr/bin/quietwrtctl install' -TimeoutSeconds 120 | Out-Null
    return Get-QuietWrtStatus -Connection $Connection
}

function Set-QuietWrtToggleState {
    param(
        $Connection,
        [ValidateSet('always', 'workday', 'overnight')]
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

function Get-QuietWrtBackupFileNames {
    param(
        [string]$OutputDirectory,
        [datetime]$Timestamp = (Get-Date)
    )

    $suffix = $Timestamp.ToString('yyyy-MM-dd-HHmmss')

    return [pscustomobject]@{
        Always = Join-Path $OutputDirectory "quietwrt-always-$suffix.txt"
        Workday = Join-Path $OutputDirectory "quietwrt-workday-$suffix.txt"
    }
}

function Get-QuietWrtLatestBackupSelection {
    param(
        [string]$BackupDirectory = (Get-QuietWrtBackupDirectory)
    )

    $always = @()
    $workday = @()

    if (Test-Path -LiteralPath $BackupDirectory) {
        $always = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter 'quietwrt-always-*.txt' | Sort-Object Name -Descending)
        $workday = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter 'quietwrt-workday-*.txt' | Sort-Object Name -Descending)
    }

    return [pscustomobject]@{
        Directory = $BackupDirectory
        Always = if ($always.Count -gt 0) { $always[0] } else { $null }
        Workday = if ($workday.Count -gt 0) { $workday[0] } else { $null }
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
for path in /etc/quietwrt/always-blocked.txt /etc/quietwrt/workday-blocked.txt; do
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

        Move-Item -LiteralPath (Join-Path $tempDir 'always-blocked.txt') -Destination $destination.Always -Force
        Move-Item -LiteralPath (Join-Path $tempDir 'workday-blocked.txt') -Destination $destination.Workday -Force
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
    if ($null -eq $selection.Always -and $null -eq $selection.Workday) {
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

        $command = '/usr/bin/quietwrtctl restore ' + ($restoreArgs -join ' ')
        Invoke-QuietWrtRemote -Connection $Connection -Command $command -TimeoutSeconds 120 | Out-Null
    } finally {
        Invoke-QuietWrtRemote -Connection $Connection -Command "rm -rf $remoteRoot" -TimeoutSeconds 30 -AllowFailure | Out-Null
    }

    return Get-QuietWrtStatus -Connection $Connection
}

function Show-QuietWrtStatus {
    param(
        $Status
    )

    Write-Host ''
    Write-Host 'QuietWrt Status'
    Write-Host "  Installed: $(if ($Status.installed) { 'yes' } else { 'no' })"
    Write-Host "  Mode: $($Status.mode_label)"

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
    Write-Host "  Workday blocklist: $(if ($Status.workday_enabled) { 'enabled' } else { 'disabled' })"
    Write-Host "  Overnight blocking: $(if ($Status.overnight_enabled) { 'enabled' } else { 'disabled' })"
    Write-Host "  Always entries: $($Status.always_count)"
    Write-Host "  Workday entries: $($Status.workday_count)"
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
        "4. $(if ($Status.overnight_enabled) { 'Disable' } else { 'Enable' }) overnight blocking"
        '5. Backup both blocklists to this PC'
        '6. Restore latest backup'
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
            $updatedStatus = Set-QuietWrtToggleState -Connection $Connection -ToggleName 'overnight' -Enabled (-not [bool]$Status.overnight_enabled)
            Show-QuietWrtStatus -Status $updatedStatus
            return [pscustomobject]@{
                Continue = $true
                Status = $updatedStatus
                BackupPaths = $null
            }
        }
        '5' {
            $backupPaths = Backup-QuietWrtBlocklists -Connection $Connection -OutputDirectory $BackupDirectory
            Write-Host ''
            Write-Host 'Saved backups:'
            Write-Host "  $($backupPaths.Always)"
            Write-Host "  $($backupPaths.Workday)"
            return [pscustomobject]@{
                Continue = $true
                Status = $Status
                BackupPaths = $backupPaths
            }
        }
        '6' {
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

if ($MyInvocation.InvocationName -ne '.') {
    Start-QuietWrtCli
}
