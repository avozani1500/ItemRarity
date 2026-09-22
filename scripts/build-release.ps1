[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$')]
    [string]$Version,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path $repositoryRoot 'release' }
$packageRoot = Join-Path $OutputRoot "ItemRarity-$Version"
$source42 = Join-Path $repositoryRoot '42.20'
$sourceCommon = Join-Path $repositoryRoot 'common'

if (Test-Path -LiteralPath $packageRoot) {
    throw "Release target already exists and will not be overwritten: $packageRoot"
}
foreach ($required in @($source42, $sourceCommon, (Join-Path $repositoryRoot 'README.md'), (Join-Path $repositoryRoot 'CHANGELOG.md'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing release source: $required" }
}

New-Item -ItemType Directory -Path $packageRoot | Out-Null
$package42 = Join-Path $packageRoot '42.20'
& robocopy $source42 $package42 /E /XD Diagnostics /XF *Audit*.lua *Profiler*.lua *Snapshot*.lua /FFT /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Host
if ($LASTEXITCODE -ge 8) { throw "Unable to copy 42.20 runtime files (robocopy exit $LASTEXITCODE)." }
& robocopy $sourceCommon (Join-Path $packageRoot 'common') /E /FFT /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Host
if ($LASTEXITCODE -ge 8) { throw "Unable to copy common runtime files (robocopy exit $LASTEXITCODE)." }
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'README.md'), (Join-Path $repositoryRoot 'CHANGELOG.md') -Destination $packageRoot

@(
    'name=Item Rarity',
    'id=ItemRarity',
    'description=Structural item rarity for Project Zomboid.',
    'author=Natan',
    "modversion=$Version",
    'versionMin=42.20.0',
    'poster=poster.png',
    'icon=poster.png'
) | Set-Content -LiteralPath (Join-Path $package42 'mod.info') -Encoding utf8

$forbidden = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Force | Where-Object {
    $_.FullName -match '\\Diagnostics(\\|$)' -or $_.Name -match '^(\.git|.*(?:Audit|Report|Snapshot|Dump|Profiler).*(?:\.lua|\.txt|\.log)?)$'
})
if ($forbidden.Count -gt 0) { throw "Release package contains excluded artifacts: $($forbidden.FullName -join ', ')" }
foreach ($required in @(
    (Join-Path $package42 'mod.info'),
    (Join-Path $package42 'poster.png'),
    (Join-Path $package42 'media'),
    (Join-Path $packageRoot 'common'),
    (Join-Path $packageRoot 'README.md'),
    (Join-Path $packageRoot 'CHANGELOG.md')
)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Incomplete release package; missing $required" }
}
Write-Host "Release package built and verified: $packageRoot"
