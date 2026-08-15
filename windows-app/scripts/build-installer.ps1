$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$tauriRoot = Join-Path $projectRoot "src-tauri"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "Rust is not available. Run bootstrap-windows.ps1 first, then restart PowerShell."
}

if (-not (Get-Command cargo-tauri -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Tauri CLI from crates.io..." -ForegroundColor Cyan
    cargo install tauri-cli --version "^2.0" --locked
}

Push-Location $tauriRoot
try {
    cargo tauri build --bundles nsis
} finally {
    Pop-Location
}

$bundleDirectory = Join-Path $tauriRoot "target\release\bundle\nsis"
$installer = Get-ChildItem -Path $bundleDirectory -Filter "*-setup.exe" | Select-Object -First 1
if (-not $installer) {
    throw "The NSIS installer was not generated."
}

Write-Host "Installer created:" -ForegroundColor Green
Write-Host $installer.FullName
