param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$SavePathOverride = "",
    [int]$TimeoutSeconds = 360,
    [int]$StaleProgressSeconds = 60
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcTutorialSaveContinueRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\tutorial-save-continue-playtest.json"
}
if ($SavePathOverride -eq "") {
    $SavePathOverride = Join-Path $projectPath "artifacts\npc\saves\tutorial-save-continue-playtest.json"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$SavePathOverride = [System.IO.Path]::GetFullPath($SavePathOverride)
$reportDir = [System.IO.Path]::GetDirectoryName($ReportPath)
$saveDirectory = [System.IO.Path]::GetDirectoryName($SavePathOverride)
$saveBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SavePathOverride)
$stageOneReport = Join-Path $reportDir "tutorial-save-continue-stage-new-game.json"
$stageTwoReport = Join-Path $reportDir "tutorial-save-continue-stage-continue.json"
$stageOneProgress = Join-Path $projectPath "artifacts\npc\progress\tutorial-save-continue-stage-new-game.txt"
$stageTwoProgress = Join-Path $projectPath "artifacts\npc\progress\tutorial-save-continue-stage-continue.txt"
$stageOneShots = Join-Path $projectPath "artifacts\npc\screenshots\tutorial-save-continue-stage-new-game"
$stageTwoShots = Join-Path $projectPath "artifacts\npc\screenshots\tutorial-save-continue-stage-continue"
$logDir = Join-Path $projectPath "artifacts\npc\logs"

New-Item -ItemType Directory -Force -Path $reportDir,$saveDirectory,([System.IO.Path]::GetDirectoryName($stageOneProgress)),$stageOneShots,$stageTwoShots,$logDir | Out-Null
Remove-Item -LiteralPath $ReportPath,$stageOneReport,$stageTwoReport,$stageOneProgress,$stageTwoProgress,$SavePathOverride -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $saveDirectory -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.StartsWith("${saveBaseName}_slot_", [System.StringComparison]::OrdinalIgnoreCase) -or $_.Name -eq "${saveBaseName}_active_seed.txt" } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $stageOneShots,$stageTwoShots -Filter "*.png" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$guardJson = & $guardScript -RunnerPath $runnerPath -ReportPath $ReportPath -TestId "npc_tutorial_save_continue_playtest" -PassThruJson
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$guard = $guardJson | ConvertFrom-Json

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Read-StageLogErrors([string]$OutLog, [string]$ErrLog) {
    $pattern = 'SCRIPT ERROR|Parse Error|previously freed instance|Invalid get index|Invalid call|Attempt to call|ERROR:'
    $ignoredShutdownPattern = 'ObjectDB instances leaked at exit|resources still in use at exit|WASAPI: GetBufferSize error'
    $matches = @()
    foreach ($path in @($OutLog, $ErrLog)) {
        if (Test-Path -LiteralPath $path) {
            $matches += @(Select-String -LiteralPath $path -Pattern $pattern | ForEach-Object {
                if ($_.Line -notmatch $ignoredShutdownPattern) {
                    [pscustomobject]@{ file = $path; line = $_.LineNumber; text = $_.Line.Trim() }
                }
            })
        }
    }
    return $matches
}

function Invoke-Stage([string]$Stage, [string]$StageReport, [string]$ProgressPath, [string]$ScreenshotDir) {
    $stageSlug = $Stage -replace '[^A-Za-z0-9_-]', '-'
    $outLog = Join-Path $logDir "tutorial-save-continue-$stageSlug.out.log"
    $errLog = Join-Path $logDir "tutorial-save-continue-$stageSlug.err.log"
    Remove-Item -LiteralPath $StageReport,$ProgressPath,$outLog,$errLog -ErrorAction SilentlyContinue

    Remove-Item Env:\VOXEL_PLAYTEST,Env:\VOXEL_TEST_SEED,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_REAL_BOOT -ErrorAction SilentlyContinue
    $env:VOXEL_SAVE_PATH_OVERRIDE = $SavePathOverride
    $env:VOXEL_TUTORIAL_SAVE_CONTINUE_REAL_BOOT = "1"
    $env:VOXEL_TUTORIAL_SAVE_CONTINUE_STAGE = $Stage
    $env:VOXEL_ACTUAL_GAMEPLAY_MIRA_REPORT = $StageReport
    $env:VOXEL_ACTUAL_GAMEPLAY_MIRA_PROGRESS = $ProgressPath
    $env:VOXEL_ACTUAL_GAMEPLAY_MIRA_SCREENSHOT_DIR = $ScreenshotDir
    $env:VOXEL_ACTUAL_GAMEPLAY_MIRA_WATCHDOG_SECONDS = [string]$TimeoutSeconds
    $env:VOXEL_ACTUAL_GAMEPLAY_MIRA_RUN_TOKEN = [guid]::NewGuid().ToString("N")
    $env:VOXEL_GIT_BRANCH = (& git -C $projectPath branch --show-current).Trim()
    $env:VOXEL_GIT_COMMIT = (& git -C $projectPath rev-parse HEAD).Trim()

    $process = Start-Process -FilePath $GodotExe -ArgumentList @("--fixed-fps", "60", "--resolution", "1280x720", "--path", $projectPath) -WorkingDirectory $projectPath -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $started = Get-Date
    $lastProgressWriteUtc = [datetime]::MinValue
    $stopReason = "completed"
    $reportFinished = $false
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 500
        $now = Get-Date
        if ($reportFinished) {
            if (($now - $started).TotalSeconds -gt ($TimeoutSeconds + 90)) {
                $stopReason = "shutdown_timeout"
                Stop-ProcessTree $process
                break
            }
            continue
        }
        if (Test-Path -LiteralPath $ProgressPath) {
            $item = Get-Item -LiteralPath $ProgressPath
            if ($item.LastWriteTimeUtc -gt $lastProgressWriteUtc) {
                $lastProgressWriteUtc = $item.LastWriteTimeUtc
                $progress = (Get-Content -LiteralPath $ProgressPath -Raw -ErrorAction SilentlyContinue).Trim()
                Write-Host "$Stage progress: $($progress -replace [Environment]::NewLine, ' | ')"
            }
        }
        $errors = @(Read-StageLogErrors $outLog $errLog)
        if ($errors.Count -gt 0) {
            $stopReason = "script_error_detected"
            Stop-ProcessTree $process
            break
        }
        if (Test-Path -LiteralPath $StageReport) {
            $candidate = Get-Content -LiteralPath $StageReport -Raw | ConvertFrom-Json
            if ($candidate.finished -eq $true) {
                $stopReason = "report_finished"
                $reportFinished = $true
                continue
            }
        }
        if (($now - $started).TotalSeconds -gt $TimeoutSeconds) {
            $stopReason = "timeout"
            Stop-ProcessTree $process
            break
        }
        if ($lastProgressWriteUtc -ne [datetime]::MinValue -and ($now - $lastProgressWriteUtc.ToLocalTime()).TotalSeconds -gt $StaleProgressSeconds) {
            $stopReason = "stale_progress"
            Stop-ProcessTree $process
            break
        }
    }
    if (-not (Test-Path -LiteralPath $StageReport)) {
        throw "$Stage did not produce a report (stopReason=$stopReason)"
    }
    $report = Get-Content -LiteralPath $StageReport -Raw | ConvertFrom-Json
    $report | Add-Member -Force -NotePropertyName processStopReason -NotePropertyValue $stopReason
    $report | Add-Member -Force -NotePropertyName scriptErrorMatches -NotePropertyValue @(Read-StageLogErrors $outLog $errLog)
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $StageReport
    if ($stopReason -notin @("completed", "report_finished") -or $report.passed -ne $true) {
        throw "$Stage failed (stopReason=$stopReason)"
    }
    return $report
}

