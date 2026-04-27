param(
    [string]$FlutterSdkPath = 'C:\flutter',
    [switch]$InstallFlutterIfMissing,
    [switch]$InstallVsBuildToolsIfMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
    if (-not (Test-Command 'winget')) {
        throw "winget is not available. Install App Installer from Microsoft Store, then retry."
    }
}

function Test-PubDevAccess {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://pub.dev' -TimeoutSec 20
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    }
    catch {
        return $false
    }
}

function Invoke-FlutterCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        & flutter @Arguments
        if ($LASTEXITCODE -eq 0) {
            return
        }

        if ($attempt -eq $MaxAttempts) {
            throw "flutter $($Arguments -join ' ') failed after $MaxAttempts attempts."
        }

        Write-Warning "flutter $($Arguments -join ' ') failed on attempt $attempt. Retrying..."
    }
}

function Get-FlutterPath {
    if (Test-Command 'flutter') {
        return (Get-Command flutter).Source
    }
    return $null
}

function Ensure-FlutterOnPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FlutterSdkPath
    )

    $flutterBin = Join-Path $FlutterSdkPath 'bin'
    $flutterBat = Join-Path $flutterBin 'flutter.bat'
    if (-not (Test-Path $flutterBat)) {
        return $false
    }

    if (($env:Path -split ';') -notcontains $flutterBin) {
        $env:Path = "$flutterBin;$env:Path"
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) {
        $userPath = ''
    }

    $pathEntries = $userPath -split ';' | Where-Object { $_ -ne '' }
    if ($pathEntries -notcontains $flutterBin) {
        $newPath = ($pathEntries + $flutterBin) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Host "Added Flutter to user PATH: $flutterBin" -ForegroundColor Green
        Write-Host "Re-open terminal to apply PATH changes." -ForegroundColor Yellow
    }

    return $true
}

function Install-Flutter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FlutterSdkPath
    )

    if (Test-Path $FlutterSdkPath) {
        $existingFlutterBat = Join-Path $FlutterSdkPath 'bin\flutter.bat'
        if (Test-Path $existingFlutterBat) {
            Ensure-FlutterOnPath -FlutterSdkPath $FlutterSdkPath | Out-Null
            Write-Host "Flutter SDK path already exists: $FlutterSdkPath" -ForegroundColor Yellow
            return
        }

        Write-Warning "FlutterSdkPath exists but is not a valid Flutter SDK. Removing and reinstalling: $FlutterSdkPath"
        Remove-Item -Path $FlutterSdkPath -Recurse -Force
    }

    Write-Step "Install Flutter SDK to $FlutterSdkPath"
    if (-not (Test-Command 'git')) {
        throw "git command not found. Install Git first or install Flutter manually, then retry."
    }

    git clone https://github.com/flutter/flutter.git -b stable "$FlutterSdkPath"

    $flutterBin = Join-Path $FlutterSdkPath 'bin'
    if (-not (Test-Path $flutterBin)) {
        throw "Flutter bin directory not found after git clone: $flutterBin"
    }

    Ensure-FlutterOnPath -FlutterSdkPath $FlutterSdkPath | Out-Null
}

function Install-VsBuildTools {
    Write-Step "Install Visual Studio 2022 Build Tools (Desktop C++ + Windows SDK)"
    Ensure-Winget

    winget install --id Microsoft.VisualStudio.2022.BuildTools --source winget --accept-package-agreements --accept-source-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows10SDK.19041 --includeRecommended"
}

function Enable-FlutterWindowsDesktop {
    $flutterCmd = Get-FlutterPath
    if (-not $flutterCmd) {
        throw "flutter command not found. Install Flutter and reopen terminal, then retry."
    }

    if (-not (Test-PubDevAccess)) {
        throw "pub.dev is not reachable from this machine right now. Check proxy/VPN/firewall and retry."
    }

    Write-Step "Enable Flutter Windows desktop"
    Invoke-FlutterCommand -Arguments @('config', '--enable-windows-desktop')
}

function Run-Doctor {
    if (-not (Test-PubDevAccess)) {
        throw "pub.dev is not reachable from this machine right now. Check proxy/VPN/firewall and retry."
    }

    Write-Step "Run flutter doctor -v"
    Invoke-FlutterCommand -Arguments @('doctor', '-v')
}

Write-Host "Storyforge Windows build environment setup script" -ForegroundColor Green

Ensure-FlutterOnPath -FlutterSdkPath $FlutterSdkPath | Out-Null

$flutterPath = Get-FlutterPath
if (-not $flutterPath -and $InstallFlutterIfMissing) {
    Install-Flutter -FlutterSdkPath $FlutterSdkPath
    $flutterPath = Get-FlutterPath
}

if (-not $flutterPath) {
    Write-Warning "flutter command not found. Install Flutter first, or use -InstallFlutterIfMissing."
}
else {
    Write-Host "Detected Flutter: $flutterPath" -ForegroundColor Green
}

$vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsFound = $false
if (Test-Path $vsWhere) {
    $vsInstall = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsInstall) {
        $vsFound = $true
        Write-Host "Detected VS Build Tools/Visual Studio: $vsInstall" -ForegroundColor Green
    }
}

if (-not $vsFound -and $InstallVsBuildToolsIfMissing) {
    Install-VsBuildTools
    Write-Host "VS Build Tools install command executed. Reboot may be required before first build." -ForegroundColor Yellow
}
elseif (-not $vsFound) {
    Write-Warning "Desktop C++ toolchain not found. Use -InstallVsBuildToolsIfMissing to install."
}

if ($flutterPath) {
    Enable-FlutterWindowsDesktop
    Run-Doctor
}

Write-Host "`nEnvironment setup flow completed." -ForegroundColor Green
