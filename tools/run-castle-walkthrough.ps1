param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [int]$Seed = 208158,
    [float]$CitadelScale = 6.0,
    [switch]$Capture,
    [string]$ArtifactDir = "artifacts\buildings\castle-walkthrough"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/CastleWalkthroughTest.tscn", "--", "--seed", $Seed, "--citadel-scale", $CitadelScale)
if (-not $Capture) {
    Write-Host "Launching Castle collision and door walkthrough (seed $Seed)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_CASTLE_WALKTHROUGH_REPORT = Join-Path $ArtifactDir "castle-walkthrough-report.json"
$env:VOXEL_CASTLE_WALKTHROUGH_CAPTURE = Join-Path $ArtifactDir "castle-walkthrough.png"
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_CASTLE_WALKTHROUGH_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_CASTLE_WALKTHROUGH_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "castle-walkthrough-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Castle walkthrough did not produce a report: $reportPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") { throw "Castle walkthrough capture failed." }
