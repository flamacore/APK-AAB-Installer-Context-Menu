Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exporter = Join-Path $scriptRoot 'Export-AabToApk.ps1'

if (-not (Test-Path $exporter)) {
    throw "Exporter script not found: $exporter"
}

$keyPath = 'HKCU:\Software\Classes\SystemFileAssociations\.aab\shell\ExportAabToApk'
$commandPath = Join-Path $keyPath 'command'

$null = New-Item -Path $keyPath -Force
$null = New-ItemProperty -Path $keyPath -Name '(default)' -Value 'Export AAB to APK' -PropertyType String -Force
$null = New-ItemProperty -Path $keyPath -Name 'Icon' -Value 'imageres.dll,-1003' -PropertyType String -Force
$null = New-ItemProperty -Path $keyPath -Name 'MUIVerb' -Value 'Export AAB to APK' -PropertyType String -Force

$null = New-Item -Path $commandPath -Force
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$exporter`" `"%1`""
$null = New-ItemProperty -Path $commandPath -Name '(default)' -Value $command -PropertyType String -Force

Write-Host 'Registered Explorer context menu for .aab files:' -ForegroundColor Green
Write-Host '  Export AAB to APK'
