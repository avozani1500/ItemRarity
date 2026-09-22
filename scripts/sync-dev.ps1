[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$developmentInstall = 'C:\Users\Natan\Zomboid\mods\ItemRarity_DEV'
$sourceRoots = @('42.20', 'common')

if ($Apply -and $Check) { throw 'Use either -Check or -Apply, not both.' }

function Assert-SafeTarget([string]$Path) {
    $resolvedRepository = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
    $resolvedTarget = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($resolvedRepository -eq $resolvedTarget) { throw 'Refusing to synchronize a repository onto itself.' }
    if ($resolvedTarget -ne 'C:\Users\Natan\Zomboid\mods\ItemRarity_DEV') { throw "Unexpected DEV installation target: $resolvedTarget" }
}

function Invoke-Mirror([string]$Source, [string]$Target) {
    $arguments = @($Source, $Target, '/MIR', '/FFT', '/R:1', '/W:1', '/NJH', '/NJS', '/NDL', '/NFL')
    if (-not $Apply) { $arguments += '/L' }
    & robocopy @arguments | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed while processing $Source (exit code $LASTEXITCODE)." }
}

function Get-TreeManifest([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        "$relative|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
}

Assert-SafeTarget $developmentInstall
foreach ($name in $sourceRoots) {
    $source = Join-Path $repositoryRoot $name
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing repository root: $source" }
}

$unexpected = @()
if (Test-Path -LiteralPath $developmentInstall) {
    $unexpected = @(Get-ChildItem -LiteralPath $developmentInstall -Force | Where-Object { $_.Name -notin $sourceRoots })
}
if ($unexpected.Count -gt 0) {
    throw "DEV installation contains unexpected top-level entries: $($unexpected.Name -join ', '). Report and resolve them; this script will not delete them."
}

if (-not (Test-Path -LiteralPath $developmentInstall)) {
    if (-not $Apply) {
        Write-Host "DEV installation is missing: $developmentInstall (run with -Apply to create it)."
        exit 2
    }
    New-Item -ItemType Directory -Path $developmentInstall | Out-Null
}

foreach ($name in $sourceRoots) {
    Invoke-Mirror (Join-Path $repositoryRoot $name) (Join-Path $developmentInstall $name)
}

if (-not $Apply) {
    Write-Host 'Check only: no files were changed. Use -Apply after reviewing the differences.'
    exit 0
}

foreach ($name in $sourceRoots) {
    $sourceManifest = Get-TreeManifest (Join-Path $repositoryRoot $name)
    $targetManifest = Get-TreeManifest (Join-Path $developmentInstall $name)
    $difference = Compare-Object -ReferenceObject $sourceManifest -DifferenceObject $targetManifest
    if ($difference) { throw "Post-sync verification failed for $name." }
}

Write-Host "DEV installation synchronized and hash-verified: $developmentInstall"
