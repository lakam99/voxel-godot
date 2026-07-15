param(
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 190
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runnerPath = Join-Path $projectPath "scripts\testing\npc\NpcGoHomeVisualPlaytestRunner.gd"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\go-home-visual-playtest.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\go-home-visual-playtest.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\go-home-visual"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $ScreenshotDir "*.png") -ErrorAction SilentlyContinue

$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$guardAllowed = @(
    'safe_place_npc.*visual_go_home_spawn',
    'player\.global_position\s*=\s*Vector3\(float\(center\.x - 10\)'
)
$guardJson = & $guardScript `
    -RunnerPath $runnerPath `
    -ReportPath $ReportPath `
    -TestId "npc_go_home_visual_door_traversal" `
    -AllowedShortcutPattern $guardAllowed `
    -PassThruJson
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$staticScan = $guardJson | ConvertFrom-Json

$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_NPC_GO_HOME_VISUAL_REPORT = $ReportPath
$env:VOXEL_NPC_GO_HOME_VISUAL_PROGRESS = $ProgressPath
$env:VOXEL_NPC_GO_HOME_VISUAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_NPC_GO_HOME_VISUAL_RUN_TOKEN = $runToken
$env:VOXEL_NPC_GO_HOME_VISUAL_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$args = @(
    "--fixed-fps", "60",
    "--resolution", "1280x720",
    "--path", $projectPath,
    "--scene", "res://scenes/testing/npc/NpcGoHomeVisualPlaytest.tscn"
)

function Quote-Arg([string]$Value) {
    return '"' + ($Value -replace '"', '\"') + '"'
}

$argumentLine = ($args | ForEach-Object { Quote-Arg $_ }) -join " "
$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $false
$process.StartInfo.Arguments = $argumentLine
[void]$process.Start()
$processId = $process.Id
$started = Get-Date
$lastProgressWriteUtc = [datetime]::MinValue
$lastProgressText = ""
$stopReason = "completed"

Write-Host "Started headed Godot PID $processId; polling $ProgressPath"
$completedFromReport = $false
while ($true) {
    Start-Sleep -Milliseconds 500
    $runningProcess = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $runningProcess) {
        break
    }
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

    if (Test-Path -LiteralPath $ReportPath) {
        try {
            $liveReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
            if (($liveReport.runToken -eq $runToken) -and ($true -eq $liveReport.finished)) {
                $completedFromReport = $true
                $stopReason = "report_finished"
                break
            }
        } catch {
            # The runner may be in the middle of writing the report; try again on
            # the next poll rather than treating a transient parse as failure.
        }
    }
    $outerTimeoutSeconds = [Math]::Max($WatchdogSeconds + 90, [int]($WatchdogSeconds * 2))
    if (($now - $started).TotalSeconds -gt $outerTimeoutSeconds) {
        $stopReason = "timeout"
        Write-Error "NPC go-home visual playtest outer timeout exceeded $outerTimeoutSeconds seconds"
        if (Test-Path -LiteralPath $ProgressPath) {
            Get-Content -LiteralPath $ProgressPath
        }
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

$stillRunning = Get-Process -Id $processId -ErrorAction SilentlyContinue
if ($null -ne $stillRunning) {
    Start-Sleep -Milliseconds 500
}
$exitCode = 1
try {
    $exitCode = $process.ExitCode
} catch {
    $exitCode = 1
}
if ($completedFromReport) {
    $exitCode = 0
} elseif ($stopReason -ne "completed") {
    $exitCode = 1
}

if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh NPC go-home visual report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "NPC go-home visual report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($true -ne $report.nonHeadlessRequired) {
    Write-Error "NPC go-home visual report did not mark nonHeadlessRequired=true"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$requiredScreenshots = @("spawn_behind_home.png", "at_home_door.png", "door_open.png", "inside_closed_door.png")
foreach ($fileName in $requiredScreenshots) {
    $path = Join-Path $ScreenshotDir $fileName
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "Missing visual proof screenshot: $path"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
}

$report | Add-Member -Force -NotePropertyName forbiddenCallSelfScan -NotePropertyValue $staticScan
$report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath

$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
& $evidenceScript `
    -ReportPath $ReportPath `
    -RunnerId "npc_go_home_visual_playtest" `
    -EvidenceLevel "acceptance_visual" `
    -AcceptanceClaims @("npc_go_home_opens_crosses_closes_home_door") `
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
$scriptErrorStatus = "passed"
if ($report.PSObject.Properties.Name -contains "scriptErrorScan") {
    $scriptErrorStatus = $report.scriptErrorScan.status
}
if (($exitCode -ne 0) -or ([int]$report.failureCount -gt 0) -or ($scriptErrorStatus -ne "passed")) {
    exit 1
}

exit 0
