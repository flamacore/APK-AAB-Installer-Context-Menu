Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$extensions = @('.apk', '.aab')
$removed = $false

foreach ($ext in $extensions) {
    $keyPath = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\InstallApkOverNetwork"

    if (Test-Path $keyPath) {
        Remove-Item -Path $keyPath -Recurse -Force
        Write-Host "Removed network install menu for $ext files" -ForegroundColor Green
        $removed = $true
    }
}

if (-not $removed) {
    Write-Host 'No network install context menu entries found; nothing to remove.' -ForegroundColor Yellow
}