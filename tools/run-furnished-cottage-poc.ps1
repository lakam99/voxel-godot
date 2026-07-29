param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [ValidateSet("timber", "masonry")]
    [string]$Style = "timber",
    [ValidateSet("exterior", "dollhouse", "hearth", "sleeping")]
    [string]$View = "dollhouse",
    [int]$Seed = 207154,
    [switch]$Capture,
    [string]$ArtifactDir = "artifacts\buildings\furnished-cottage-poc"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}

$arguments = @("--path", $ProjectPath, "--resolution", "1280x720", "--scene", "res://scenes/testing/buildings/FurnishedCottagePocTest.tscn", "--", "--style", $Style, "--seed", $Seed, "--view", $View)
if (-not $Capture) {
    Write-Host "Launching the furnished cottage PoC ($Style, $View, seed $Seed)."
    & $GodotExe @arguments
    exit $LASTEXITCODE
}

$ArtifactDir = Join-Path $ProjectPath $ArtifactDir
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$env:VOXEL_FURNISHED_COTTAGE_POC_REPORT = Join-Path $ArtifactDir "furnished-cottage-poc-report.json"
$env:VOXEL_FURNISHED_COTTAGE_POC_CAPTURE = Join-Path $ArtifactDir "furnished-cottage-poc.png"
& $GodotExe @arguments
$exitCode = $LASTEXITCODE
Remove-Item Env:VOXEL_FURNISHED_COTTAGE_POC_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_FURNISHED_COTTAGE_POC_CAPTURE -ErrorAction SilentlyContinue
if ($exitCode -ne 0) {
    exit $exitCode
}
$reportPath = Join-Path $ArtifactDir "furnished-cottage-poc-report.json"
if (-not (Test-Path -LiteralPath $reportPath)) {
    throw "Furnished cottage PoC did not produce a report: $reportPath"
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($report.status -ne "passed") {
    throw "Furnished cottage PoC capture failed."
}
