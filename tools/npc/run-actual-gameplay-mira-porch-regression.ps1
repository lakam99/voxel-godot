param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [string]$SavePathOverride = "",
    [int]$TimeoutSeconds = 300,
    [int]$StaleProgressSeconds = 45,
    [switch]$Headless,
    [switch]$RealBoot
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcActualGameplayMiraPorchRegressionRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\actual-gameplay-mira-porch-regression.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\actual-gameplay-mira-porch-regression.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\actual-gameplay-mira-porch-regression"
}
if ($SavePathOverride -eq "") {
    $SavePathOverride = Join-Path $projectPath "artifacts\npc\saves\actual-gameplay-mira-porch-regression-saves.json"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
$SavePathOverride = [System.IO.Path]::GetFullPath($SavePathOverride)
$logDir = Join-Path $projectPath "artifacts\npc\logs"
$outLog = Join-Path $logDir "actual-gameplay-mira-porch-regression.out.log"
$errLog = Join-Path $logDir "actual-gameplay-mira-porch-regression.err.log"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($SavePathOverride)) | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $SavePathOverride -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ScreenshotDir -Filter "*.png" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outLog -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $errLog -ErrorAction SilentlyContinue

$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$guardJson = & $guardScript `
    -RunnerPath $runnerPath `
    -ReportPath $ReportPath `
    -TestId "npc_actual_gameplay_mira_porch_regression" `
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
if ($RealBoot) {
    Remove-Item Env:\VOXEL_SAVE_PATH_OVERRIDE -ErrorAction SilentlyContinue
    $env:VOXEL_ACTUAL_GAMEPLAY_MIRA_REAL_BOOT = "1"
} else {
    $env:VOXEL_SAVE_PATH_OVERRIDE = $SavePathOverride
    Remove-Item Env:\VOXEL_ACTUAL_GAMEPLAY_MIRA_REAL_BOOT -ErrorAction SilentlyContinue
}
$env:VOXEL_ACTUAL_GAMEPLAY_MIRA_REPORT = $ReportPath
$env:VOXEL_ACTUAL_GAMEPLAY_MIRA_PROGRESS = $ProgressPath
$env:VOXEL_ACTUAL_GAMEPLAY_MIRA_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_ACTUAL_GAMEPLAY_MIRA_RUN_TOKEN = $runToken
$env:VOXEL_ACTUAL_GAMEPLAY_MIRA_WATCHDOG_SECONDS = [string]$TimeoutSeconds
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
            testId = "npc_actual_gameplay_mira_porch_regression"
            runToken = $runToken
            gitBranch = $branch
            gitCommit = $commit
            finished = $true
            passed = $false
            failureCount = 1
            resultCount = 1
            forbiddenCallSelfScan = $staticScan
            scriptErrorScan = $scriptScan
            actualGameplayDerived = $true
            usesVoxelPlaytest = $false
            savePathOverride = $SavePathOverride
            results = @([pscustomobject]@{
                name = "actual_gameplay_mira_porch_process"
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
    $report | Add-Member -Force -NotePropertyName wrapperRemovedVoxelPlaytest -NotePropertyValue $true
    $report | Add-Member -Force -NotePropertyName wrapperRemovedVoxelTestSeed -NotePropertyValue $true
    $report | Add-Member -Force -NotePropertyName wrapperRealBoot -NotePropertyValue ([bool]$RealBoot)
    $report | Add-Member -Force -NotePropertyName wrapperRemovedSavePathOverride -NotePropertyValue ([bool]$RealBoot)
    if ($logMatches.Count -gt 0) {
        $existingFailures = @()
        if ($null -ne $report.PSObject.Properties["failureReasons"] -and $null -ne $report.failureReasons) {
            $existingFailures += @($report.failureReasons)
        }
        $existingFailures += [pscustomobject]@{
            code = "actual_gameplay_script_error_detected"
            details = "Godot log contained script/runtime errors"
            time = $null
        }
        $report | Add-Member -Force -NotePropertyName passed -NotePropertyValue $false
        $report | Add-Member -Force -NotePropertyName failureCount -NotePropertyValue $existingFailures.Count
        $report | Add-Member -Force -NotePropertyName failureReasons -NotePropertyValue $existingFailures
        $report | Add-Member -Force -NotePropertyName lastFailure -NotePropertyValue $existingFailures[$existingFailures.Count - 1]
    }
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $ReportPath
}

$godotArgs = @("--fixed-fps", "60", "--resolution", "1280x720", "--path", $projectPath)
if (-not $RealBoot) {
    $godotArgs += @("--scene", "res://scenes/testing/npc/NpcActualGameplayMiraPorchRegressionTest.tscn")
}
if ($Headless) {
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
if ($Headless) {
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
        $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
        if ($report.finished -eq $true) {
            $finishedByReport = $true
            $stopReason = "report_finished"
            Stop-ProcessTree $process
            break
        }
    }

    if (($now - $started).TotalSeconds -gt $TimeoutSeconds) {
        $stopReason = "timeout"
        Stop-ProcessTree $process
        break
    }

    if ($lastProgressWriteUtc -ne [datetime]::MinValue) {
        $lastWriteLocal = $lastProgressWriteUtc.ToLocalTime()
        if (($now - $lastWriteLocal).TotalSeconds -gt $StaleProgressSeconds) {
            $stopReason = "stale_progress"
            Stop-ProcessTree $process
            break
        }
    }
}

if ($process.HasExited) {
    $exitCode = $process.ExitCode
} else {
    $exitCode = 1
}
if ($finishedByReport -and $exitCode -ne 0 -and $stopReason -eq "report_finished") {
    $exitCode = 0
}
Set-ReportDiagnostics -ExitCode $exitCode -StopReason $stopReason

if (Test-Path -LiteralPath $ReportPath) {
    Get-Content -LiteralPath $ReportPath
}

if ($stopReason -notin @("completed", "report_finished")) {
    exit 1
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    exit 1
}
$finalReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($finalReport.passed -eq $true) {
    exit 0
}
exit 1
