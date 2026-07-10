param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$RunName = "real-tutorial-playthrough-no-flags",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [string]$NoFlagsProofPath = "",
    [int]$TimeoutSeconds = 470,
    [int]$StaleProgressSeconds = 45,
    [switch]$Visible,
    [switch]$DayOne,
    [switch]$RealBoot
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\$RunName.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\$RunName.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\$RunName"
}
if ($NoFlagsProofPath -eq "") {
    $NoFlagsProofPath = Join-Path $projectPath "artifacts\npc\progress\$RunName.no-flags-proof.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
$NoFlagsProofPath = [System.IO.Path]::GetFullPath($NoFlagsProofPath)
$logDir = Join-Path $projectPath "artifacts\npc\logs"
$outLog = Join-Path $logDir "$RunName.out.log"
$errLog = Join-Path $logDir "$RunName.err.log"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($NoFlagsProofPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $NoFlagsProofPath -ErrorAction SilentlyContinue
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

$forbiddenGameplayEnvVars = @(
    "VOXEL_PLAYTEST",
    "VOXEL_TEST_SEED",
    "VOXEL_SAVE_PATH_OVERRIDE",
    "VOXEL_REAL_TUTORIAL_GOD_MODE",
    "VOXEL_GOD_MODE"
)
$runnerModeEnvVars = @(
    "VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY",
    "VOXEL_REAL_TUTORIAL_MORNING_OUTSIDE_ONLY",
    "VOXEL_REAL_TUTORIAL_FINAL_RESCUE",
    "VOXEL_REAL_TUTORIAL_REAL_BOOT"
)
foreach ($name in $forbiddenGameplayEnvVars + $runnerModeEnvVars) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}

$runToken = [guid]::NewGuid().ToString("N")
$branch = (& git -C $projectPath branch --show-current).Trim()
$commit = (& git -C $projectPath rev-parse HEAD).Trim()

$env:VOXEL_REAL_TUTORIAL_REPORT = $ReportPath
$env:VOXEL_REAL_TUTORIAL_PROGRESS = $ProgressPath
$env:VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED = if ($Visible) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_DAY_ONE = if ($DayOne) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_REAL_BOOT = if ($RealBoot) { "1" } else { "0" }
$env:VOXEL_REAL_TUTORIAL_RUN_TOKEN = $runToken
$env:VOXEL_REAL_TUTORIAL_WATCHDOG_SECONDS = [string]$TimeoutSeconds
$env:VOXEL_GIT_BRANCH = $branch
$env:VOXEL_GIT_COMMIT = $commit

function Get-EnvProof([string[]]$Names) {
    $result = [ordered]@{}
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        $result[$name] = [pscustomobject]@{
            present = -not [string]::IsNullOrEmpty($value)
            valueLength = if ($null -eq $value) { 0 } else { ([string]$value).Length }
        }
    }
    return [pscustomobject]$result
}

$forbiddenProof = Get-EnvProof $forbiddenGameplayEnvVars
$forbiddenPassed = $true
foreach ($name in $forbiddenGameplayEnvVars) {
    if ($forbiddenProof.$name.present) {
        $forbiddenPassed = $false
    }
}
$noFlagsProof = [pscustomobject]@{
    schemaVersion = 1
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    scope = "process_environment_before_godot_launch"
    passed = $forbiddenPassed
    forbiddenGameplayFlags = $forbiddenProof
    runnerOnlyEnvironment = [pscustomobject]@{
        VOXEL_REAL_TUTORIAL_DAY_ONE = $env:VOXEL_REAL_TUTORIAL_DAY_ONE
        VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED = $env:VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED
        VOXEL_REAL_TUTORIAL_REAL_BOOT = $env:VOXEL_REAL_TUTORIAL_REAL_BOOT
        VOXEL_REAL_TUTORIAL_REPORT = $ReportPath
        VOXEL_REAL_TUTORIAL_PROGRESS = $ProgressPath
        VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR = $ScreenshotDir
    }
    runToken = $runToken
    gitBranch = $branch
    gitCommit = $commit
}
$noFlagsProof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $NoFlagsProofPath
if (-not $forbiddenPassed) {
    Write-Error "No-flags wrapper found gameplay-affecting environment variables still set. Proof: $NoFlagsProofPath"
    exit 1
}

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
            seed = ""
            runToken = $runToken
            gitBranch = $branch
            gitCommit = $commit
            finished = $true
            passed = $false
            failureCount = 1
            resultCount = 1
            processExitCode = $ExitCode
            processStopReason = $StopReason
            noGameplayFlagsProof = $noFlagsProof
            forbiddenCallSelfScan = $staticScan
            scriptErrorScan = $scriptScan
            results = @([pscustomobject]@{
                name = "real_tutorial_playthrough_no_flags_process"
                passed = $false
                details = "missing Godot report; exitCode=$ExitCode stopReason=$StopReason"
            })
        }
        $fallback | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $ReportPath
        return
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    $report | Add-Member -Force -NotePropertyName noGameplayFlagsProof -NotePropertyValue $noFlagsProof
    $report | Add-Member -Force -NotePropertyName noGameplayFlagsProofPath -NotePropertyValue $NoFlagsProofPath
    $report | Add-Member -Force -NotePropertyName forbiddenCallSelfScan -NotePropertyValue $staticScan
    $report | Add-Member -Force -NotePropertyName scriptErrorScan -NotePropertyValue $scriptScan
    $report | Add-Member -Force -NotePropertyName processExitCode -NotePropertyValue $ExitCode
    $report | Add-Member -Force -NotePropertyName processStopReason -NotePropertyValue $StopReason
    $processFailed = ($ExitCode -ne 0) -or ($StopReason -notin @("completed", "report_finished"))
    if ($processFailed) {
        $failureCode = "real_tutorial_no_flags_process_$($StopReason -replace '[^A-Za-z0-9_]', '_')"
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
            name = "real_tutorial_playthrough_no_flags_process"
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
    $report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath
}

