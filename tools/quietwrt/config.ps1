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
