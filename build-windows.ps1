param(
    [switch]$Clean,
    [switch]$Zip,
    [string]$BuildName,
    [string]$BuildNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetScript = Join-Path $PSScriptRoot 'scripts\win\build-windows.ps1'
if (-not (Test-Path $targetScript)) {
    throw "Target script not found: $targetScript"
}

$forwardedArgs = @()
if ($Clean) {
    $forwardedArgs += '-Clean'
}
if ($Zip) {
    $forwardedArgs += '-Zip'
}
if ($BuildName) {
    $forwardedArgs += '-BuildName', $BuildName
}
if ($BuildNumber) {
    $forwardedArgs += '-BuildNumber', $BuildNumber
}

& $targetScript @forwardedArgs
exit $LASTEXITCODE