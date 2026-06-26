param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$OutputDir = "",
    [string]$Seed = "atlas-1492",
    [switch]$UpdateBaseline,
    [switch]$Headless
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($OutputDir -eq "") {
    $OutputDir = Join-Path $projectPath "artifacts\visual\latest"
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$baselineDir = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\baselines\visual\phase1"))

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_VISUAL_CAPTURE_DIR = $OutputDir
$env:VOXEL_TEST_SEED = $Seed

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$args = @("--fixed-fps", "60", "--resolution", "1280x720", "--path", $projectPath, "--scene", "res://scenes/VisualCapture.tscn")
if ($Headless) {
    $args = @("--headless") + $args
}

& $GodotExe @args
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    exit $exitCode
}

$expectedCases = @(
    "town_noon",
    "town_sunset",
    "forest_midnight",
    "forest_midnight_lights",
    "forest_rain",
    "mountain_day",
    "water_overcast",
    "hud_gameplay"
)
foreach ($caseName in $expectedCases) {
    $pngPath = Join-Path $OutputDir "$caseName.png"
    $jsonPath = Join-Path $OutputDir "$caseName.json"
    if (-not (Test-Path -LiteralPath $pngPath)) {
        throw "Missing visual capture PNG: $pngPath"
    }
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        throw "Missing visual capture metadata: $jsonPath"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $OutputDir "visual-captures.json"))) {
    throw "Missing visual capture report: $(Join-Path $OutputDir "visual-captures.json")"
}

if ($UpdateBaseline) {
    $baselineRoot = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\baselines"))
    if (-not $baselineDir.StartsWith($baselineRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to update baseline outside artifacts\baselines: $baselineDir"
    }
    if (Test-Path -LiteralPath $baselineDir) {
        Remove-Item -LiteralPath $baselineDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $baselineDir | Out-Null
    Copy-Item -Path (Join-Path $OutputDir "*") -Destination $baselineDir -Recurse -Force
}

Get-ChildItem -LiteralPath $OutputDir -File | Select-Object Name,Length | Format-Table -AutoSize
exit 0
