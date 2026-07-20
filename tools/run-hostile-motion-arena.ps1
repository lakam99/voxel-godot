param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [switch]$Verify,
    [switch]$Capture,
    [string]$OpponentId = "hostile.shadow",
    [string]$ArtifactDir = "artifacts\combat\hostile-motion-arena"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}

if ($Verify -or $Capture) {
    $ArtifactDir = Join-Path $ProjectPath $ArtifactDir
    New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
    $reportPath = Join-Path $ArtifactDir "hostile-motion-arena-report.json"
    Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    $env:VOXEL_HOSTILE_MOTION_ARENA_AUTOVERIFY = "1"
    $env:VOXEL_HOSTILE_MOTION_ARENA_REPORT = $reportPath
    $capturePath = Join-Path $ArtifactDir "hostile-motion-arena.png"
    if ($Capture) {
        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $env:VOXEL_HOSTILE_MOTION_ARENA_CAPTURE = $capturePath
        Write-Host "Running standalone hostile-motion arena visual fixture capture."
        & $GodotExe --path $ProjectPath --resolution 1280x720 --scene res://scenes/testing/HostileMotionArenaTest.tscn -- --arena-opponent $OpponentId
    } else {
        Write-Host "Running standalone hostile-motion arena fixture verification."
        & $GodotExe --headless --path $ProjectPath --scene res://scenes/testing/HostileMotionArenaTest.tscn -- --arena-opponent $OpponentId
    }
    Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_AUTOVERIFY -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_REPORT -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_CAPTURE -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $reportPath)) {
        throw "Hostile Motion Arena did not produce a report: $reportPath"
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $report | ConvertTo-Json -Depth 8
    if ($LASTEXITCODE -ne 0 -or $report.status -ne "passed") {
        throw "Hostile Motion Arena verification failed."
    }
    if ($Capture -and -not (Test-Path -LiteralPath $capturePath)) {
        throw "Hostile Motion Arena did not produce a visual capture: $capturePath"
    }
    exit 0
}

Write-Host "Launching the interactive Hostile Motion Arena. Close the Godot window when finished."
& $GodotExe --path $ProjectPath --resolution 1280x720 --scene res://scenes/testing/HostileMotionArenaTest.tscn -- --arena-opponent $OpponentId
if ($LASTEXITCODE -ne 0) {
    throw "Hostile Motion Arena exited with code $LASTEXITCODE"
}
