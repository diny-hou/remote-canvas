$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "RemoteCanvas Windows build prerequisites" -ForegroundColor Cyan

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required. Install or update App Installer from Microsoft Store."
}

if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Write-Host "Installing the official Rust toolchain..."
    winget install --id Rustlang.Rustup --exact --source winget --accept-package-agreements --accept-source-agreements
    $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Host "Installing Microsoft C++ Build Tools..."
    winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget `
        --accept-package-agreements --accept-source-agreements `
        --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
}

rustup default stable-msvc
Write-Host "Prerequisites installed. Restart PowerShell, then run build-installer.ps1." -ForegroundColor Green
