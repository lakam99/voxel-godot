param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$TestSeed = "",
    [switch]$RuntimeReset,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\tutorial-town\main-menu-startup-readiness-smoke.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT = $ReportPath
$env:VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE = "new_game"
if ($TestSeed -ne "") {
    $env:VOXEL_TEST_SEED = $TestSeed
}
if ($RuntimeReset) {
    $env:VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET = "1"
} else {
    Remove-Item Env:\VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET -ErrorAction SilentlyContinue
}
Remove-Item Env:\VOXEL_MAIN_MENU_STARTUP_REAL_SAVE_MODE,Env:\VOXEL_MAIN_MENU_STARTUP_PERSIST_SAVE -ErrorAction SilentlyContinue
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$godotArgs = @("--path", $projectPath, "--script", "res://scripts/testing/MainMenuStartupSmokeRunner.gd")
if (-not $Visible) {
    $godotArgs = @("--headless") + $godotArgs
}
$godotOutput = & $GodotExe @godotArgs 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
Remove-Item Env:\VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT,Env:\VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE,Env:\VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET -ErrorAction SilentlyContinue
if ($TestSeed -ne "") {
    Remove-Item Env:\VOXEL_TEST_SEED -ErrorAction SilentlyContinue
}
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing main-menu startup readiness smoke report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$expectedRunnerId = if ($RuntimeReset) { "main_menu_runtime_reset_smoke" } else { "main_menu_startup_smoke" }
if ([string]$report.runnerId -ne $expectedRunnerId -or [string]$report.evidenceLevel -ne "scene-load-smoke") {
    Write-Error "Main-menu startup readiness smoke report identity mismatch"
    exit 1
}
if ($RuntimeReset) {
    $runtimeResetReport = $report.details.runtimeReset
    $collision = $runtimeResetReport.readinessDomains.terrain_collision.metrics.voxelCollision
    $reset = $runtimeResetReport.readinessDomains.terrain_authority.metrics.reset
    if (($true -ne $runtimeResetReport.runtimeInstancePreserved) -or
        ($true -ne $runtimeResetReport.terrainInstancePreserved) -or
        ([string]$reset.resetMode -ne "in_place_generator_reload") -or
        ([int]$collision.publishedChunkCount -ne [int]$collision.requiredChunkCount)) {
        Write-Error "Runtime New Game terrain reset readiness contract mismatch"
        exit 1
    }
}
$acceptedEngineExit = $exitCode -eq 0
$trackedShutdownIssue = $null
$knownShutdownSignature = (($godotOutput | Out-String) -match "NavRegion3D.+leaked at exit") -and
    (($godotOutput | Out-String) -match "NavMap3D.+leaked at exit")
if ((-not $acceptedEngineExit) -and $RuntimeReset -and $Visible -and ($true -eq $report.passed) -and $knownShutdownSignature) {
    $acceptedEngineExit = $true
    $trackedShutdownIssue = "VOX-66"
    Write-Warning "Forward+ startup/reset assertions passed; Godot returned $exitCode during the separately tracked VOX-66 terrain/navigation shutdown lifecycle defect."
}
[pscustomobject]@{
    runnerId = $report.runnerId
    passed = $report.passed
    elapsedMs = $report.details.elapsedMs
    maxStepMs = $report.details.startupMaxStep.stepMs
    maxStepDomain = $report.details.startupMaxStep.domain
    maxStepMessage = $report.details.startupMaxStep.message
    readinessDomains = @($report.details.startupReadinessDomains.psobject.Properties.Name).Count
    registeredNpcCount = @($report.details.npcPhysics).Count
    failureCount = @($report.errors).Count
    runtimeResetElapsedMs = if ($RuntimeReset) { $report.details.runtimeReset.elapsedMs } else { $null }
    runtimeTerrainPreserved = if ($RuntimeReset) { $report.details.runtimeReset.terrainInstancePreserved } else { $null }
    engineExitCode = $exitCode
    trackedShutdownIssue = $trackedShutdownIssue
    reportPath = $ReportPath
} | ConvertTo-Json
if ((-not $acceptedEngineExit) -or ($true -ne $report.passed)) {
    exit 1
}
exit 0
