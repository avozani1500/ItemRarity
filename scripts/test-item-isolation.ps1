param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
    [switch]$StagedCalculator
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
    foreach ($fixtureName in @('item-isolation-probe.lua', 'firearm-isolation-probe.lua', 'melee-isolation-probe.lua', 'batch-comparison-probe.lua')) {
        & $javaPath "-Ditemrarity.staged=$($StagedCalculator.IsPresent.ToString().ToLowerInvariant())" -cp ($probeDir + ';' + $jarPath) ItemIsolationProbe $repoRoot $fixtureName
        if ($LASTEXITCODE -ne 0) { throw "Fixture failed: $fixtureName" }
    }
} finally {
    Pop-Location
}
Write-Output 'FIXTURE_GATES_PASSED=3/15; WORLD_SCAN=NOT_RUN; SYNC=NOT_RUN'
