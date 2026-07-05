param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$AabPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-AdbPath {
    $adbCmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($adbCmd) {
        return $adbCmd.Source
    }

    $sdkRoots = @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $sdkRoots) {
        $candidate = Join-Path $root 'platform-tools\adb.exe'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw 'adb.exe was not found. Install Android platform-tools and ensure adb is available in PATH or ANDROID_SDK_ROOT.'
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

    throw 'java.exe was not found. Install Java (JDK/JRE) and ensure java is available in PATH.'
}

function Resolve-KeytoolPath {
    param([string]$JavaExe)

    $keytoolCmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($keytoolCmd) {
        return $keytoolCmd.Source
    }

    if ($JavaExe) {
        $javaDir = Split-Path -Parent $JavaExe
        $candidate = Join-Path $javaDir 'keytool.exe'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw 'keytool.exe was not found. Install a JDK and ensure keytool is available in PATH.'
}

function Resolve-BundletoolJar {
    param([string]$ScriptRoot)

    if ($env:BUNDLETOOL_JAR -and (Test-Path $env:BUNDLETOOL_JAR)) {
        return $env:BUNDLETOOL_JAR
    }

    $candidates = @(
        (Join-Path $ScriptRoot 'bundletool-all.jar'),
        (Join-Path $ScriptRoot 'bundletool.jar')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $downloadPath = Join-Path $ScriptRoot 'bundletool-all.jar'
    $downloadUrl = 'https://github.com/google/bundletool/releases/latest/download/bundletool-all.jar'

    Write-Info 'bundletool JAR not found locally. Downloading latest bundletool-all.jar...'
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath -UseBasicParsing
    }
    catch {
        throw "Unable to download bundletool from $downloadUrl. Set BUNDLETOOL_JAR or place bundletool-all.jar next to this script. Error: $($_.Exception.Message)"
    }

    if (-not (Test-Path $downloadPath)) {
        throw 'bundletool download did not produce a file.'
    }

    return $downloadPath
}

function Ensure-DebugKeystore {
    param(
        [string]$KeystorePath,
        [string]$KeytoolExe
    )

    if (Test-Path $KeystorePath) {
        return
    }

    Write-Info "Generating debug keystore at: $KeystorePath"

    & $KeytoolExe -genkeypair -v `
        -keystore $KeystorePath `
        -storepass android `
        -alias androiddebugkey `
        -keypass android `
        -dname 'CN=Android Debug,O=Android,C=US' `
        -keyalg RSA `
        -keysize 2048 `
        -validity 10000 | Out-Null

    if (-not (Test-Path $KeystorePath)) {
        throw 'Failed to generate debug keystore.'
    }
}

function Get-ConnectedDevices {
    param([string]$AdbExe)

    $lines = & $AdbExe devices -l
    if ($LASTEXITCODE -ne 0) {
        throw 'adb devices failed.'
    }

    $devices = @()
    foreach ($line in $lines) {
        if (-not $line -or $line -match '^List of devices attached') {
            continue
        }

        $trimmed = $line.Trim()
        if ($trimmed -eq '') {
            continue
        }

        $tokens = $trimmed -split '\s+'
        if ($tokens.Count -lt 2) {
            continue
        }

        $serial = $tokens[0]
        $state = $tokens[1]

        if ($state -ne 'device') {
            continue
        }

        $model = $null
        if ($trimmed -match 'model:([^\s]+)') {
            $model = $matches[1].Replace('_', ' ')
        }

        if (-not $model) {
            try {
                $model = (& $AdbExe -s $serial shell getprop ro.product.model).Trim()
            }
            catch {
                $model = ''
            }
        }

        $devices += [PSCustomObject]@{
            Serial = $serial
            Model  = if ($model) { $model } else { 'Unknown Model' }
        }
    }

    return $devices
}

function Select-Device {
    param([array]$Devices)

    if (-not $Devices -or $Devices.Count -eq 0) {
        throw 'No connected Android devices found in adb state "device".'
    }

    if ($Devices.Count -eq 1) {
        $d = $Devices[0]
        Write-Info "Single device detected: $($d.Model) [$($d.Serial)]"
        return $d
    }

    Write-Host ''
    Write-Host 'Select target device:' -ForegroundColor Yellow

    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        Write-Host ("[{0}] {1} ({2})" -f ($i + 1), $d.Model, $d.Serial)
    }

    while ($true) {
        $choice = Read-Host 'Enter number'
        [int]$index = 0
        if ([int]::TryParse($choice, [ref]$index)) {
            if ($index -ge 1 -and $index -le $Devices.Count) {
                return $Devices[$index - 1]
            }
        }
        Write-Host 'Invalid selection. Try again.' -ForegroundColor Yellow
    }
}

