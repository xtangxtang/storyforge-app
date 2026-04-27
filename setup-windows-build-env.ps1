param(
    [string]$FlutterSdkPath = 'C:\flutter',
    [switch]$InstallFlutterIfMissing,
    [switch]$InstallVsBuildToolsIfMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetScript = Join-Path $PSScriptRoot 'scripts\win\setup-windows-build-env.ps1'
if (-not (Test-Path $targetScript)) {
    throw "Target script not found: $targetScript"
}

$forwardedArgs = @('-FlutterSdkPath', $FlutterSdkPath)
if ($InstallFlutterIfMissing) {
    $forwardedArgs += '-InstallFlutterIfMissing'
}
if ($InstallVsBuildToolsIfMissing) {
    $forwardedArgs += '-InstallVsBuildToolsIfMissing'
}

& $targetScript @forwardedArgs
exit $LASTEXITCODE