$godotArgs = @("--fixed-fps", "60", "--resolution", "1280x720", "--path", $projectPath)
if (-not $RealBoot) {
    $godotArgs += @("--scene", "res://scenes/testing/npc/NpcRealTutorialPlaythroughTest.tscn")
}
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

Write-Host "Started no-flags Godot PID $($process.Id); polling $ProgressPath"
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
    Write-Error "No-flags tutorial report token mismatch; expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($true -ne $report.noGameplayFlagsProof.passed) {
    Write-Error "No-flags proof failed: $NoFlagsProofPath"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ([string]$report.seed -ne "") {
    Write-Error "No-flags run should not set VOXEL_TEST_SEED, but report seed was '$($report.seed)'"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ([bool]$report.playtestGodMode) {
    Write-Error "No-flags run reported playtestGodMode=true"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$lastFailureCode = ""
if ($null -ne $report.lastFailure) {
    $lastFailureCode = [string]$report.lastFailure.code
}
$playthroughPassed = ([bool]$report.passed) -and ([int]$report.failureCount -eq 0)
$requiredScreenshots = @()
if ($Visible) {
    $hasVisualFlag = $null -ne $report.PSObject.Properties["nonHeadlessVisualRequired"]
    if ($hasVisualFlag -and $true -ne $report.nonHeadlessVisualRequired) {
        Write-Error "Visible no-flags tutorial run did not mark nonHeadlessVisualRequired=true"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    if ((-not $hasVisualFlag) -and [string]$report.processStopReason -eq "report_finished") {
        Write-Error "Visible no-flags tutorial run finished without nonHeadlessVisualRequired in the report"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    if ($DayOne -and $playthroughPassed) {
        $requiredScreenshots = @(
            "player_pov_day_one_wake.png",
            "player_pov_day_one_mira_briefing.png",
            "player_pov_day_one_niko_food.png",
            "player_pov_day_one_rowan_tools.png",
            "player_pov_day_one_ready.png"
        )
    }
    foreach ($fileName in $requiredScreenshots) {
        $path = Join-Path $ScreenshotDir $fileName
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Error "Missing visible no-flags tutorial proof screenshot: $path"
            Get-Content -LiteralPath $ReportPath
            exit 1
        }
        $size = (Get-Item -LiteralPath $path).Length
        if ($size -le 0) {
            Write-Error "Empty visible no-flags tutorial proof screenshot: $path"
            Get-Content -LiteralPath $ReportPath
            exit 1
        }
    }
}

$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
$evidenceLevel = if ($Visible -and $DayOne -and $playthroughPassed) { "acceptance_visual" } else { "integration" }
$runnerId = if ($DayOne) { "npc_real_tutorial_day_one_full_player_pov" } else { "npc_real_tutorial_playthrough_integration" }
$acceptanceClaims = if ($Visible -and $DayOne -and $playthroughPassed) {
    @("tutorial_day_one_mira_niko_rowan_full_player_pov_visual")
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
    dayOneTutorial = [bool]$report.dayOneTutorial
    playtestGodMode = [bool]$report.playtestGodMode
    noGameplayFlagsProof = [bool]$report.noGameplayFlagsProof.passed
    noGameplayFlagsProofPath = $NoFlagsProofPath
    realBoot = [bool]$RealBoot
    fullPlayerPov = [bool]$report.fullPlayerPov
    evidenceLevel = [string]$report.evidenceLevel
    reportPath = $ReportPath
    screenshotDir = $ScreenshotDir
} | ConvertTo-Json -Depth 4

$wrapperExitCode = [int]$exitCode
$reportFailureCount = [int]$report.failureCount
$scriptScanStatus = [string]$report.scriptErrorScan.status
$wrapperFailed = ($wrapperExitCode -ne 0) -or ($reportFailureCount -gt 0) -or ($scriptScanStatus -eq "failed")
Write-Host "No-flags real tutorial wrapper result: exitCode=$wrapperExitCode failureCount=$reportFailureCount scriptScan=$scriptScanStatus proof=$NoFlagsProofPath"
if ($wrapperFailed) {
    $global:LASTEXITCODE = 1
    exit 1
}
$global:LASTEXITCODE = 0
exit 0
