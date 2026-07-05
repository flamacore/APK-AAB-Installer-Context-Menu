param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FilePath
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

    throw 'adb.exe not found. Install Android platform-tools and ensure adb in PATH, ANDROID_SDK_ROOT, or ANDROID_HOME.'
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

    throw 'java.exe not found. Install Java (JDK/JRE) and ensure java in PATH.'
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

    throw 'keytool.exe not found. Install a JDK and ensure keytool in PATH.'
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
        throw "Unable to download bundletool from $downloadUrl. Set BUNDLETOOL_JAR env var or place bundletool-all.jar next to this script. Error: $($_.Exception.Message)"
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

function Show-IpInputDialog {
    <#
    .SYNOPSIS
    Shows a Windows Forms dialog to ask for IP:port, or falls back to Read-Host if forms unavailable.
    #>
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    if (-not ('System.Windows.Forms.Form' -as [type])) {
        Write-Info 'Windows Forms unavailable; using console input.'
        $inputStr = Read-Host 'Enter device IP:port (e.g. 192.168.1.100:5555)'
        return $inputStr
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ADB Network Install'
    $form.Size = New-Object System.Drawing.Size(400, 180)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Enter device IP:port:'
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.Size = New-Object System.Drawing.Size(350, 20)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(20, 50)
    $textBox.Size = New-Object System.Drawing.Size(350, 24)
    $textBox.Text = '192.168.1.100:5555'

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Connect & Install'
    $okButton.Location = New-Object System.Drawing.Point(100, 90)
    $okButton.Size = New-Object System.Drawing.Size(180, 30)
    $okButton.Add_Click({
        $form.Tag = $textBox.Text.Trim()
        $form.Close()
    })
    $form.AcceptButton = $okButton

    $form.Controls.Add($label)
    $form.Controls.Add($textBox)
    $form.Controls.Add($okButton)

    $null = $form.ShowDialog()

    $result = $form.Tag
    if (-not $result) {
        throw 'User cancelled the dialog.'
    }

    return $result
}

try {
    if (-not (Test-Path $FilePath)) {
        throw "File not found: $FilePath"
    }

    $fullPath = (Resolve-Path $FilePath).Path
    $ext = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()

    if ($ext -eq '.aab') {
        Write-Info 'Detected .aab file — will build universal APK then install via network.'
    }
    elseif ($ext -eq '.apk') {
        Write-Info 'Detected .apk file — will install directly via network.'
    }
    else {
        throw "Unsupported file extension: $ext. Only .aab and .apk files are supported."
    }

    $ipPort = Show-IpInputDialog
    if ($ipPort -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$') {
        throw "Invalid IP:port format. Expected something like 192.168.1.100:5555, got: $ipPort"
    }

    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $adbExe = Resolve-AdbPath

    # ----- Connect via ADB over network -----
    Write-Info "Connecting to $ipPort via ADB over network..."
    $connectOutput = & $adbExe connect $ipPort 2>&1
    $connectExitCode = $LASTEXITCODE
    foreach ($line in $connectOutput) { Write-Host "  $line" }

    if ($connectExitCode -ne 0) {
        throw "adb connect to $ipPort failed (exit code $connectExitCode)."
    }

    # adb connect can exit 0 but still fail — check output for "failed" / "unable"
    $connectText = ($connectOutput -join ' ')
    if ($connectText -match 'failed|unable|cannot|error|refused') {
        throw "adb connect to $ipPort reported failure: $connectText"
    }

    # Verify device is in 'device' state
    $devLines = & $adbExe devices
    $connected = $false
    foreach ($line in $devLines) {
        if ($line.Trim() -match "^$([regex]::Escape($ipPort))\s+device") {
            $connected = $true
            break
        }
    }

    if (-not $connected) {
        throw "Device $ipPort not in 'device' state after connect. Check IP:port and ensure device has ADB over network enabled."
    }

    Write-Ok "Connected to $ipPort"

    try {
        $apkToInstall = $fullPath

        if ($ext -eq '.aab') {
            $javaExe = Resolve-JavaPath
            $keytoolExe = Resolve-KeytoolPath -JavaExe $javaExe
            $bundletoolJar = Resolve-BundletoolJar -ScriptRoot $scriptRoot

            $keystorePath = Join-Path $scriptRoot 'debug-aab.keystore'
            Ensure-DebugKeystore -KeystorePath $keystorePath -KeytoolExe $keytoolExe

            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
            $outputApk = Join-Path (Split-Path -Parent $fullPath) ($baseName + '-universal.apk')

            $apkToInstall = Build-And-ExtractUniversalApk `
                -JavaExe $javaExe `
                -BundletoolJar $bundletoolJar `
                -AabFile $fullPath `
                -KeystorePath $keystorePath `
                -OutputApk $outputApk

            Write-Ok "Universal APK generated: $apkToInstall"
        }

        Write-Info "Installing APK to $ipPort..."
        & $adbExe -s $ipPort install -r -d $apkToInstall
        if ($LASTEXITCODE -ne 0) {
            throw 'adb install failed.'
        }

        Write-Ok "Install complete on $ipPort"
    }
    finally {
        # Disconnect cleanly
        Write-Info "Disconnecting from $ipPort..."
        $null = & $adbExe disconnect $ipPort 2>&1
        Write-Ok "Disconnected from $ipPort"
    }
}
catch {
    Write-Err $_.Exception.Message
    # Try to disconnect even on failure
    try {
        if ($ipPort) {
            $null = & $adbExe disconnect $ipPort 2>&1
        }
    }
    catch {}
    exit 1
}