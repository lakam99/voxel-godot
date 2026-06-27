param(
    [ValidateSet("All", "NoonWork", "DuskReturnHome", "MidnightTown", "MidnightGuardAndInteriors", "DawnTransition", "CrowdedDoorTraffic", "PlayerNpcSharedDoor", "DynamicBlockRepair")]
    [string]$Scenario = "All",
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Transition",
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$TraceDir = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 45,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$timeModeValue = $TimeMode.ToLowerInvariant()
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\observation-$Scenario-$timeModeValue.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\observation-$Scenario-$timeModeValue.txt"
}
if ($TraceDir -eq "") {
    $TraceDir = Join-Path $projectPath "artifacts\npc\traces\observation-$Scenario-$timeModeValue"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\observation-$Scenario-$timeModeValue"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$TraceDir = [System.IO.Path]::GetFullPath($TraceDir)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $TraceDir | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue

$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_NPC_TEST_SEED = $Seed
$env:VOXEL_NPC_OBSERVATION_SCENARIO = $Scenario
$env:VOXEL_NPC_TIME_MODE = $timeModeValue
$env:VOXEL_NPC_OBSERVATION_REPORT = $ReportPath
$env:VOXEL_NPC_OBSERVATION_PROGRESS = $ProgressPath
$env:VOXEL_NPC_OBSERVATION_TRACE_DIR = $TraceDir
$env:VOXEL_NPC_OBSERVATION_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_NPC_TEST_RUN_TOKEN = $runToken
$env:VOXEL_NPC_TEST_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/testing/npc/NpcObservationTest.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
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

$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = -not $Visible
$process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
$started = Get-Date
[void]$process.Start()

while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 250
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-ProcessTree $process
        Write-Error "NPC observation watchdog exceeded $WatchdogSeconds seconds"
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

$exitCode = $process.ExitCode
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh NPC observation report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "NPC observation report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($null -eq $report.failureCount) {
    Write-Error "NPC observation report missing failureCount"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

Get-Content -LiteralPath $ReportPath
if ($exitCode -ne 0 -or [int]$report.failureCount -gt 0) {
    exit 1
}

exit 0
