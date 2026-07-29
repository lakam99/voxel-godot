param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [ValidateSet("timber", "masonry")]
    [string]$Style = "masonry",
    [int]$Seed = 208154,
    [switch]$Capture,
    [string]$ArtifactDir = "artifacts\buildings\town-hall-poc"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }

$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/TownHallPocTest.tscn", "--", "--style", $Style, "--seed", $Seed)
if (-not $Capture) {
    Write-Host "Launching the Town Hall PoC ($Style, seed $Seed)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_TOWN_HALL_POC_REPORT = Join-Path $ArtifactDir "town-hall-poc-report.json"
$env:VOXEL_TOWN_HALL_POC_CAPTURE = Join-Path $ArtifactDir "town-hall-poc.png"
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_TOWN_HALL_POC_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_TOWN_HALL_POC_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "town-hall-poc-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Town Hall PoC did not produce a report: $reportPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") { throw "Town Hall PoC capture failed." }
