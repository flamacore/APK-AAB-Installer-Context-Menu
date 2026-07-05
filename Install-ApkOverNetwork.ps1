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

function Show-ConnectionDialog {
    <#
    .SYNOPSIS
    Shows a Windows Forms dialog to choose direct connect or pairing, then returns connection info.
    #>
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    if (-not ('System.Windows.Forms.Form' -as [type])) {
        Write-Info 'Windows Forms unavailable; using console input.'
        Write-Host "Select mode:" -ForegroundColor Yellow
        Write-Host "  1) Direct connect (adb connect IP:port)" -ForegroundColor Yellow
        Write-Host "  2) Pair first (Android 11+ wireless debugging)" -ForegroundColor Yellow
        $mode = Read-Host 'Enter 1 or 2'
        if ($mode -eq '2') {
            $pairIpPort = Read-Host 'Enter pairing IP:port (e.g. 192.168.1.100:41916)'
            $pairCode = Read-Host 'Enter 6-digit pairing code'
            $connectIpPort = Read-Host 'Enter connect IP:port (e.g. 192.168.1.100:41731)'
            return @{ Mode = 'pair'; PairIpPort = $pairIpPort; PairCode = $pairCode; ConnectIpPort = $connectIpPort }
        }
        else {
            $ipPort = Read-Host 'Enter device IP:port (e.g. 192.168.1.100:5555)'
            return @{ Mode = 'direct'; ConnectIpPort = $ipPort }
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ADB Network Install'
    $form.Size = New-Object System.Drawing.Size(480, 340)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # --- Mode selector (tab-like radio buttons) ---
    $radioDirect = New-Object System.Windows.Forms.RadioButton
    $radioDirect.Text = 'Direct connect'
    $radioDirect.Location = New-Object System.Drawing.Point(20, 15)
    $radioDirect.Size = New-Object System.Drawing.Size(120, 24)
    $radioDirect.Checked = $true

    $radioPair = New-Object System.Windows.Forms.RadioButton
    $radioPair.Text = 'Pair first (Android 11+)'
    $radioPair.Location = New-Object System.Drawing.Point(160, 15)
    $radioPair.Size = New-Object System.Drawing.Size(180, 24)

    # --- Direct connect fields ---
    $groupDirect = New-Object System.Windows.Forms.GroupBox
    $groupDirect.Text = ' Direct connect '
    $groupDirect.Location = New-Object System.Drawing.Point(20, 50)
    $groupDirect.Size = New-Object System.Drawing.Size(440, 70)

    $labelDirect = New-Object System.Windows.Forms.Label
    $labelDirect.Text = 'IP:port (e.g. 192.168.1.100:5555):'
    $labelDirect.Location = New-Object System.Drawing.Point(10, 25)
    $labelDirect.Size = New-Object System.Drawing.Size(410, 18)

    $tbDirect = New-Object System.Windows.Forms.TextBox
    $tbDirect.Location = New-Object System.Drawing.Point(10, 45)
    $tbDirect.Size = New-Object System.Drawing.Size(410, 24)
    $tbDirect.Text = '192.168.1.100:5555'

    $groupDirect.Controls.Add($labelDirect)
    $groupDirect.Controls.Add($tbDirect)

    # --- Pairing fields ---
    $groupPair = New-Object System.Windows.Forms.GroupBox
    $groupPair.Text = ' Pairing (Android 11+ wireless debugging) '
    $groupPair.Location = New-Object System.Drawing.Point(20, 50)
    $groupPair.Size = New-Object System.Drawing.Size(440, 180)
    $groupPair.Visible = $false

    $labelPairIp = New-Object System.Windows.Forms.Label
    $labelPairIp.Text = 'Pairing IP:port (from "Pair device with pairing code"):'
    $labelPairIp.Location = New-Object System.Drawing.Point(10, 25)
    $labelPairIp.Size = New-Object System.Drawing.Size(410, 18)

    $tbPairIp = New-Object System.Windows.Forms.TextBox
    $tbPairIp.Location = New-Object System.Drawing.Point(10, 45)
    $tbPairIp.Size = New-Object System.Drawing.Size(410, 24)
    $tbPairIp.Text = '192.168.1.100:41916'

    $labelCode = New-Object System.Windows.Forms.Label
    $labelCode.Text = '6-digit pairing code:'
    $labelCode.Location = New-Object System.Drawing.Point(10, 75)
    $labelCode.Size = New-Object System.Drawing.Size(410, 18)

    $tbCode = New-Object System.Windows.Forms.TextBox
    $tbCode.Location = New-Object System.Drawing.Point(10, 95)
    $tbCode.Size = New-Object System.Drawing.Size(410, 24)
    $tbCode.Font = New-Object System.Drawing.Font('Consolas', 12)

    $labelConnectIp = New-Object System.Windows.Forms.Label
    $labelConnectIp.Text = 'Connect IP:port (from "Wireless debugging"):'
    $labelConnectIp.Location = New-Object System.Drawing.Point(10, 125)
    $labelConnectIp.Size = New-Object System.Drawing.Size(410, 18)

    $tbConnectIp = New-Object System.Windows.Forms.TextBox
    $tbConnectIp.Location = New-Object System.Drawing.Point(10, 145)
    $tbConnectIp.Size = New-Object System.Drawing.Size(410, 24)
    $tbConnectIp.Text = '192.168.1.100:41731'

    $groupPair.Controls.Add($labelPairIp)
    $groupPair.Controls.Add($tbPairIp)
    $groupPair.Controls.Add($labelCode)
    $groupPair.Controls.Add($tbCode)
    $groupPair.Controls.Add($labelConnectIp)
    $groupPair.Controls.Add($tbConnectIp)

    # --- Toggle groups on radio change ---
    $radioDirect.Add_CheckedChanged({
        $groupDirect.Visible = $radioDirect.Checked
        $groupPair.Visible = (-not $radioDirect.Checked)
        $form.Height = if ($radioDirect.Checked) { 240 } else { 360 }
    })

    $radioPair.Add_CheckedChanged({
        $groupDirect.Visible = (-not $radioPair.Checked)
        $groupPair.Visible = $radioPair.Checked
        $form.Height = if ($radioPair.Checked) { 360 } else { 240 }
    })

    # --- OK button ---
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Connect & Install'
    $okButton.Location = New-Object System.Drawing.Point(140, 250)
    $okButton.Size = New-Object System.Drawing.Size(180, 30)
    $okButton.Add_Click({
        if ($radioDirect.Checked) {
            $val = $tbDirect.Text.Trim()
            if (-not $val) { throw 'IP:port cannot be empty.' }
            $form.Tag = @{ Mode = 'direct'; ConnectIpPort = $val }
        }
        else {
            $pairIp = $tbPairIp.Text.Trim()
            $code = $tbCode.Text.Trim()
            $connIp = $tbConnectIp.Text.Trim()
            if (-not $pairIp) { throw 'Pairing IP:port cannot be empty.' }
            if (-not $code) { throw 'Pairing code cannot be empty.' }
            if (-not $connIp) { throw 'Connect IP:port cannot be empty.' }
            $form.Tag = @{ Mode = 'pair'; PairIpPort = $pairIp; PairCode = $code; ConnectIpPort = $connIp }
        }
        $form.Close()
    })
    $form.AcceptButton = $okButton

    $form.Controls.Add($radioDirect)
    $form.Controls.Add($radioPair)
    $form.Controls.Add($groupDirect)
    $form.Controls.Add($groupPair)
    $form.Controls.Add($okButton)

    $form.Height = 240

    $null = $form.ShowDialog()

    $result = $form.Tag
    if (-not $result) {
        throw 'User cancelled the dialog.'
    }

    return $result
}

function Invoke-AdbConnect {
    param(
        [string]$AdbExe,
        [string]$IpPort
    )

    Write-Info "Connecting to $IpPort via ADB over network..."
    $output = & $AdbExe connect $IpPort 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-Host "  $line" }

    if ($exitCode -ne 0) {
        throw "adb connect to $IpPort failed (exit code $exitCode)."
    }

    $text = ($output -join ' ')
    if ($text -match 'failed|unable|cannot|error|refused') {
        throw "adb connect to $IpPort reported failure: $text"
    }

    # Verify device is in 'device' state
    $devLines = & $AdbExe devices
    $connected = $false
    foreach ($line in $devLines) {
        if ($line.Trim() -match "^$([regex]::Escape($IpPort))\s+device") {
            $connected = $true
            break
        }
    }

    if (-not $connected) {
        throw "Device $IpPort not in 'device' state after connect. Check IP:port and ensure device has ADB over network enabled."
    }

    Write-Ok "Connected to $IpPort"
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

    $connInfo = Show-ConnectionDialog
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $adbExe = Resolve-AdbPath

    # ----- Pair if needed -----
    if ($connInfo.Mode -eq 'pair') {
        Write-Info "Pairing with $($connInfo.PairIpPort)..."
        $pairOutput = & $adbExe pair $connInfo.PairIpPort $connInfo.PairCode 2>&1
        $pairExit = $LASTEXITCODE
        foreach ($line in $pairOutput) { Write-Host "  $line" }

        if ($pairExit -ne 0) {
            throw "adb pair to $($connInfo.PairIpPort) failed (exit code $pairExit)."
        }

        $pairText = ($pairOutput -join ' ')
        if ($pairText -match 'failed|unable|cannot|error|refused|denied') {
            throw "adb pair to $($connInfo.PairIpPort) reported failure: $pairText"
        }

        Write-Ok "Paired with $($connInfo.PairIpPort)"
    }

    # ----- Connect -----
    Invoke-AdbConnect -AdbExe $adbExe -IpPort $connInfo.ConnectIpPort
    $ipPort = $connInfo.ConnectIpPort

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