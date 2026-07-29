param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [int]$Seed = 208154,
    [float]$CitadelScale = 0.0,
    [float]$OrbitDegrees = -138.0,
    [float]$ReviewDistanceScale = 1.34,
    [float]$ReviewHeightScale = 1.10,
    [float]$ReviewFocusX = 0.0,
    [float]$ReviewFocusZ = 0.0,
    [switch]$Capture,
    [string]$ArtifactDir = "artifacts\buildings\castle-poc"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/CastlePocTest.tscn", "--", "--seed", $Seed, "--citadel-scale", $CitadelScale, "--orbit-degrees", $OrbitDegrees, "--review-distance-scale", $ReviewDistanceScale, "--review-height-scale", $ReviewHeightScale, "--review-focus-x", $ReviewFocusX, "--review-focus-z", $ReviewFocusZ)
if (-not $Capture) {
    Write-Host "Launching generated Castle visual PoC (seed $Seed)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_CASTLE_POC_REPORT = Join-Path $ArtifactDir "castle-poc-report.json"
$env:VOXEL_CASTLE_POC_CAPTURE = Join-Path $ArtifactDir "castle-poc.png"
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_CASTLE_POC_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_CASTLE_POC_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "castle-poc-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Castle PoC did not produce a report: $reportPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") { throw "Castle PoC capture failed." }
