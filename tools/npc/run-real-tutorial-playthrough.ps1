param(
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$TimeoutSeconds = 470,
    [int]$StaleProgressSeconds = 45,
    [switch]$Visible,
    [switch]$MiraHomeOnly,
    [switch]$MorningOutsideOnly,
    [switch]$DayOne,
    [switch]$FinalRescue,
    [switch]$GodMode
)

$ErrorActionPreference = "Stop"
if ($MiraHomeOnly -and $MorningOutsideOnly) {
    Write-Error "Use either -MiraHomeOnly or -MorningOutsideOnly, not both."
    exit 1
}
if ($DayOne -and ($MiraHomeOnly -or $MorningOutsideOnly)) {
    Write-Error "Use -DayOne by itself; it cannot be combined with -MiraHomeOnly or -MorningOutsideOnly."
    exit 1
}
if ($FinalRescue -and ($MiraHomeOnly -or $MorningOutsideOnly -or $DayOne)) {
    Write-Error "Use -FinalRescue by itself; it cannot be combined with -MiraHomeOnly, -MorningOutsideOnly, or -DayOne."
    exit 1
}

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\real-tutorial-playthrough.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\real-tutorial-playthrough.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\real-tutorial-playthrough"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
$logDir = Join-Path $projectPath "artifacts\npc\logs"
$outLog = Join-Path $logDir "real-tutorial-playthrough.out.log"
$errLog = Join-Path $logDir "real-tutorial-playthrough.err.log"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ScreenshotDir -Filter "*.png" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
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
$focusedVisualAcceptance = $Visible -and ($MiraHomeOnly -or $MorningOutsideOnly -or $FinalRescue)
$dayOneVisualAcceptance = $Visible -and $DayOne
$fullPlayerPovVisible = $Visible -and (-not $MiraHomeOnly) -and (-not $MorningOutsideOnly)
$godModeEnabled = $GodMode -or $FinalRescue

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_REAL_TUTORIAL_REPORT = $ReportPath
$env:VOXEL_REAL_TUTORIAL_PROGRESS = $ProgressPath
$env:VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED = if ($Visible) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY = if ($MiraHomeOnly) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_MORNING_OUTSIDE_ONLY = if ($MorningOutsideOnly) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_DAY_ONE = if ($DayOne) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_FINAL_RESCUE = if ($FinalRescue) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_GOD_MODE = if ($godModeEnabled) { "1" } else { "0" }
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
    $ignoredShutdownPattern = 'ObjectDB instances leaked at exit|resources still in use at exit'
    $matches = @()
    foreach ($path in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $path) {
            $matches += @(Select-String -LiteralPath $path -Pattern $pattern | ForEach-Object {
                if ($_.Line -match $ignoredShutdownPattern) {
                    return
                }
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
    $logMatches = @(Read-LogMatches)
    $scriptScan = [pscustomobject]@{
        status = if ($logMatches.Count -gt 0) { "failed" } else { "passed" }
        stopReason = $StopReason
        matchCount = $logMatches.Count
        matches = $logMatches
        stdout = $outLog
        stderr = $errLog
    }
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        $fallback = [pscustomobject]@{
            schemaVersion = 1
            testId = "npc_tutorial_real_knock_repair_sleep_morning_foragers"
            seed = $Seed
            runToken = $runToken
            gitBranch = $branch
            gitCommit = $commit
            finished = $true
            passed = $false
            failureCount = 1
            resultCount = 1
            forbiddenCallSelfScan = $staticScan
            scriptErrorScan = $scriptScan
            results = @([pscustomobject]@{
                name = "real_tutorial_playthrough_process"
                passed = $false
                details = "missing Godot report; exitCode=$ExitCode stopReason=$StopReason"
            })
        }
        $fallback | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ReportPath
        return
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $report | Add-Member -Force -NotePropertyName forbiddenCallSelfScan -NotePropertyValue $staticScan
    $report | Add-Member -Force -NotePropertyName scriptErrorScan -NotePropertyValue $scriptScan
    $report | Add-Member -Force -NotePropertyName processExitCode -NotePropertyValue $ExitCode
    $report | Add-Member -Force -NotePropertyName processStopReason -NotePropertyValue $StopReason
    $processFailed = ($ExitCode -ne 0) -or ($StopReason -notin @("completed", "report_finished"))
    if ($processFailed) {
        $failureCode = "real_tutorial_process_$($StopReason -replace '[^A-Za-z0-9_]', '_')"
        $failureDetails = "Godot process did not finish cleanly; exitCode=$ExitCode stopReason=$StopReason"
        $existingFailures = @()
        if ($null -ne $report.PSObject.Properties["failureReasons"] -and $null -ne $report.failureReasons) {
            $existingFailures += @($report.failureReasons)
        }
        $existingFailures += [pscustomobject]@{
            code = $failureCode
            details = $failureDetails
            time = $null
        }
        $existingResults = @()
        if ($null -ne $report.PSObject.Properties["results"] -and $null -ne $report.results) {
            $existingResults += @($report.results)
        }
        $existingResults += [pscustomobject]@{
            name = "real_tutorial_playthrough_process"
            passed = $false
            details = $failureDetails
        }
        $report | Add-Member -Force -NotePropertyName passed -NotePropertyValue $false
        $report | Add-Member -Force -NotePropertyName failureCount -NotePropertyValue $existingFailures.Count
        $report | Add-Member -Force -NotePropertyName resultCount -NotePropertyValue $existingResults.Count
        $report | Add-Member -Force -NotePropertyName results -NotePropertyValue $existingResults
        $report | Add-Member -Force -NotePropertyName failureReasons -NotePropertyValue $existingFailures
        $report | Add-Member -Force -NotePropertyName lastFailure -NotePropertyValue $existingFailures[$existingFailures.Count - 1]
        $report | Add-Member -Force -NotePropertyName processFailure -NotePropertyValue $true
    }
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $ReportPath
}

$godotArgs = @("--fixed-fps", "60", "--resolution", "1280x720", "--path", $projectPath, "--scene", "res://scenes/testing/npc/NpcRealTutorialPlaythroughTest.tscn")
if (-not $Visible) {
    $godotArgs = @("--headless") + $godotArgs
}
$argumentLine = ($godotArgs | ForEach-Object { Quote-Arg $_ }) -join " "

$startInfo = @{
    FilePath = $GodotExe
    ArgumentList = $argumentLine
    WorkingDirectory = $projectPath
    PassThru = $true
    RedirectStandardOutput = $outLog
    RedirectStandardError = $errLog
}
if (-not $Visible) {
    $startInfo.WindowStyle = "Hidden"
}

$process = Start-Process @startInfo
$started = Get-Date
$lastProgressWriteUtc = [datetime]::MinValue
$lastProgressText = ""
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
            $rawProgress = Get-Content -LiteralPath $ProgressPath -Raw -ErrorAction SilentlyContinue
            if ($null -eq $rawProgress) {
                $lastProgressText = ""
            } else {
                $lastProgressText = ([string]$rawProgress).Trim()
            }
            Write-Host "progress: $($lastProgressText -replace [Environment]::NewLine, ' | ')"
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
Set-ReportDiagnostics -ExitCode $exitCode -StopReason $stopReason

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "Real tutorial report token mismatch; expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$lastFailureCode = ""
if ($null -ne $report.lastFailure) {
    $lastFailureCode = [string]$report.lastFailure.code
}
$requiredScreenshots = @()
if ($Visible) {
    if ($true -ne $report.nonHeadlessVisualRequired) {
        Write-Error "Visible tutorial run did not mark nonHeadlessVisualRequired=true"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    if ($FinalRescue) {
        $requiredScreenshots = @(
            "player_pov_final_rescue_mira_briefing.png",
            "player_pov_final_rescue_sera_escort.png",
            "player_pov_final_rescue_gate_open.png",
            "player_pov_final_rescue_site_arrival.png",
            "player_pov_final_rescue_sera_at_site.png",
            "player_pov_final_rescue_sera_attack.png",
            "player_pov_final_rescue_hostiles_target_npc.png",
            "player_pov_final_rescue_combat.png",
            "player_pov_final_rescue_combat_complete.png",
            "player_pov_final_rescue_niko_returning.png",
            "player_pov_final_rescue_complete.png",
            "final_rescue_niko_home_normal.png",
            "final_rescue_sera_guard_normal.png"
        )
    } elseif ($DayOne) {
        $requiredScreenshots = @(
            "player_pov_day_one_wake.png",
            "player_pov_day_one_mira_briefing.png",
            "player_pov_day_one_niko_food.png",
            "player_pov_day_one_rowan_tools.png",
            "player_pov_day_one_ready.png"
        )
    } elseif ($MorningOutsideOnly) {
        $requiredScreenshots = @(
            "morning_outside_group.png",
            "morning_outside_rowan.png",
            "morning_outside_mira.png",
            "morning_outside_niko.png"
        )
    } elseif ($MiraHomeOnly) {
        $requiredScreenshots = @(
            "mira_go_home_start.png",
            "mira_route_departure.png",
            "mira_route_midpoint.png",
            "mira_at_home_door.png",
            "mira_home_door_open.png",
            "mira_inside_home_closed_door.png",
            "non_guard_home_rowan.png",
            "non_guard_home_niko.png"
        )
    }
    foreach ($fileName in $requiredScreenshots) {
        $path = Join-Path $ScreenshotDir $fileName
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Error "Missing visible tutorial proof screenshot: $path"
            Get-Content -LiteralPath $ReportPath
            exit 1
        }
        $size = (Get-Item -LiteralPath $path).Length
        if ($size -le 0) {
            Write-Error "Empty visible tutorial proof screenshot: $path"
            Get-Content -LiteralPath $ReportPath
            exit 1
        }
    }
}

$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
$evidenceLevel = if ($focusedVisualAcceptance -or $dayOneVisualAcceptance) { "acceptance_visual" } else { "integration" }
$runnerId = if ($FinalRescue) {
    "npc_real_tutorial_final_rescue"
} elseif ($MorningOutsideOnly) {
    "npc_real_tutorial_morning_outside"
} elseif ($MiraHomeOnly) {
    "npc_real_tutorial_playthrough"
} elseif ($DayOne) {
    "npc_real_tutorial_day_one_full_player_pov"
} elseif ($fullPlayerPovVisible) {
    "npc_real_tutorial_full_player_pov"
} else {
    "npc_real_tutorial_playthrough_integration"
}
$acceptanceClaims = if ($focusedVisualAcceptance -or $dayOneVisualAcceptance) {
    if ($FinalRescue) {
        @("tutorial_final_rescue_combat_niko_home_sera_guard_visual")
    } elseif ($MorningOutsideOnly) {
        @("tutorial_following_morning_rowan_mira_niko_outside_visual")
    } elseif ($DayOne) {
        @("tutorial_day_one_mira_niko_rowan_full_player_pov_visual")
    } else {
        @(
            "tutorial_mira_enters_home_and_closes_door",
            "tutorial_other_non_guard_npcs_visually_home_after_mira"
        )
    }
} else { @() }
$evidenceArgs = @(
    "-ReportPath", $ReportPath,
    "-RunnerId", $runnerId,
    "-EvidenceLevel", $evidenceLevel,
    "-RegistryPath", (Join-Path $projectPath "tools\test-runner-registry.json")
)
if ($acceptanceClaims.Count -gt 0) {
    $evidenceArgs += @("-AcceptanceClaims", ($acceptanceClaims -join ";"))
}
if ($Visible) {
    $evidenceArgs += @("-RequireForbiddenCallSelfScan")
}
if ($requiredScreenshots.Count -gt 0) {
    $evidenceArgs += @("-RequiredScreenshots", ($requiredScreenshots -join ";"))
    $evidenceArgs += @("-ScreenshotDir", $ScreenshotDir, "-RequireVisualProof")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evidenceScript @evidenceArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $ReportPath
    exit $LASTEXITCODE
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json

[pscustomobject]@{
    schemaVersion = [int]$report.schemaVersion
    testId = [string]$report.testId
    seed = [string]$report.seed
    finished = [bool]$report.finished
    passed = [bool]$report.passed
    failureCount = [int]$report.failureCount
    resultCount = [int]$report.resultCount
    processExitCode = [int]$report.processExitCode
    processStopReason = [string]$report.processStopReason
    lastFailureCode = $lastFailureCode
    miraHomeOnly = [bool]$report.miraHomeOnly
    morningOutsideOnly = [bool]$report.morningOutsideOnly
    finalRescueTutorial = [bool]$report.finalRescueTutorial
    playtestGodMode = [bool]$report.playtestGodMode
    playtestDamagePolicy = $report.playtestDamagePolicy
    fullPlayerPov = [bool]$report.fullPlayerPov
    evidenceLevel = [string]$report.evidenceLevel
    reportPath = $ReportPath
} | ConvertTo-Json -Depth 4
$wrapperExitCode = [int]$exitCode
$reportFailureCount = [int]$report.failureCount
$scriptScanStatus = [string]$report.scriptErrorScan.status
$wrapperFailed = ($wrapperExitCode -ne 0) -or ($reportFailureCount -gt 0) -or ($scriptScanStatus -eq "failed")
Write-Host "Real tutorial wrapper result: exitCode=$wrapperExitCode failureCount=$reportFailureCount scriptScan=$scriptScanStatus"
if ($wrapperFailed) {
    $global:LASTEXITCODE = 1
    exit 1
}
$global:LASTEXITCODE = 0
exit 0
