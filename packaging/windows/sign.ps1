#Requires -Version 5.1
<#
  Code-sign NexusLink-Host-Setup.exe and (when present) the IddCx catalog.

  Local / CI:
    $env:NEXUSLINK_PFX = path to .pfx
    $env:NEXUSLINK_PFX_PASSWORD = password
    .\sign.ps1

  Attestation signing of NexusLinkIdd.cat is done in Microsoft Partner Center
  (hardware dashboard) with an EV certificate. This script only runs signtool
  Authenticode on the installer and user-mode binaries.
#>
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Dist = Join-Path $Root 'dist'
$Pfx = $env:NEXUSLINK_PFX
if (-not $Pfx -or -not (Test-Path $Pfx)) {
    Write-Host 'NEXUSLINK_PFX not set — skipping Authenticode. Unsigned binaries are fine for this PC.'
    exit 0
}
$Password = $env:NEXUSLINK_PFX_PASSWORD
if (-not (Get-Command signtool -ErrorAction SilentlyContinue)) {
    throw 'signtool.exe not on PATH (install Windows SDK)'
}
$files = @(
    Get-ChildItem -Path $Dist -Recurse -Include *.exe,*.dll,*.sys,*.cat -ErrorAction SilentlyContinue
)
foreach ($f in $files) {
    Write-Host "Signing $($f.FullName)"
    if ($Password) {
        signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $Pfx /p $Password $f.FullName
    } else {
        signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $Pfx $f.FullName
    }
}
