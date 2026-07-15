param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "",
    [int]$WatchdogSeconds = 420
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ArtifactDir -eq "") {
    $ArtifactDir = Join-Path $projectPath "artifacts\vegetation\vox123-canopy-release"
}
$ArtifactDir = [IO.Path]::GetFullPath($ArtifactDir)
$savePath = Join-Path $ArtifactDir "canopy-release-save.json"
$activeSeedPath = Join-Path $ArtifactDir "canopy-release-save_active_seed.txt"
$saveReport = Join-Path $ArtifactDir "save-and-harvest.json"
$continueReport = Join-Path $ArtifactDir "continue-verify.json"
$saveProgress = Join-Path $ArtifactDir "save-and-harvest-progress.txt"
$continueProgress = Join-Path $ArtifactDir "continue-verify-progress.txt"
$screenshotDir = Join-Path $ArtifactDir "screenshots"
New-Item -ItemType Directory -Force -Path $ArtifactDir,$screenshotDir | Out-Null
Remove-Item -LiteralPath $savePath,$activeSeedPath,$saveReport,$continueReport,$saveProgress,$continueProgress -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ArtifactDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "canopy-release-save_slot_*" } | Remove-Item -Force
Get-ChildItem -LiteralPath $screenshotDir -File -Filter "*.png" -ErrorAction SilentlyContinue | Remove-Item -Force

Remove-Item Env:\VOXEL_PLAYTEST,Env:\VOXEL_TEST_SEED -ErrorAction SilentlyContinue
$env:VOXEL_SAVE_PATH_OVERRIDE = $savePath
$env:VOXEL_CANOPY_RELEASE_SCREENSHOT_DIR = $screenshotDir
$env:VOXEL_CANOPY_RELEASE_WATCHDOG_SECONDS = [string]$WatchdogSeconds

function Invoke-CanopyStage([string]$Stage, [string]$ReportPath, [string]$ProgressPath, [string]$ExpectedPropId = "") {
    $env:VOXEL_CANOPY_RELEASE_STAGE = $Stage
    $env:VOXEL_CANOPY_RELEASE_REPORT = $ReportPath
    $env:VOXEL_CANOPY_RELEASE_PROGRESS = $ProgressPath
    $env:VOXEL_CANOPY_RELEASE_RUN_TOKEN = [guid]::NewGuid().ToString("N")
    if ($ExpectedPropId -ne "") {
        $env:VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID = $ExpectedPropId
    } else {
        Remove-Item Env:\VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID -ErrorAction SilentlyContinue
    }
    & $GodotExe --path $projectPath --resolution 1280x720 --scene "res://scenes/testing/CanopyReleasePlaytest.tscn"
    $exitCode = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "Missing canopy release stage report: $ReportPath"
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ([string]$report.runnerId -ne "canopy_release_playtest" -or [string]$report.evidenceLevel -ne "acceptance_visual") {
        throw "Canopy release report identity mismatch"
    }
    if ($exitCode -ne 0 -or $true -ne $report.passed) {
        throw "Canopy release stage failed: $Stage"
    }
    return $report
}

try {
    $save = Invoke-CanopyStage "save_and_harvest" $saveReport $saveProgress
    $removedPropId = [string]$save.harvest.propId
    if ($removedPropId -eq "" -or -not (Test-Path -LiteralPath $activeSeedPath)) {
        throw "Save/harvest stage did not persist its isolated save or removed prop ID"
    }
    $continued = Invoke-CanopyStage "continue_verify" $continueReport $continueProgress $removedPropId
    $requiredCaptures = @(
        "menu_before_save_and_harvest.png",
        "generated_tree_before_harvest.png",
        "tree_falling_after_live_input.png",
        "forest_after_chunk_reload.png",
        "menu_before_continue_verify.png",
        "continue_dense_forest_removed_tree_persisted.png"
    )
    $missing = @($requiredCaptures | Where-Object { -not (Test-Path -LiteralPath (Join-Path $screenshotDir $_)) })
    if ($missing.Count -gt 0) {
        throw "Missing canopy release captures: $($missing -join ', ')"
    }
    [pscustomobject]@{
        runnerId = "canopy_release_playtest"
        passed = $true
        seed = $save.seed
        removedPropId = $removedPropId
        saveResultCount = $save.resultCount
        continueResultCount = $continued.resultCount
        saveReport = $saveReport
        continueReport = $continueReport
        screenshotDir = $screenshotDir
    } | ConvertTo-Json
} finally {
    Remove-Item Env:\VOXEL_SAVE_PATH_OVERRIDE,Env:\VOXEL_CANOPY_RELEASE_SCREENSHOT_DIR,Env:\VOXEL_CANOPY_RELEASE_WATCHDOG_SECONDS,Env:\VOXEL_CANOPY_RELEASE_STAGE,Env:\VOXEL_CANOPY_RELEASE_REPORT,Env:\VOXEL_CANOPY_RELEASE_PROGRESS,Env:\VOXEL_CANOPY_RELEASE_RUN_TOKEN,Env:\VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID -ErrorAction SilentlyContinue
}
