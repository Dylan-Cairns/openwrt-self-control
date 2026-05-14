Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $repoRoot 'backups'

if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
    Write-Host "Backup directory not found: $backupDir"
    exit 1
}

$patterns = @(
    'quietwrt-always-*.txt',
    'quietwrt-workday-*.txt',
    'quietwrt-after-work-*.txt',
    'quietwrt-password-vault-*.txt'
)

$filesToKeep = @()
$filesToDelete = @()

foreach ($pattern in $patterns) {
    $files = @(Get-ChildItem -LiteralPath $backupDir -File -Filter $pattern | Sort-Object Name -Descending)

    if ($files.Count -gt 0) {
        $filesToKeep += $files | Select-Object -First 1
        $filesToDelete += $files | Select-Object -Skip 1
    }
}

if ($filesToKeep.Count -gt 0) {
    Write-Host 'Files that will remain:'
    Write-Host ''
    foreach ($file in ($filesToKeep | Sort-Object Name)) {
        Write-Host "  $($file.Name)"
    }
    Write-Host ''
}

if ($filesToDelete.Count -eq 0) {
    Write-Host 'No old backup files found.'
    exit 0
}

Write-Host 'Files that will be deleted:'
Write-Host ''
foreach ($file in ($filesToDelete | Sort-Object Name)) {
    Write-Host "  $($file.Name)"
}
Write-Host ''

$confirmation = Read-Host 'Delete these old backup files? [y/N]'
if ($confirmation -notin @('y', 'yes')) {
    Write-Host 'Cancelled. No files were deleted.'
    exit 0
}

foreach ($file in $filesToDelete) {
    Remove-Item -LiteralPath $file.FullName
}

Write-Host "Deleted $($filesToDelete.Count) old backup file(s)."
