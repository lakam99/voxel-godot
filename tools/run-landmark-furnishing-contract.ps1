param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "artifacts\buildings\landmark-furnishing-contract"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_LANDMARK_FURNISHING_CONTRACT_REPORT = Join-Path $ArtifactDir "landmark-furnishing-contract.json"
& $GodotExe --headless --path $ProjectPath --script res://scripts/testing/buildings/LandmarkFurnishingContractRunner.gd
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_LANDMARK_FURNISHING_CONTRACT_REPORT -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "landmark-furnishing-contract.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Landmark furnishing contract did not produce a report: $reportPath" }
Get-Content -LiteralPath $reportPath -Raw
