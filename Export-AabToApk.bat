@echo off
setlocal

if "%~1"=="" (
    echo.
    echo  Export AAB to signed universal APK ^(OverClash^)
    echo.
    echo  Usage:
    echo    - Drag and drop one or more .aab files onto this script
    echo    - Right-click an .aab file ^> "Export AAB to APK"
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-AabToApk.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
