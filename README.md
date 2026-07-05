# AAB / APK Context Menu Installer

Windows Explorer right-click actions for `.aab` and `.apk` files.

## Actions

### Install aab to device (USB)

Right-click a `.aab` file → `Install aab to device`

1. Prompts you to select a connected Android device (via `adb` over USB),
2. Builds a universal APK from the `.aab` using `bundletool`,
3. Extracts/copies the generated APK next to the bundle (`<name>-universal.apk`),
4. Installs it to the selected device with `adb install -r -d`.

### Install to ADB device (network)

Right-click a `.apk` or `.aab` file → `Install to ADB device (network)...`

Two modes in the dialog:

**Direct connect** — for devices already authorized or using TCP/IP port 5555:
1. Enter `IP:port` (e.g. `192.168.1.100:5555`),
2. Connects via `adb connect`.

**Pair first (Android 11+)** — for wireless debugging with pairing code:
1. Enter pairing `IP:port` and 6-digit code from "Pair device with pairing code",
2. Enter connect `IP:port` from "Wireless debugging" (different port),
3. Runs `adb pair`, then `adb connect`.

Both modes then:
1. If `.aab`: builds a universal APK using `bundletool` (same as USB flow),
2. Installs the APK with `adb install -r -d`,
3. Disconnects cleanly with `adb disconnect`.

Fails immediately on any error (invalid IP, wrong code, connection refused, install failure).

## Files

| File | Purpose |
|------|---------|
| `Install-AabToDevice.ps1` | USB install script (`.aab` only) |
| `Install-ApkOverNetwork.ps1` | Network install script (`.apk` + `.aab`) |
| `Register-InstallAabContextMenu.ps1` | Register USB context menu (`.aab`) |
| `Register-NetworkInstallContextMenu.ps1` | Register network context menu (`.apk` + `.aab`) |
| `Unregister-InstallAabContextMenu.ps1` | Remove USB context menu |
| `Unregister-NetworkInstallContextMenu.ps1` | Remove network context menu |

## One-time setup

Register USB menu:
```powershell
powershell -ExecutionPolicy Bypass -File .\Register-InstallAabContextMenu.ps1
```

Register network menu:
```powershell
powershell -ExecutionPolicy Bypass -File .\Register-NetworkInstallContextMenu.ps1
```

Both register for the current user only (no admin required).

## Requirements

- `adb` (in `PATH`, or under `ANDROID_SDK_ROOT` / `ANDROID_HOME` / `%LOCALAPPDATA%\Android\Sdk`),
- Java runtime (`java` + `keytool`) — needed only for `.aab` files,
- Internet on first run if `bundletool-all.jar` is not already present next to the script.

The script auto-downloads `bundletool-all.jar` if missing.

## Remove menu entries

```powershell
powershell -ExecutionPolicy Bypass -File .\Unregister-InstallAabContextMenu.ps1
powershell -ExecutionPolicy Bypass -File .\Unregister-NetworkInstallContextMenu.ps1