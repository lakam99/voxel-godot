param(
    [ValidateSet("All", "DayWork", "DuskReturnHome", "MidnightTown", "CrowdedDoorTraffic", "SprintTraversal", "UndergroundTraversal", "TerrainMeshingWarmup", "AutosaveEnabled", "AutosaveDisabled")]
    [string]$Scenario = "All",
    [string]$Seed = "atlas-1492",
    [int]$DurationSeconds = 60,
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$LogPath = "",
    [int]$WatchdogSeconds = 0,
    [int]$WarmupFrames = -1,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($WatchdogSeconds -le 0) {
    $scenarioCount = if ($Scenario -eq "All") { 8 } else { 1 }
    $WatchdogSeconds = [Math]::Max(300, ($DurationSeconds * $scenarioCount) + 90)
}
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\performance\runtime-observation-$Scenario.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\performance\runtime-observation-$Scenario-progress.txt"
}
if ($LogPath -eq "") {
    $LogPath = Join-Path $projectPath "artifacts\performance\runtime-observation-$Scenario-godot.log"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$LogPath = [System.IO.Path]::GetFullPath($LogPath)

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($LogPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue

$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_RUNTIME_PERF_SCENARIO = $Scenario
$env:VOXEL_RUNTIME_PERF_REPORT = $ReportPath
$env:VOXEL_RUNTIME_PERF_PROGRESS = $ProgressPath
$env:VOXEL_RUNTIME_PERF_RUN_TOKEN = $runToken
$env:VOXEL_RUNTIME_PERF_DURATION_SECONDS = [string]$DurationSeconds
$env:VOXEL_RUNTIME_PERF_WATCHDOG_SECONDS = [string]$WatchdogSeconds
if ($WarmupFrames -ge 0) {
    $env:VOXEL_RUNTIME_PERF_WARMUP_FRAMES = [string]$WarmupFrames
} else {
    Remove-Item Env:VOXEL_RUNTIME_PERF_WARMUP_FRAMES -ErrorAction SilentlyContinue
}

$args = @("--fixed-fps", "60", "--log-file", $LogPath, "--path", $projectPath, "--scene", "res://scenes/testing/RuntimePerformanceObservation.tscn")
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
    Start-Sleep -Milliseconds 500
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-ProcessTree $process
        Write-Error "Runtime performance observation watchdog exceeded $WatchdogSeconds seconds"
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

$exitCode = $process.ExitCode
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh runtime performance report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "Runtime performance report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($null -eq $report.failureCount) {
    Write-Error "Runtime performance report missing failureCount"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

Get-Content -LiteralPath $ReportPath
if (($exitCode -ne 0) -or ([int]$report.failureCount -gt 0)) {
    exit 1
}

exit 0
