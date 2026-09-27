param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
    [switch]$StagedCalculator,
    [ValidateSet('magazine','ammo','fish','literature','batch3-shadow','lightfire','explosive','incendiary','noisemaker','accessory')][string]$Utility
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$javaPath = Join-Path $GameRoot 'jre64\bin\java.exe'
$jarPath = Join-Path $GameRoot 'projectzomboid.jar'
if (-not (Test-Path -LiteralPath $javaPath) -or -not (Test-Path -LiteralPath $jarPath)) {
    throw 'Project Zomboid Java runtime/jar not found.'
}
$probeDir = Join-Path ([IO.Path]::GetTempPath()) ('ir-isolation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeDir | Out-Null
& javac -d $probeDir (Join-Path $PSScriptRoot 'tests\ItemIsolationProbe.java')
if ($LASTEXITCODE -ne 0) { throw 'Probe compilation failed.' }
Push-Location $GameRoot
try {
    $fixtures = @('item-isolation-probe.lua', 'firearm-isolation-probe.lua', 'melee-isolation-probe.lua', 'clothing-isolation-probe.lua', 'food-isolation-probe.lua', 'medical-isolation-probe.lua', 'magazine-isolation-probe.lua', 'ammo-isolation-probe.lua', 'fish-isolation-probe.lua', 'literature-isolation-probe.lua', 'batch-comparison-probe.lua')
    if ($Utility) { $fixtures = @("$Utility-isolation-probe.lua") }
    if ($Utility -eq 'batch3-shadow') { $fixtures = @('batch3-shadow-probe.lua') }
    if (-not $Utility) { $fixtures += @('lightfire-isolation-probe.lua','explosive-isolation-probe.lua','incendiary-isolation-probe.lua','noisemaker-isolation-probe.lua','accessory-isolation-probe.lua') }
    foreach ($fixtureName in $fixtures) {
        & $javaPath "-Ditemrarity.staged=$($StagedCalculator.IsPresent.ToString().ToLowerInvariant())" -cp ($probeDir + ';' + $jarPath) ItemIsolationProbe $repoRoot $fixtureName
        if ($LASTEXITCODE -ne 0) { throw "Fixture failed: $fixtureName" }
    }
} finally {
    Pop-Location
}
if ($Utility) { Write-Output "FIXTURE_GATE_PASSED=$Utility; WORLD_SCAN=NOT_RUN; SYNC=NOT_RUN" }
else { Write-Output 'FIXTURE_GATES_PASSED=15/15; WORLD_SCAN=NOT_RUN; SYNC=NOT_RUN' }
