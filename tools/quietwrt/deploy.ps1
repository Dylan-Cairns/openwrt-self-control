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
