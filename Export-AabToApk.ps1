param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$AabPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- OverClash signing (edit here if paths change) ---
$BundletoolJar = 'C:\Users\chagl\Downloads\bundletool-all-1.18.3.jar'
$KeystorePath    = 'E:\tinyWizardRoyale\Keystore\OverClash.keystore'
$KeyAlias        = 'upload'
$StorePass       = 'zLgTRwzVouaQhCEgRKcr3vxXHzoBiQ'
$KeyPass         = $StorePass

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERR]  $Message" -ForegroundColor Red
}

function Resolve-JavaPath {
    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCmd) {
        return $javaCmd.Source
    }

    $candidates = @(
        (Join-Path $env:JAVA_HOME 'bin\java.exe'),
        (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr\bin\java.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Android\Android Studio\jbr\bin\java.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    throw 'java.exe was not found. Install Java (JDK/JRE) or Android Studio JBR.'
}

function Export-UniversalApk {
    param(
        [string]$JavaExe,
        [string]$AabFile,
        [string]$OutputApk
    )

    if (-not (Test-Path $BundletoolJar)) {
        throw "bundletool JAR not found: $BundletoolJar"
    }
    if (-not (Test-Path $KeystorePath)) {
        throw "Keystore not found: $KeystorePath"
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aab-export-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $tempRoot -ItemType Directory -Force

    try {
        $apksPath = Join-Path $tempRoot 'bundle.apks'
        $extractDir = Join-Path $tempRoot 'extract'

        Write-Info "Building universal APK: $(Split-Path -Leaf $AabFile)"
        & $JavaExe -jar $BundletoolJar build-apks `
            --bundle=$AabFile `
            --output=$apksPath `
            --mode=universal `
            --ks=$KeystorePath `
            --ks-key-alias=$KeyAlias `
            --ks-pass="pass:$StorePass" `
            --key-pass="pass:$KeyPass"

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $apksPath)) {
            throw 'bundletool build-apks failed.'
        }

        $null = New-Item -Path $extractDir -ItemType Directory -Force
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($apksPath, $extractDir)

        $universalApk = Join-Path $extractDir 'universal.apk'
        if (-not (Test-Path $universalApk)) {
            throw 'Could not find universal.apk inside generated .apks archive.'
        }

        Copy-Item -Path $universalApk -Destination $OutputApk -Force
        if (-not (Test-Path $OutputApk)) {
            throw 'Failed to write output APK.'
        }

        return $OutputApk
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$failures = 0

try {
    if (-not $AabPaths -or $AabPaths.Count -eq 0) {
        throw 'No .aab file provided. Drag and drop onto Export-AabToApk.bat or use the Explorer context menu.'
    }

    $javaExe = Resolve-JavaPath

    foreach ($rawPath in $AabPaths) {
        try {
            if (-not (Test-Path $rawPath)) {
                throw "AAB file not found: $rawPath"
            }

            $fullAabPath = (Resolve-Path $rawPath).Path
            if ([System.IO.Path]::GetExtension($fullAabPath).ToLowerInvariant() -ne '.aab') {
                throw "Not an .aab file: $fullAabPath"
            }

            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fullAabPath)
            $outputApk = Join-Path (Split-Path -Parent $fullAabPath) ($baseName + '.apk')

            $generatedApk = Export-UniversalApk -JavaExe $javaExe -AabFile $fullAabPath -OutputApk $outputApk
            Write-Ok "Exported: $generatedApk"
        }
        catch {
            $failures++
            Write-Err "$(Split-Path -Leaf $rawPath): $($_.Exception.Message)"
        }
    }

    if ($failures -gt 0) {
        exit 1
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
