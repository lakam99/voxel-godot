param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "",
    [int]$WatchdogSeconds = 520
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\ResourceLifecycleVisualPlaytestRunner.gd"
if ($ArtifactDir -eq "") {
    $ArtifactDir = Join-Path $projectPath "artifacts\npc\vox124-resource-lifecycle"
}
$ArtifactDir = [IO.Path]::GetFullPath($ArtifactDir)
$savePath = Join-Path $ArtifactDir "resource-lifecycle-save.json"
$activeSeedPath = Join-Path $ArtifactDir "resource-lifecycle-save_active_seed.txt"
$saveReport = Join-Path $ArtifactDir "save-and-harvest.json"
$continueReport = Join-Path $ArtifactDir "continue-verify.json"
$saveProgress = Join-Path $ArtifactDir "save-and-harvest-progress.txt"
$continueProgress = Join-Path $ArtifactDir "continue-verify-progress.txt"
$screenshotDir = Join-Path $ArtifactDir "screenshots"
$logDir = Join-Path $ArtifactDir "logs"
New-Item -ItemType Directory -Force -Path $ArtifactDir,$screenshotDir,$logDir | Out-Null
Remove-Item -LiteralPath $savePath,$activeSeedPath,$saveReport,$continueReport,$saveProgress,$continueProgress -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ArtifactDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "resource-lifecycle-save_slot_*" } | Remove-Item -Force
Get-ChildItem -LiteralPath $screenshotDir -File -Filter "*.png" -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $logDir -File -Filter "*.log" -ErrorAction SilentlyContinue | Remove-Item -Force

