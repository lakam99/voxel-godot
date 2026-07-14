param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [string]$NoFlagsProofPath = "",
    [int]$TimeoutSeconds = 720,
    [int]$StaleProgressSeconds = 75,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

if (-not $Visible) {
    throw "Phase 7 live tutorial acceptance requires -Visible. Headless output cannot prove gameplay-visible behavior."
}

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\real-tutorial-playthrough-no-flags.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\real-tutorial-playthrough-no-flags.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\real-tutorial-playthrough-no-flags"
}
if ($NoFlagsProofPath -eq "") {
    $reportName = [System.IO.Path]::GetFileNameWithoutExtension($ReportPath)
    $NoFlagsProofPath = Join-Path ([System.IO.Path]::GetDirectoryName($ReportPath)) "$reportName-proof.json"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
$NoFlagsProofPath = [System.IO.Path]::GetFullPath($NoFlagsProofPath)
$logDir = Join-Path $projectPath "artifacts\npc\logs"
$outLog = Join-Path $logDir "real-tutorial-playthrough-no-flags.out.log"
$errLog = Join-Path $logDir "real-tutorial-playthrough-no-flags.err.log"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $NoFlagsProofPath -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ScreenshotDir -Filter "*.png" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outLog -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $errLog -ErrorAction SilentlyContinue

$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$guardJson = & $guardScript `
    -RunnerPath $runnerPath `
    -ReportPath $ReportPath `
    -TestId "npc_tutorial_real_knock_repair_sleep_morning_foragers" `
    -AllowedShortcutPattern "final_rescue_fixture_setup_allowance" `
    -PassThruJson
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$staticScan = $guardJson | ConvertFrom-Json

$runToken = [guid]::NewGuid().ToString("N")
$branch = (& git -C $projectPath branch --show-current).Trim()
$commit = (& git -C $projectPath rev-parse HEAD).Trim()

Remove-Item Env:\VOXEL_PLAYTEST -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_TEST_SEED -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_SAVE_PATH_OVERRIDE -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_REAL_TUTORIAL_GOD_MODE -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_REAL_TUTORIAL_MORNING_OUTSIDE_ONLY -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_REAL_TUTORIAL_DAY_ONE -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_REAL_TUTORIAL_FINAL_RESCUE -ErrorAction SilentlyContinue

$requiredUnset = @(
    "VOXEL_PLAYTEST",
    "VOXEL_TEST_SEED",
    "VOXEL_SAVE_PATH_OVERRIDE",
    "VOXEL_REAL_TUTORIAL_GOD_MODE"
)
$environmentProof = [ordered]@{}
foreach ($name in $requiredUnset) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    $environmentProof[$name] = [ordered]@{
        value = $value
        unset = [string]::IsNullOrWhiteSpace($value)
    }
}
if (@($environmentProof.Values | Where-Object { -not $_.unset }).Count -gt 0) {
    throw "No-flags preflight failed: a gameplay-affecting test environment variable remains set."
}

$env:VOXEL_REAL_TUTORIAL_REAL_BOOT = "1"
$env:VOXEL_REAL_TUTORIAL_PHASE7_LIVE_ACCEPTANCE = "1"
$env:VOXEL_REAL_TUTORIAL_REPORT = $ReportPath
$env:VOXEL_REAL_TUTORIAL_PROGRESS = $ProgressPath
$env:VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED = "1"
$env:VOXEL_REAL_TUTORIAL_RUN_TOKEN = $runToken
$env:VOXEL_REAL_TUTORIAL_WATCHDOG_SECONDS = [string]$TimeoutSeconds
$env:VOXEL_GIT_BRANCH = $branch
$env:VOXEL_GIT_COMMIT = $commit

function Quote-Arg([string]$Value) {
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) {
        return
    }
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Read-LogMatches {
    $pattern = 'SCRIPT ERROR|Parse Error|previously freed instance|Invalid get index|Invalid call|Attempt to call|ERROR:'
    $ignoredShutdownPattern = 'ObjectDB instances leaked at exit|resources still in use at exit|WASAPI: GetBufferSize error'
    $matches = @()
    foreach ($path in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $path) {
            $matches += @(Select-String -LiteralPath $path -Pattern $pattern | ForEach-Object {
                if ($_.Line -notmatch $ignoredShutdownPattern) {
                    [pscustomobject]@{
                        file = $path
                        line = $_.LineNumber
                        text = $_.Line.Trim()
                    }
                }
            })
        }
    }
    return $matches
}

function Write-NoFlagsProof([int]$ExitCode, [string]$StopReason, [bool]$ReportPresent, [string[]]$LaunchArguments) {
    $proof = [ordered]@{
        schemaVersion = 1
        testId = "npc_tutorial_real_knock_repair_sleep_morning_foragers"
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        projectPath = $projectPath
        launchPath = "project main scene MainMenu.tscn -> visible New Game button input"
        launchArguments = $LaunchArguments
        fixedFramePacingOverride = $false
        runnerPath = $runnerPath
        branch = $branch
        commit = $commit
        requiredUnsetBeforeLaunch = $environmentProof
        noGameplayAffectingFlags = $true
        realBoot = $true
        visible = $true
        saveIsolation = $false
        processExitCode = $ExitCode
        processStopReason = $StopReason
        reportPresent = $ReportPresent
        staticAcceptanceRunnerScan = $staticScan
    }
    $proof | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $NoFlagsProofPath
}

# Live acceptance must use the same uncapped frame pacing as a normal player boot.
# Fixed FPS conceals CPU/frame-budget starvation that is visible in the shipped game.
$godotArgs = @("--resolution", "1280x720", "--path", $projectPath)
$argumentLine = ($godotArgs | ForEach-Object { Quote-Arg $_ }) -join " "
$startInfo = @{
    FilePath = $GodotExe
    ArgumentList = $argumentLine
    WorkingDirectory = $projectPath
    PassThru = $true
    RedirectStandardOutput = $outLog
    RedirectStandardError = $errLog
}

$process = Start-Process @startInfo
$started = Get-Date
$lastProgressWriteUtc = [datetime]::MinValue
$stopReason = "completed"
$finishedByReport = $false

Write-Host "Started Godot PID $($process.Id); polling $ProgressPath"
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    $now = Get-Date
    if (Test-Path -LiteralPath $ProgressPath) {
        $progressItem = Get-Item -LiteralPath $ProgressPath
        if ($progressItem.LastWriteTimeUtc -gt $lastProgressWriteUtc) {
            $lastProgressWriteUtc = $progressItem.LastWriteTimeUtc
            $progress = (Get-Content -LiteralPath $ProgressPath -Raw -ErrorAction SilentlyContinue).Trim()
            Write-Host "progress: $($progress -replace [Environment]::NewLine, ' | ')"
        }
    }
    $logMatches = @(Read-LogMatches)
    if ($logMatches.Count -gt 0) {
        $stopReason = "script_error_detected"
        Stop-ProcessTree $process
        break
    }
    if (Test-Path -LiteralPath $ReportPath) {
        try {
            $liveReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
            if ($liveReport.runToken -eq $runToken -and [bool]$liveReport.finished) {
                $finishedByReport = $true
                $stopReason = "report_finished"
                if (-not $process.WaitForExit(5000)) {
                    Stop-ProcessTree $process
                }
                break
            }
        } catch {
        }
    }
    if (($now - $started).TotalSeconds -gt $TimeoutSeconds) {
        $stopReason = "timeout"
        Stop-ProcessTree $process
        break
    }
    if ($lastProgressWriteUtc -ne [datetime]::MinValue) {
        $staleSeconds = ($now.ToUniversalTime() - $lastProgressWriteUtc).TotalSeconds
        if ($staleSeconds -gt $StaleProgressSeconds) {
            $stopReason = "stale_progress"
            Stop-ProcessTree $process
            break
        }
    }
}

if (-not $process.HasExited) {
    $process.WaitForExit(5000)
}
$exitCode = if ($process.HasExited) { $process.ExitCode } else { 1 }
if ($finishedByReport) {
    $exitCode = 0
}
$reportPresent = Test-Path -LiteralPath $ReportPath
Write-NoFlagsProof -ExitCode $exitCode -StopReason $stopReason -ReportPresent $reportPresent -LaunchArguments $godotArgs

if (-not $reportPresent) {
    throw "Missing Godot report; exitCode=$exitCode stopReason=$stopReason"
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$scriptErrorScan = [pscustomobject]@{
    status = if ((Read-LogMatches).Count -gt 0) { "failed" } else { "passed" }
    stopReason = $stopReason
    stdout = $outLog
    stderr = $errLog
}
$report | Add-Member -Force -NotePropertyName forbiddenCallSelfScan -NotePropertyValue $staticScan
$report | Add-Member -Force -NotePropertyName scriptErrorScan -NotePropertyValue $scriptErrorScan
$report | Add-Member -Force -NotePropertyName processExitCode -NotePropertyValue $exitCode
$report | Add-Member -Force -NotePropertyName processStopReason -NotePropertyValue $stopReason
$report | Add-Member -Force -NotePropertyName wrapperNoFlagsProofPath -NotePropertyValue $NoFlagsProofPath
$report | Add-Member -Force -NotePropertyName wrapperNoGameplayAffectingFlags -NotePropertyValue $true
$report | Add-Member -Force -NotePropertyName wrapperRealBoot -NotePropertyValue $true
$report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath

$requiredScreenshots = @(
    "phase7_menu_before_new_game.png",
    "phase7_loading_gameplay_prerequisites.png",
    "player_pov_dialogue_acknowledged.png",
    "mira_go_home_start.png",
    "mira_route_departure.png",
    "mira_at_home_door.png",
    "mira_home_door_open.png",
    "mira_inside_home_closed_door.png",
    "player_pov_after_mira_home.png"
)
foreach ($fileName in $requiredScreenshots) {
    $path = Join-Path $ScreenshotDir $fileName
    if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -le 0) {
        throw "Missing visible Phase 7 proof screenshot: $path"
    }
}

$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evidenceScript `
    -ReportPath $ReportPath `
    -RunnerId "npc_real_tutorial_no_flags" `
    -EvidenceLevel "acceptance_visual" `
    -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") `
    -AcceptanceClaims "tutorial_no_flags_main_menu_new_game_full_playthrough" `
    -RequireForbiddenCallSelfScan `
    -RequireVisualProof `
    -RequiredScreenshots ($requiredScreenshots -join ";") `
    -ScreenshotDir $ScreenshotDir | Out-Null
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $ReportPath
    exit $LASTEXITCODE
}

$finalReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
[pscustomobject]@{
    schemaVersion = [int]$finalReport.schemaVersion
    testId = [string]$finalReport.testId
    finished = [bool]$finalReport.finished
    passed = [bool]$finalReport.passed
    failureCount = [int]$finalReport.failureCount
    processStopReason = [string]$finalReport.processStopReason
    reportPath = $ReportPath
    noFlagsProofPath = $NoFlagsProofPath
} | ConvertTo-Json -Depth 4

if ($exitCode -ne 0 -or -not [bool]$finalReport.passed -or [string]$finalReport.scriptErrorScan.status -eq "failed") {
    exit 1
}
exit 0
