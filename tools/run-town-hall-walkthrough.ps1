param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [ValidateSet("timber", "masonry")]
    [string]$Style = "masonry",
    [int]$Seed = 208154,
    [switch]$Capture,
    [ValidateSet("entry", "public", "archive", "office", "store")]
    [string]$CaptureView = "entry",
    [string]$ArtifactDir = "artifacts\buildings\town-hall-walkthrough"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/TownHallWalkthroughTest.tscn", "--", "--seed", $Seed, "--style", $Style)
if (-not $Capture) {
    Write-Host "Launching Town Hall collision and door walkthrough (seed $Seed, $Style)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_TOWN_HALL_WALKTHROUGH_REPORT = Join-Path $ArtifactDir "town-hall-walkthrough-report.json"
$env:VOXEL_TOWN_HALL_WALKTHROUGH_CAPTURE = Join-Path $ArtifactDir "town-hall-walkthrough.png"
$env:VOXEL_TOWN_HALL_WALKTHROUGH_CAPTURE_VIEW = $CaptureView
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_TOWN_HALL_WALKTHROUGH_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_TOWN_HALL_WALKTHROUGH_CAPTURE -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_TOWN_HALL_WALKTHROUGH_CAPTURE_VIEW -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "town-hall-walkthrough-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Town Hall walkthrough did not produce a report: $reportPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") { throw "Town Hall walkthrough capture failed." }
