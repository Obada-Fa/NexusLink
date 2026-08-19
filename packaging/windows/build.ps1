#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $Root

$Out = Join-Path $Root 'dist\windows'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host 'Installing workspace…'
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw 'Bun is required to compile the host. Install from https://bun.sh'
}
bun install

Write-Host 'Building PWA…'
bun run --cwd apps/mobile-client build

Write-Host 'Compiling Windows host…'
$env:NEXUSLINK_STATIC_DIR = (Join-Path $Root 'apps\mobile-client\out')
bun build --compile --outfile (Join-Path $Out 'nexuslink-host.exe') apps/windows-host/src/server/index.ts

Copy-Item -Recurse -Force (Join-Path $Root 'apps\mobile-client\out') (Join-Path $Out 'www')

if (Get-Command cargo -ErrorAction SilentlyContinue) {
    Write-Host 'Building sidecar…'
    cargo build --release --manifest-path (Join-Path $Root 'sidecar\Cargo.toml')
    $sidecar = Join-Path $Root 'sidecar\target\release\nexuslink-sidecar.exe'
    if (Test-Path $sidecar) { Copy-Item $sidecar $Out }
}

$conpty = Join-Path $Root 'apps\windows-host\native\conpty-host.exe'
if (Test-Path $conpty) { Copy-Item $conpty $Out }

$nsi = Join-Path $PSScriptRoot 'nexuslink.nsi'
if (Get-Command makensis -ErrorAction SilentlyContinue) {
    Write-Host 'Building installer…'
    makensis /DHOST_DIR="$Out" $nsi
} else {
    Write-Host 'makensis not found — zip the dist\windows folder or install NSIS.'
}

Write-Host "Artifacts in $Out"
