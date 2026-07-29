param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "artifacts\npcs\npc-biped-recipe-contract"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_NPC_BIPED_RECIPE_CONTRACT_REPORT = Join-Path $ArtifactDir "npc-biped-recipe-contract.json"
try {
    & $GodotExe --headless --path $ProjectPath --script res://scripts/testing/npcs/NpcBipedRecipeContractRunner.gd
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item Env:VOXEL_NPC_BIPED_RECIPE_CONTRACT_REPORT -ErrorAction SilentlyContinue
}
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "npc-biped-recipe-contract.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "NPC biped recipe contract did not produce a report: $reportPath" }
Get-Content -LiteralPath $reportPath -Raw
