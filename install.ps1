# RawView Windows PowerShell Installer
# Usage:
#   irm https://raw.githubusercontent.com/taixuann/raw-viewer/master/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo = "taixuann/raw-viewer"
$BinName = "raw-viewer.exe"
$InstallDir = if ($env:RAW_VIEWER_BIN_DIR) { $env:RAW_VIEWER_BIN_DIR } else { "$env:LOCALAPPDATA\raw-viewer\bin" }
$Version = if ($env:RAW_VIEWER_VERSION) { $env:RAW_VIEWER_VERSION } else { "latest" }

Write-Host "==> Installing RawView CLI for Windows (x86_64)..." -ForegroundColor Cyan

# 1. Resolve Version
if ($Version -eq "latest") {
    try {
        $Latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "RawView-Installer" }
        $Version = $Latest.tag_name
    } catch {
        $Version = "v0.2.0"
        Write-Warning "Could not resolve latest release via GitHub API. Using fallback $Version."
    }
}

Write-Host "==> Selected version: $Version" -ForegroundColor Green

$ArchiveName = "raw-viewer-x86_64-pc-windows-msvc.zip"
$DownloadUrl = "https://github.com/$Repo/releases/download/$Version/$ArchiveName"

# 2. Download
$TempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
[System.IO.Directory]::CreateDirectory($TempDir) | Out-Null
$ZipPath = [System.IO.Path]::Combine($TempDir, $ArchiveName)

try {
    Write-Host "==> Downloading $DownloadUrl..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing

    # 3. Extract
    Write-Host "==> Extracting to $InstallDir..." -ForegroundColor Cyan
    if (!(Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $TempDir -Force

    $ExtractedBin = Get-ChildItem -Path $TempDir -Filter $BinName -Recurse | Select-Object -First 1
    if (!$ExtractedBin) {
        throw "Binary $BinName not found in downloaded archive."
    }

    Copy-Item -Path $ExtractedBin.FullName -Destination (Join-Path $InstallDir $BinName) -Force

    Write-Host "==> Successfully installed $BinName to $InstallDir" -ForegroundColor Green

    # 4. PATH Check
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($UserPath -notlike "*$InstallDir*") {
        Write-Host "==> Adding $InstallDir to User PATH..." -ForegroundColor Cyan
        [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
        $env:Path += ";$InstallDir"
        Write-Host "==> User PATH updated. Restart your terminal to refresh." -ForegroundColor Green
    }

    # 5. Test
    $TargetExe = Join-Path $InstallDir $BinName
    if (Test-Path $TargetExe) {
        & $TargetExe --version
    }

    Write-Host "`nRawView CLI is ready to use!" -ForegroundColor Green
    Write-Host "Try running: raw-viewer doctor`n" -ForegroundColor Yellow
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item -Recurse -Force $TempDir
    }
}
