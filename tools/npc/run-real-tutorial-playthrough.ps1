param(
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [int]$TimeoutSeconds = 470,
    [int]$StaleProgressSeconds = 45,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\real-tutorial-playthrough.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\real-tutorial-playthrough.txt"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$logDir = Join-Path $projectPath "artifacts\npc\logs"
$outLog = Join-Path $logDir "real-tutorial-playthrough.out.log"
$errLog = Join-Path $logDir "real-tutorial-playthrough.err.log"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outLog -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $errLog -ErrorAction SilentlyContinue

$forbiddenPattern = 'on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc'
$scanMatches = @()
if (Get-Command rg -ErrorAction SilentlyContinue) {
    $rgOutput = & rg -n $forbiddenPattern $runnerPath 2>&1
    $rgExit = $LASTEXITCODE
    if ($rgExit -eq 0) {
        $scanMatches = @($rgOutput)
    } elseif ($rgExit -gt 1) {
        Write-Error "Static guard failed to scan runner: $rgOutput"
        exit 1
    }
} else {
    $scanMatches = @(Select-String -Path $runnerPath -Pattern $forbiddenPattern -AllMatches | ForEach-Object { "$($_.LineNumber):$($_.Line)" })
}
if ($scanMatches.Count -gt 0) {
    $guardReport = [pscustomobject]@{
        schemaVersion = 1
        testId = "npc_tutorial_real_knock_repair_sleep_morning_foragers"
        seed = $Seed
        finished = $true
        passed = $false
        failureCount = 1
        resultCount = 1
        forbiddenCallSelfScan = [pscustomobject]@{
            status = "failed"
            pattern = $forbiddenPattern
            matches = $scanMatches
        }
        results = @([pscustomobject]@{
            name = "real_tutorial_runner_static_guard"
            passed = $false
            details = "runner source contains forbidden shortcut calls"
        })
    }
    $guardReport | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$runToken = [guid]::NewGuid().ToString("N")
$branch = (& git -C $projectPath branch --show-current).Trim()
$commit = (& git -C $projectPath rev-parse HEAD).Trim()
$staticScan = [pscustomobject]@{
    status = "passed"
    pattern = $forbiddenPattern
    matches = @()
    runnerPath = $runnerPath
}

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_REAL_TUTORIAL_REPORT = $ReportPath
$env:VOXEL_REAL_TUTORIAL_PROGRESS = $ProgressPath
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
    $pattern = 'SCRIPT ERROR|previously freed instance|Invalid get index|Invalid call|ObjectDB instances leaked|ERROR:'
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
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $ReportPath
}

$godotArgs = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/testing/npc/NpcRealTutorialPlaythroughTest.tscn")
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
