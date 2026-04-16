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
$script:QuietWrtHelperRoot = Join-Path $script:QuietWrtScriptRoot 'quietwrt'
$script:QuietWrtRemotePaths = [ordered]@{
    UploadRoot = '/tmp/quietwrt-upload'
    CgiPath = '/www/cgi-bin/quietwrt'
    CliPath = '/usr/bin/quietwrtctl'
    InitPath = '/etc/init.d/quietwrt'
    ModuleDir = '/usr/lib/lua/quietwrt'
    AlwaysListPath = '/etc/quietwrt/always-blocked.txt'
    WorkdayListPath = '/etc/quietwrt/workday-blocked.txt'
    AfterWorkListPath = '/etc/quietwrt/after-work-blocked.txt'
    PasswordVaultListPath = '/etc/quietwrt/password-vault-blocked.txt'
}

foreach ($helperFile in @(
    'config.ps1',
    'transport.ps1',
    'status.ps1',
    'deploy.ps1',
    'schedule.ps1',
    'backup.ps1',
    'ui.ps1'
)) {
    $helperPath = Join-Path $script:QuietWrtHelperRoot $helperFile
    if (-not (Test-Path -LiteralPath $helperPath)) {
        throw "QuietWrt helper script is missing: $helperPath"
    }

    . $helperPath
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-QuietWrtCli
}