$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$guardJson = & $guardScript `
    -RunnerPath $runnerPath `
    -ReportPath $saveReport `
    -TestId "vox_124_tree_and_ground_forage_resource_lifecycle" `
    -AllowedShortcutPattern "resource_lifecycle_pre_act_pose_fixture" `
    -PassThruJson
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$staticScan = $guardJson | ConvertFrom-Json

Remove-Item Env:\VOXEL_PLAYTEST,Env:\VOXEL_TEST_SEED -ErrorAction SilentlyContinue
$env:VOXEL_SAVE_PATH_OVERRIDE = $savePath
$env:VOXEL_RESOURCE_LIFECYCLE_SCREENSHOT_DIR = $screenshotDir
$env:VOXEL_RESOURCE_LIFECYCLE_WATCHDOG_SECONDS = [string]$WatchdogSeconds

function Set-ReportDiagnostics([string]$ReportPath, [object]$Report, [object[]]$ScriptMatches, [int]$ExitCode) {
    $Report | Add-Member -Force -NotePropertyName forbiddenCallSelfScan -NotePropertyValue $staticScan
    $Report | Add-Member -Force -NotePropertyName scriptErrorScan -NotePropertyValue ([pscustomobject]@{
        status = if ($ScriptMatches.Count -eq 0) { "passed" } else { "failed" }
        matchCount = $ScriptMatches.Count
        matches = $ScriptMatches
    })
    $Report | Add-Member -Force -NotePropertyName processExitCode -NotePropertyValue $ExitCode
    $Report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath
}

function Invoke-ResourceLifecycleStage(
    [string]$Stage,
    [string]$ReportPath,
    [string]$ProgressPath,
    [string]$ExpectedTreeId = "",
    [string]$ExpectedForageId = "",
    [string]$ExpectedTreePosition = "",
    [string]$ExpectedForagePosition = ""
) {
    $outLog = Join-Path $logDir "$Stage.out.log"
    $errLog = Join-Path $logDir "$Stage.err.log"
    $env:VOXEL_RESOURCE_LIFECYCLE_STAGE = $Stage
    $env:VOXEL_RESOURCE_LIFECYCLE_REPORT = $ReportPath
    $env:VOXEL_RESOURCE_LIFECYCLE_PROGRESS = $ProgressPath
    $env:VOXEL_RESOURCE_LIFECYCLE_RUN_TOKEN = [guid]::NewGuid().ToString("N")
    if ($ExpectedTreeId -ne "") {
        $env:VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_ID = $ExpectedTreeId
        $env:VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_ID = $ExpectedForageId
        $env:VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_POSITION = $ExpectedTreePosition
        $env:VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_POSITION = $ExpectedForagePosition
    } else {
        Remove-Item Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_ID,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_ID,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_POSITION,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_POSITION -ErrorAction SilentlyContinue
    }
    $process = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList "--path",$projectPath,"--resolution","1280x720","--scene","res://scenes/testing/ResourceLifecycleVisualPlaytest.tscn" `
        -WorkingDirectory $projectPath `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = $process.ExitCode
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "Missing VOX-124 resource lifecycle stage report: $ReportPath"
    }
    $matches = @()
    $ignoredShutdownPattern = "ObjectDB instances leaked at exit|resources still in use at exit|WASAPI: GetBufferSize error"
    foreach ($path in @($outLog,$errLog)) {
        if (Test-Path -LiteralPath $path) {
            $matches += @(Select-String -LiteralPath $path -Pattern "SCRIPT ERROR|Parse Error|previously freed instance|Invalid get index|Invalid call|Attempt to call|ERROR:" | Where-Object {
                $_.Line -notmatch $ignoredShutdownPattern
            } | ForEach-Object {
                [pscustomobject]@{file=$path;line=$_.LineNumber;text=$_.Line.Trim()}
            })
        }
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    Set-ReportDiagnostics $ReportPath $report $matches $exitCode
    if ([string]$report.runnerId -ne "vox124_resource_lifecycle_visual" -or [string]$report.evidenceLevel -ne "acceptance_visual") {
        throw "VOX-124 resource lifecycle report identity mismatch"
    }
    $stagePassed = [bool]$report.passed
    $scriptMatchCount = @($matches).Count
    if ([int]$exitCode -ne 0 -or -not $stagePassed -or $scriptMatchCount -ne 0) {
        throw "VOX-124 resource lifecycle stage failed: $Stage (exitCode=$exitCode passed=$stagePassed scriptMatches=$scriptMatchCount)"
    }
    return $report
}

function ConvertTo-ResourcePositionText([object]$Value) {
    $items = @($Value)
    if ($items.Count -ge 3) {
        return "$($items[0]),$($items[1]),$($items[2])"
    }
    if ($null -ne $Value -and $Value.PSObject.Properties.Name -contains "x") {
        return "$($Value.x),$($Value.y),$($Value.z)"
    }
    throw "Resource lifecycle report position was not a three-component vector: $Value"
}

try {
    $save = Invoke-ResourceLifecycleStage "save_and_harvest" $saveReport $saveProgress
    $treeId = [string]$save.harvest.treePropId
    $forageId = [string]$save.harvest.groundForagePropId
    $treePosition = ConvertTo-ResourcePositionText $save.harvest.treePosition
    $foragePosition = ConvertTo-ResourcePositionText $save.harvest.groundForagePosition
    if ($treeId -eq "" -or $forageId -eq "" -or -not (Test-Path -LiteralPath $activeSeedPath)) {
        throw "Save/harvest stage did not persist both removed IDs or its isolated save"
    }
    $continued = Invoke-ResourceLifecycleStage "continue_verify" $continueReport $continueProgress $treeId $forageId $treePosition $foragePosition
    $requiredCaptures = @(
        "menu_before_save_and_harvest.png",
        "tree_before_stream_rebind.png",
        "ground_forage_before_stream_rebind.png",
        "ground_forage_before_live_harvest.png",
        "tree_before_live_harvest.png",
        "resources_retired_after_chunk_reload.png",
        "menu_before_continue_verify.png",
        "continue_resources_remain_retired.png"
    )
    $missing = @($requiredCaptures | Where-Object { -not (Test-Path -LiteralPath (Join-Path $screenshotDir $_)) })
    if ($missing.Count -gt 0) {
        throw "Missing VOX-124 resource lifecycle captures: $($missing -join ', ')"
    }
    [pscustomobject]@{
        runnerId = "vox124_resource_lifecycle_visual"
        passed = $true
        seed = $save.seed
        treePropId = $treeId
        groundForagePropId = $forageId
        saveReport = $saveReport
        continueReport = $continueReport
        screenshotDir = $screenshotDir
    } | ConvertTo-Json
} finally {
    Remove-Item Env:\VOXEL_SAVE_PATH_OVERRIDE,Env:\VOXEL_RESOURCE_LIFECYCLE_SCREENSHOT_DIR,Env:\VOXEL_RESOURCE_LIFECYCLE_WATCHDOG_SECONDS,Env:\VOXEL_RESOURCE_LIFECYCLE_STAGE,Env:\VOXEL_RESOURCE_LIFECYCLE_REPORT,Env:\VOXEL_RESOURCE_LIFECYCLE_PROGRESS,Env:\VOXEL_RESOURCE_LIFECYCLE_RUN_TOKEN,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_ID,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_ID,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_POSITION,Env:\VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_POSITION -ErrorAction SilentlyContinue
}
