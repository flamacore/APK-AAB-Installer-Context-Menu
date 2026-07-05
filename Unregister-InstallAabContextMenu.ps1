Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$keyPath = 'HKCU:\Software\Classes\SystemFileAssociations\.aab\shell\InstallAabToDevice'

if (Test-Path $keyPath) {
    Remove-Item -Path $keyPath -Recurse -Force
    Write-Host 'Removed Explorer context menu entry: Install aab to device' -ForegroundColor Green
}
else {
    Write-Host 'Context menu entry not found; nothing to remove.' -ForegroundColor Yellow
}