try {
    $stageOne = Invoke-Stage "save_post_ack" $stageOneReport $stageOneProgress $stageOneShots
    $stageTwo = Invoke-Stage "continue_observe" $stageTwoReport $stageTwoProgress $stageTwoShots
    $aggregate = [pscustomobject]@{
        schemaVersion = 1
        testId = "npc_tutorial_save_continue_playtest"
        finished = $true
        passed = $true
        failureCount = 0
        resultCount = 2
        evidenceLevel = "integration"
        scope = "Headed two-process Main Menu input flow: New Game, live player knock acknowledgement, isolated SaveSystem save, Main Menu Continue input, then real NPC physics observation. The save-path override isolates test data only; no gameplay-affecting flags, test seed, teleport, direct tutorial progression, or direct NPC movement were used."
        actualGameplayDerived = $true
        gameplayFlags = [pscustomobject]@{
            voxelPlaytest = $false
            voxelTestSeed = ""
            savePathOverride = $SavePathOverride
            savePathOverridePurpose = "isolated real SaveSystem fixture"
        }
        forbiddenCallSelfScan = $guard
        stageReports = [pscustomobject]@{
            newGameSave = $stageOneReport
            continueObserve = $stageTwoReport
        }
        screenshotDirs = @($stageOneShots, $stageTwoShots)
        results = @(
            [pscustomobject]@{ name = "live_new_game_post_ack_save"; passed = $stageOne.passed; details = $stageOne.postAckSave },
            [pscustomobject]@{ name = "live_continue_generic_home_restore"; passed = $stageTwo.passed; details = [pscustomobject]@{ restoredOrder = $stageTwo.continuedRestoredOrder; porchClearanceDelay = $stageTwo.continuePorchClearanceDelayAfterObservation; strictHome = $stageTwo.miraReachedStrictHome } }
        )
    }
    $aggregate | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $ReportPath
    Get-Content -LiteralPath $ReportPath
} catch {
    $failure = [pscustomobject]@{
        schemaVersion = 1
        testId = "npc_tutorial_save_continue_playtest"
        finished = $true
        passed = $false
        failureCount = 1
        resultCount = 1
        evidenceLevel = "integration"
        actualGameplayDerived = $true
        forbiddenCallSelfScan = $guard
        results = @([pscustomobject]@{
            name = "tutorial_save_continue_wrapper"
            passed = $false
            details = $_.Exception.Message
        })
    }
    $failure | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ReportPath
    Write-Error "Tutorial save/Continue wrapper failed: $($_.Exception.Message)"
    exit 1
} finally {
    Remove-Item Env:\VOXEL_PLAYTEST,Env:\VOXEL_TEST_SEED,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_REAL_BOOT,Env:\VOXEL_TUTORIAL_SAVE_CONTINUE_REAL_BOOT,Env:\VOXEL_TUTORIAL_SAVE_CONTINUE_STAGE,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_REPORT,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_PROGRESS,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_SCREENSHOT_DIR,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_WATCHDOG_SECONDS,Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_RUN_TOKEN,Env:\VOXEL_GIT_BRANCH,Env:\VOXEL_GIT_COMMIT,Env:\VOXEL_SAVE_PATH_OVERRIDE -ErrorAction SilentlyContinue
}
