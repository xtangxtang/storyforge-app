param(
    [switch]$Clean,
    [switch]$Zip,
    [string]$BuildName,
    [string]$BuildNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Command not found: $Name. Install and configure it before running this script."
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir '..')
Set-Location $repoRoot

Write-Host "Storyforge one-click Windows build script" -ForegroundColor Green
Write-Host "Project root: $repoRoot"

Assert-Tool 'flutter'

Write-Step "Enable Windows desktop target"
flutter config --enable-windows-desktop

if ($Clean) {
    Write-Step "Run flutter clean"
    flutter clean
}

Write-Step "Install dependencies with flutter pub get"
flutter pub get

$buildArgs = @('build', 'windows', '--release')
if ($BuildName) {
    $buildArgs += "--build-name=$BuildName"
}
if ($BuildNumber) {
    $buildArgs += "--build-number=$BuildNumber"
}

Write-Step "Build Windows release"
flutter @buildArgs

$outputDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path $outputDir)) {
    throw "Build finished but output directory was not found: $outputDir"
}

Write-Host "`nBuild succeeded. Output directory: $outputDir" -ForegroundColor Green

if ($Zip) {
    $distDir = Join-Path $repoRoot 'build\dist'
    if (-not (Test-Path $distDir)) {
        New-Item -ItemType Directory -Path $distDir | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zipPath = Join-Path $distDir "storyforge-windows-release-$timestamp.zip"

    Write-Step "Pack zip: $zipPath"
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $outputDir '*') -DestinationPath $zipPath
    Write-Host "Zip package created: $zipPath" -ForegroundColor Green
}