function Build-And-ExtractUniversalApk {
    param(
        [string]$JavaExe,
        [string]$BundletoolJar,
        [string]$AabFile,
        [string]$KeystorePath,
        [string]$OutputApk
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aab-install-" + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $tempRoot -ItemType Directory -Force

    try {
        $apksPath = Join-Path $tempRoot 'bundle.apks'
        $extractDir = Join-Path $tempRoot 'extract'

        Write-Info 'Building universal APK from AAB...'
        & $JavaExe -jar $BundletoolJar build-apks `
            --bundle=$AabFile `
            --output=$apksPath `
            --mode=universal `
            --ks=$KeystorePath `
            --ks-key-alias=androiddebugkey `
            --ks-pass=pass:android `
            --key-pass=pass:android

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $apksPath)) {
            throw 'bundletool build-apks failed.'
        }

        $null = New-Item -Path $extractDir -ItemType Directory -Force
        Expand-Archive -Path $apksPath -DestinationPath $extractDir -Force

        $universalApk = Join-Path $extractDir 'universal.apk'
        if (-not (Test-Path $universalApk)) {
            throw 'Could not locate universal.apk inside generated .apks archive.'
        }

        Copy-Item -Path $universalApk -Destination $OutputApk -Force
        if (-not (Test-Path $OutputApk)) {
            throw 'Failed to copy universal APK to target location.'
        }

        return $OutputApk
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if (-not (Test-Path $AabPath)) {
        throw "AAB file not found: $AabPath"
    }

    $fullAabPath = (Resolve-Path $AabPath).Path
    if ([System.IO.Path]::GetExtension($fullAabPath).ToLowerInvariant() -ne '.aab') {
        throw "File is not an .aab: $fullAabPath"
    }

    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $adbExe = Resolve-AdbPath
    $javaExe = Resolve-JavaPath
    $keytoolExe = Resolve-KeytoolPath -JavaExe $javaExe
    $bundletoolJar = Resolve-BundletoolJar -ScriptRoot $scriptRoot

    $keystorePath = Join-Path $scriptRoot 'debug-aab.keystore'
    Ensure-DebugKeystore -KeystorePath $keystorePath -KeytoolExe $keytoolExe

    Write-Info 'Querying connected devices via adb...'
    $devices = Get-ConnectedDevices -AdbExe $adbExe
    $target = Select-Device -Devices $devices

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fullAabPath)
    $outputApk = Join-Path (Split-Path -Parent $fullAabPath) ($baseName + '-universal.apk')

    $generatedApk = Build-And-ExtractUniversalApk `
        -JavaExe $javaExe `
        -BundletoolJar $bundletoolJar `
        -AabFile $fullAabPath `
        -KeystorePath $keystorePath `
        -OutputApk $outputApk

    Write-Info "Installing APK to device $($target.Model) [$($target.Serial)]..."
    & $adbExe -s $target.Serial install -r -d $generatedApk

    if ($LASTEXITCODE -ne 0) {
        throw 'adb install failed.'
    }

    Write-Ok "Install complete: $generatedApk"
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
