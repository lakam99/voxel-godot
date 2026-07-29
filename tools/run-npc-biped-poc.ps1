param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [int]$Seed = 209154,
    [switch]$Capture,
    [string]$ArtifactDir = "artifacts\npcs\npc-biped-poc"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/NpcBipedPocTest.tscn", "--", "--seed", $Seed)
if (-not $Capture) {
    Write-Host "Launching seeded NPC biped visual PoC (seed $Seed)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_NPC_BIPED_POC_REPORT = Join-Path $ArtifactDir "npc-biped-poc-report.json"
$env:VOXEL_NPC_BIPED_POC_CAPTURE = Join-Path $ArtifactDir "npc-biped-poc.png"
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_NPC_BIPED_POC_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_NPC_BIPED_POC_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "npc-biped-poc-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "NPC biped PoC did not produce a report: $reportPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") { throw "NPC biped PoC capture failed." }
