param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [ValidateSet("timber", "masonry")]
    [string]$Style = "timber",
    [int]$Seed = 207154,
    [switch]$Capture,
    [string]$ArtifactDir = "artifacts\buildings\cottage-material-poc"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}

$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/CottageMaterialPocTest.tscn", "--", "--style", $Style, "--seed", $Seed)
if (-not $Capture) {
    Write-Host "Launching the Cottage Material PoC ($Style, seed $Seed)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_COTTAGE_POC_REPORT = Join-Path $ArtifactDir "cottage-material-poc-report.json"
$env:VOXEL_COTTAGE_POC_CAPTURE = Join-Path $ArtifactDir "cottage-material-poc.png"
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_COTTAGE_POC_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_COTTAGE_POC_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) {
    exit $exitCode
}
$reportPath = Join-Path $ArtifactDir "cottage-material-poc-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) {
    throw "Cottage Material PoC did not produce a report: $reportPath"
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") {
    throw "Cottage Material PoC capture failed."
}
