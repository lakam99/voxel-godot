param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "artifacts\combat\procedural-motion-poc",
    [int]$ReviewSeconds = 0,
    [switch]$SlowMo,
    [ValidateRange(0.05, 3.20)]
    [double]$SlowMoRate = 0.20
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$ArtifactDir = [IO.Path]::GetFullPath((Join-Path $ProjectPath $ArtifactDir))
$ContractReport = Join-Path $ArtifactDir "motion-contract.json"
$PocReport = Join-Path $ArtifactDir "motion-poc-report.json"
$ScreenshotDir = Join-Path $ArtifactDir "screenshots"
New-Item -ItemType Directory -Force -Path $ArtifactDir,$ScreenshotDir | Out-Null
if (-not $SlowMo) {
    Remove-Item -LiteralPath $ContractReport,$PocReport -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $ScreenshotDir -Filter "*.png" -File -ErrorAction SilentlyContinue | Remove-Item -Force
}

if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}

$env:VOXEL_PROCEDURAL_MOTION_CONTRACT_REPORT = $ContractReport
$ContractOutput = & $GodotExe --headless --path $ProjectPath --script res://scripts/testing/combat/ProceduralMotionContractRunner.gd 2>&1
$ContractExit = $LASTEXITCODE
$ContractOutput | Write-Host
if ($ContractOutput -match "SCRIPT ERROR|Parse Error|Compile Error|ERROR: Failed") {
    throw "Motion representation contract emitted a Godot script error"
}
if (-not (Test-Path -LiteralPath $ContractReport)) {
    throw "Motion contract runner did not write report: $ContractReport"
}
$Contract = Get-Content -LiteralPath $ContractReport -Raw | ConvertFrom-Json
if ($ContractExit -ne 0 -or $true -ne $Contract.passed) {
    throw "Motion representation contract failed"
}

if ($SlowMo) {
    $env:VOXEL_PROCEDURAL_MOTION_POC_AUTORUN = "0"
    $env:VOXEL_PROCEDURAL_MOTION_POC_AUTOPLAY = "1"
    $env:VOXEL_PROCEDURAL_MOTION_POC_PLAYBACK_RATE = [string]$SlowMoRate
    Write-Host "Launching interactive slow-motion Procedural Motion PoC at $SlowMoRate`x. Close the Godot window when finished."
    & $GodotExe --path $ProjectPath --resolution 1280x720 --scene res://scenes/testing/ProceduralMotionPocTest.tscn
    if ($LASTEXITCODE -ne 0) {
        throw "Slow-motion Procedural Motion PoC exited with code $LASTEXITCODE"
    }
    return
}

$env:VOXEL_PROCEDURAL_MOTION_POC_AUTORUN = "1"
$env:VOXEL_PROCEDURAL_MOTION_POC_REPORT = $PocReport
$env:VOXEL_PROCEDURAL_MOTION_POC_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_PROCEDURAL_MOTION_POC_REVIEW_SECONDS = [string]$ReviewSeconds
$PocOutput = & $GodotExe --path $ProjectPath --resolution 1280x720 --scene res://scenes/testing/ProceduralMotionPocTest.tscn 2>&1
$PocExit = $LASTEXITCODE
$PocOutput | Write-Host
if ($PocOutput -match "SCRIPT ERROR|Parse Error|Compile Error|ERROR: Failed") {
    throw "Procedural Motion PoC emitted a Godot script error"
}
if (-not (Test-Path -LiteralPath $PocReport)) {
    throw "Motion PoC runner did not write report: $PocReport"
}
$Poc = Get-Content -LiteralPath $PocReport -Raw | ConvertFrom-Json
$RequiredCaptures = @(
	"single_seed_1543_windup_gameplay_height.png",
    "single_seed_1543_front.png",
	"single_seed_1543_gameplay_height.png",
    "single_seed_7651_front.png",
    "single_seed_1543_side.png",
    "stack_synchronized.png",
    "stack_staggered.png",
    "stack_staggered_elevated.png"
)
$MissingCaptures = @($RequiredCaptures | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ScreenshotDir $_)) })
if ($PocExit -ne 0 -or $true -ne $Poc.passed -or $MissingCaptures.Count -gt 0) {
    throw "Motion PoC visual runner failed. Missing captures: $($MissingCaptures -join ', ')"
}

[ordered]@{
    runnerId = "procedural_motion_poc"
    evidenceLevel = "visual_poc"
    passed = $true
    scope = "isolated motion/contact-volume/passive-geometry proof only; no engine physics query, damage, AI, rig, save, or live-game integration"
    contractReport = $ContractReport
    pocReport = $PocReport
    screenshotDir = $ScreenshotDir
    captureCount = @($Poc.captures).Count
} | ConvertTo-Json
