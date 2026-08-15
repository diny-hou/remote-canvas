$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$tauriRoot = Join-Path $projectRoot "src-tauri"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

if (-not (Get-Command rustup -ErrorAction SilentlyContinue) -or -not (Test-Path $vswhere)) {
    & (Join-Path $PSScriptRoot "bootstrap-windows.ps1")
    Write-Host "Prerequisites were installed. Restart PowerShell and run this script again." -ForegroundColor Yellow
    exit 2
}

& (Join-Path $PSScriptRoot "build-installer.ps1")

$bundleDirectory = Join-Path $tauriRoot "target\release\bundle\nsis"
$installer = Get-ChildItem -Path $bundleDirectory -Filter "*-setup.exe" | Select-Object -First 1
if (-not $installer) {
    throw "RemoteCanvas installer was not found."
}

Write-Host "Starting the RemoteCanvas installer..." -ForegroundColor Cyan
$process = Start-Process -FilePath $installer.FullName -Wait -PassThru
if ($process.ExitCode -ne 0) {
    throw "The installer ended with exit code $($process.ExitCode)."
}

Write-Host "RemoteCanvas Host is installed." -ForegroundColor Green
