param(
    [string]$Seed = "",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$TimeoutSeconds = 460,
    [int]$StaleProgressSeconds = 70
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcTownJobCycleVisualPlaytestRunner.gd"
if ($Seed -eq "") {
    $Seed = "town-cycle-$(Get-Date -Format yyyyMMddHHmmss)-$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
}
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\town-job-cycle-visual-playtest.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\town-job-cycle-visual-playtest.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\town-job-cycle-visual"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
$logDir = Join-Path $projectPath "artifacts\npc\logs"
$outLog = Join-Path $logDir "town-job-cycle-visual.out.log"
$errLog = Join-Path $logDir "town-job-cycle-visual.err.log"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $ScreenshotDir "*.png") -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outLog -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $errLog -ErrorAction SilentlyContinue

$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$guardAllowed = @(
    'player\.global_position\s*=.*town_job_cycle_fixture_camera_load'
)
$guardJson = & $guardScript `
    -RunnerPath $runnerPath `
    -ReportPath $ReportPath `
    -TestId "npc_generated_town_job_cycle_visual" `
    -AllowedShortcutPattern $guardAllowed `
    -PassThruJson
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$staticScan = $guardJson | ConvertFrom-Json

function Invoke-UnscriptedBehaviorScan([string]$Path) {
    $rules = @(
        [pscustomobject]@{ Id = "scripted_go_home_order"; Pattern = '\border_go_home\b'; Reason = "This generated-town acceptance must rely on schedule/autonomy, not explicit go-home orders." },
        [pscustomobject]@{ Id = "scripted_handle"; Pattern = '\bScriptedNpcHandle\b'; Reason = "Scenario command handles are not allowed in this unscripted town observation." },
        [pscustomobject]@{ Id = "direct_behavior_order"; Pattern = '\b(order_to|assign_task|force_goal|force_home|force_guard|set_scripted)\b'; Reason = "The test may not directly assign NPC behavior." },
        [pscustomobject]@{ Id = "direct_motion_goal_write"; Pattern = '\bactiveMotionGoal\s*='; Reason = "The test may not write live motion goals." },
        [pscustomobject]@{ Id = "fake_schedule_injection"; Pattern = '\binject_snapshot\s*\('; Reason = "The test must use the real clock and schedule service." },
        [pscustomobject]@{ Id = "manual_inside_home"; Pattern = 'set_meta\s*\(\s*["'']npc_inside_home["'']'; Reason = "The test must observe interior state, not set it." },
        [pscustomobject]@{ Id = "npc_roster_fixture"; Pattern = '\b(create_npc_body|register_npc|add_npc_visual|add_npc_collider|safe_place_npc|spawn_fixture_npcs)\b'; Reason = "Generated-town acceptance must use naturally spawned game NPCs." },
        [pscustomobject]@{ Id = "town_fixture_construction"; Pattern = '\b(build_building|record_town_home|place_door|place_structure_block|place_porch|build_fence|place_fence|ensure_extra_homes)\b'; Reason = "Generated-town acceptance must not construct homes, fences, gates, or doors." },
        [pscustomobject]@{ Id = "resource_fixture_construction"; Pattern = '\b(make_forage|make_tree|make_rock|seed_job_resources)\b'; Reason = "Generated-town acceptance must use naturally generated job resources." },
        [pscustomobject]@{ Id = "town_spawn_state_mutation"; Pattern = '\bspawned_town_keys\b'; Reason = "Generated-town acceptance must not suppress or replace built-in town NPC spawning." },
        [pscustomobject]@{ Id = "fixed_role_fixture"; Pattern = '\bROLE_FIXTURE\b'; Reason = "Generated-town acceptance must not inject a hand-authored role spread." }
    )
    $lines = @(Get-Content -LiteralPath $Path)
    $matches = @()
    for ($index = 0; $index -lt $lines.Count; $index += 1) {
        $line = $lines[$index]
        foreach ($rule in $rules) {
            if ($line -match $rule.Pattern) {
                $matches += [pscustomobject]@{
                    lineNumber = $index + 1
                    line = $line.Trim()
                    ruleId = $rule.Id
                    reason = $rule.Reason
                }
            }
        }
    }
    return [pscustomobject]@{
        status = if ($matches.Count -eq 0) { "passed" } else { "failed" }
        runnerPath = [System.IO.Path]::GetFullPath($Path)
        testId = "npc_generated_town_job_cycle_visual"
        ruleCount = $rules.Count
        matches = $matches
    }
}

$unscriptedScan = Invoke-UnscriptedBehaviorScan $runnerPath
if ($unscriptedScan.status -ne "passed") {
    $guardReport = [pscustomobject]@{
        schemaVersion = 1
        testId = "npc_generated_town_job_cycle_visual"
        seed = $Seed
        finished = $true
        passed = $false
        failureCount = 1
        resultCount = 1
        forbiddenCallSelfScan = $staticScan
        unscriptedBehaviorSelfScan = $unscriptedScan
        results = @([pscustomobject]@{
            name = "unscripted_behavior_source_scan"
            passed = $false
            details = "runner source contains behavior scripting shortcuts"
        })
    }
    $guardReport | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ReportPath
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$runToken = [guid]::NewGuid().ToString("N")
$branch = (& git -C $projectPath branch --show-current).Trim()
$commit = (& git -C $projectPath rev-parse HEAD).Trim()

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_NPC_TOWN_JOB_CYCLE_REPORT = $ReportPath
$env:VOXEL_NPC_TOWN_JOB_CYCLE_PROGRESS = $ProgressPath
$env:VOXEL_NPC_TOWN_JOB_CYCLE_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_NPC_TOWN_JOB_CYCLE_RUN_TOKEN = $runToken
$env:VOXEL_NPC_TOWN_JOB_CYCLE_WATCHDOG_SECONDS = [string]$TimeoutSeconds
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

function Read-ScriptLogMatches {
    $pattern = 'SCRIPT ERROR|Parse Error|Invalid get index|Invalid call|Attempt to call'
    $matches = @()
    foreach ($path in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $path) {
            $matches += @(Select-String -LiteralPath $path -Pattern $pattern | ForEach-Object {
                [pscustomobject]@{
                    file = $path
                    line = $_.LineNumber
                    text = $_.Line.Trim()
                }
            })
        }
    }
    return $matches
}

function Read-EngineLogMatches {
    $pattern = 'ObjectDB instances leaked|ERROR:'
    $matches = @()
    foreach ($path in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $path) {
            $matches += @(Select-String -LiteralPath $path -Pattern $pattern | ForEach-Object {
                [pscustomobject]@{
                    file = $path
                    line = $_.LineNumber
                    text = $_.Line.Trim()
                }
            })
        }
    }
    return $matches
}

function Set-ReportDiagnostics([int]$ExitCode, [string]$StopReason) {
    $logMatches = @(Read-ScriptLogMatches)
    $engineMatches = @(Read-EngineLogMatches)
    $scriptScan = [pscustomobject]@{
        status = if ($logMatches.Count -gt 0) { "failed" } else { "passed" }
        stopReason = $StopReason
        matchCount = $logMatches.Count
        matches = $logMatches
        stdout = $outLog
        stderr = $errLog
    }
    $engineScan = [pscustomobject]@{
        status = if ($engineMatches.Count -gt 0) { "failed" } else { "passed" }
        stopReason = $StopReason
        matchCount = $engineMatches.Count
        matches = $engineMatches
        stdout = $outLog
        stderr = $errLog
    }
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        $fallback = [pscustomobject]@{
            schemaVersion = 1
            testId = "npc_generated_town_job_cycle_visual"
            seed = $Seed
            runToken = $runToken
            gitBranch = $branch
            gitCommit = $commit
            finished = $true
            passed = $false
            failureCount = 1
            resultCount = 1
            forbiddenCallSelfScan = $staticScan
            unscriptedBehaviorSelfScan = $unscriptedScan
            scriptErrorScan = $scriptScan
            engineErrorScan = $engineScan
            results = @([pscustomobject]@{
                name = "town_job_cycle_visual_process"
                passed = $false
                details = "missing Godot report; exitCode=$ExitCode stopReason=$StopReason"
            })
        }
        $fallback | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ReportPath
        return
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $report | Add-Member -Force -NotePropertyName forbiddenCallSelfScan -NotePropertyValue $staticScan
    $report | Add-Member -Force -NotePropertyName unscriptedBehaviorSelfScan -NotePropertyValue $unscriptedScan
    $report | Add-Member -Force -NotePropertyName scriptErrorScan -NotePropertyValue $scriptScan
    $report | Add-Member -Force -NotePropertyName engineErrorScan -NotePropertyValue $engineScan
    $report | Add-Member -Force -NotePropertyName processExitCode -NotePropertyValue $ExitCode
    $report | Add-Member -Force -NotePropertyName processStopReason -NotePropertyValue $StopReason
    $report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath
}

$godotArgs = @(
    "--fixed-fps", "60",
    "--resolution", "1280x720",
    "--path", $projectPath,
    "--scene", "res://scenes/testing/npc/NpcTownJobCycleVisualPlaytest.tscn"
)
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
$lastProgressText = ""
$stopReason = "completed"
$finishedByReport = $false

Write-Host "Started headed Godot PID $($process.Id); polling $ProgressPath"
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    $now = Get-Date
    if (Test-Path -LiteralPath $ProgressPath) {
        $progressItem = Get-Item -LiteralPath $ProgressPath
        if ($progressItem.LastWriteTimeUtc -gt $lastProgressWriteUtc) {
            $lastProgressWriteUtc = $progressItem.LastWriteTimeUtc
            $rawProgress = Get-Content -LiteralPath $ProgressPath -Raw -ErrorAction SilentlyContinue
            if ($null -eq $rawProgress) {
                $lastProgressText = ""
            } else {
                $lastProgressText = ([string]$rawProgress).Trim()
            }
            Write-Host "progress: $($lastProgressText -replace [Environment]::NewLine, ' | ')"
        }
    }

    $logMatches = @(Read-ScriptLogMatches)
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
                Stop-ProcessTree $process
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
} elseif ($stopReason -ne "completed") {
    $exitCode = 1
}
Set-ReportDiagnostics -ExitCode $exitCode -StopReason $stopReason

if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh NPC town job-cycle visual report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "NPC town job-cycle visual report token mismatch; expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($true -ne $report.nonHeadlessRequired) {
    Write-Error "NPC town job-cycle visual report did not mark nonHeadlessRequired=true"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($report.unscriptedBehaviorSelfScan.status -ne "passed") {
    Write-Error "NPC town job-cycle visual runner failed unscripted behavior scan"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$fullRequiredScreenshots = @(
    "town_setup_fenced_gate.png",
    "day_jobs_overview.png",
    "day_forager_forage.png",
    "day_guard_guarding.png",
    "night_all_inside_homes.png",
    "morning_emerge_jobs.png"
)
$preconditionRequiredScreenshots = @(
    "town_setup_fenced_gate.png"
)
$dayFailureRequiredScreenshots = @(
    "town_setup_fenced_gate.png",
    "day_jobs_overview.png",
    "day_forager_forage.png",
    "day_guard_guarding.png"
)
$nightFailureRequiredScreenshots = @(
    "town_setup_fenced_gate.png",
    "day_jobs_overview.png",
    "day_forager_forage.png",
    "day_guard_guarding.png",
    "night_all_inside_homes.png"
)
$requiredScreenshots = if ($true -eq $report.preconditionBlocked) {
    $preconditionRequiredScreenshots
} elseif ($report.stoppedPhase -eq "day") {
    $dayFailureRequiredScreenshots
} elseif ($report.stoppedPhase -eq "night") {
    $nightFailureRequiredScreenshots
} else {
    $fullRequiredScreenshots
}
foreach ($fileName in $requiredScreenshots) {
    $path = Join-Path $ScreenshotDir $fileName
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "Missing visual proof screenshot: $path"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
}

$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
& $evidenceScript `
    -ReportPath $ReportPath `
    -RunnerId "npc_town_job_cycle_visual_playtest" `
    -EvidenceLevel "acceptance_visual" `
    -AcceptanceClaims @("generated_town_job_cycle_day_night_day_natural_observation") `
    -RequiredScreenshots $requiredScreenshots `
    -ScreenshotDir $ScreenshotDir `
    -RegistryPath (Join-Path $projectPath "tools\npc\npc-suite-registry.json") `
    -RequireForbiddenCallSelfScan `
    -RequireVisualProof | Out-Null
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $ReportPath
    exit $LASTEXITCODE
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
Get-Content -LiteralPath $ReportPath
if ($exitCode -ne 0 -or [int]$report.failureCount -gt 0 -or $report.scriptErrorScan.status -ne "passed") {
    exit 1
}

exit 0
