param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [ValidateSet("timber", "masonry")]
    [string]$Style = "timber",
    [int]$Seed = 208155,
    [switch]$Capture,
    [ValidateSet("entry", "stairs", "solar", "attic")]
    [string]$CaptureView = "entry",
    [string]$ArtifactDir = "artifacts\buildings\manor-walkthrough"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/ManorWalkthroughTest.tscn", "--", "--seed", $Seed, "--style", $Style)
if (-not $Capture) {
    Write-Host "Launching Manor collision and door walkthrough (seed $Seed, $Style)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_MANOR_WALKTHROUGH_REPORT = Join-Path $ArtifactDir "manor-walkthrough-report.json"
$env:VOXEL_MANOR_WALKTHROUGH_CAPTURE = Join-Path $ArtifactDir "manor-walkthrough.png"
$arguments += @("--report-path", $env:VOXEL_MANOR_WALKTHROUGH_REPORT, "--capture-path", $env:VOXEL_MANOR_WALKTHROUGH_CAPTURE, "--capture-view", $CaptureView)
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_MANOR_WALKTHROUGH_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_MANOR_WALKTHROUGH_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { exit $exitCode }
$reportPath = Join-Path $ArtifactDir "manor-walkthrough-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Manor walkthrough did not produce a report: $reportPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") { throw "Manor walkthrough capture failed." }
