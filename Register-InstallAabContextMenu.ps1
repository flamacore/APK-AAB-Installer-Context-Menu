Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'Install-AabToDevice.ps1'

if (-not (Test-Path $installer)) {
    throw "Installer script not found: $installer"
}

$keyPath = 'HKCU:\Software\Classes\SystemFileAssociations\.aab\shell\InstallAabToDevice'
$commandPath = Join-Path $keyPath 'command'

$null = New-Item -Path $keyPath -Force
$null = New-ItemProperty -Path $keyPath -Name '(default)' -Value 'Install aab to device' -PropertyType String -Force
$null = New-ItemProperty -Path $keyPath -Name 'Icon' -Value 'imageres.dll,-5324' -PropertyType String -Force
$null = New-ItemProperty -Path $keyPath -Name 'MUIVerb' -Value 'Install aab to device' -PropertyType String -Force

$null = New-Item -Path $commandPath -Force
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installer`" `"%1`""
$null = New-ItemProperty -Path $commandPath -Name '(default)' -Value $command -PropertyType String -Force

Write-Host 'Registered Explorer context menu for .aab files:' -ForegroundColor Green
Write-Host '  Install aab to device'
