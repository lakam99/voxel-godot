param(
    [int]$DurationSeconds = 75,
    [int]$WarmupFrames = 120,
    [string]$Seed = "",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$LogPath = "",
    [string]$ScreenshotPath = "",
    [string]$Resolution = "",
    [int]$WatchdogSeconds = 0,
    [ValidateSet("NormalSprintTraversal", "NormalTutorialTownGuardActivation")]
    [string]$Scenario = "NormalSprintTraversal",
    [switch]$Headless,
    [switch]$UseRealSave
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runToken = [guid]::NewGuid().ToString("N")
if ($WatchdogSeconds -le 0) {
    $WatchdogSeconds = [Math]::Max(240, $DurationSeconds + 150)
}
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\performance\normal-runtime-performance-pass.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\performance\normal-runtime-performance-pass-progress.txt"
}
if ($LogPath -eq "") {
    $LogPath = Join-Path $projectPath "artifacts\performance\normal-runtime-performance-pass-godot.log"
}
if ($ScreenshotPath -eq "") {
    $ScreenshotPath = Join-Path $projectPath "artifacts\performance\normal-runtime-performance-pass.png"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$LogPath = [System.IO.Path]::GetFullPath($LogPath)
$ScreenshotPath = [System.IO.Path]::GetFullPath($ScreenshotPath)

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($LogPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ScreenshotPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ScreenshotPath -ErrorAction SilentlyContinue

Remove-Item Env:VOXEL_PLAYTEST -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_RUNTIME_PERF_FAST_BOOT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_UNDERGROUND_VISUAL_FAST_BOOT -ErrorAction SilentlyContinue
Remove-Item Env:VOXEL_DIGGING_VISUAL_FAST_BOOT -ErrorAction SilentlyContinue
if ($Seed -eq "") {
    Remove-Item Env:VOXEL_TEST_SEED -ErrorAction SilentlyContinue
} else {
    $env:VOXEL_TEST_SEED = $Seed
}

$env:VOXEL_NORMAL_RUNTIME_PERF_REPORT = $ReportPath
$env:VOXEL_NORMAL_RUNTIME_PERF_PROGRESS = $ProgressPath
$env:VOXEL_NORMAL_RUNTIME_PERF_SCREENSHOT = $ScreenshotPath
$env:VOXEL_NORMAL_RUNTIME_PERF_RUN_TOKEN = $runToken
$env:VOXEL_NORMAL_RUNTIME_PERF_DURATION_SECONDS = [string]$DurationSeconds
$env:VOXEL_NORMAL_RUNTIME_PERF_WATCHDOG_SECONDS = [string]$WatchdogSeconds
$env:VOXEL_NORMAL_RUNTIME_PERF_WARMUP_FRAMES = [string]$WarmupFrames
$env:VOXEL_NORMAL_RUNTIME_PERF_SCENARIO = $Scenario

if ($UseRealSave) {
    Remove-Item Env:VOXEL_SAVE_PATH_OVERRIDE -ErrorAction SilentlyContinue
} else {
    $savePath = Join-Path $projectPath ("artifacts\performance\normal-runtime-save-{0}.json" -f $runToken)
    $env:VOXEL_SAVE_PATH_OVERRIDE = [System.IO.Path]::GetFullPath($savePath)
}

$godotArgs = @("--log-file", $LogPath, "--path", $projectPath, "--scene", "res://scenes/testing/NormalRuntimePerformancePass.tscn")
if ($Resolution -ne "") {
    $godotArgs = @("--resolution", $Resolution) + $godotArgs
}
if ($Headless) {
    $godotArgs = @("--headless") + $godotArgs
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
$process.StartInfo.CreateNoWindow = [bool]$Headless
$process.StartInfo.Arguments = ($godotArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
$started = Get-Date
[void]$process.Start()
$stoppedAfterCompletedReport = $false

while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $ReportPath) {
        $progressText = ""
        if (Test-Path -LiteralPath $ProgressPath) {
            $progressText = Get-Content -LiteralPath $ProgressPath -Raw
        }
        if ($progressText -match "capture_screenshot_done" -and (((Get-Date) - $started).TotalSeconds -gt ($DurationSeconds + 30))) {
            Stop-ProcessTree $process
            $stoppedAfterCompletedReport = $true
            break
        }
    }
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-ProcessTree $process
        Write-Error "Normal runtime performance pass watchdog exceeded $WatchdogSeconds seconds"
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

$exitCode = if ($stoppedAfterCompletedReport) { 0 } else { $process.ExitCode }
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh normal runtime performance report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "Normal runtime performance report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($null -eq $report.failureCount) {
    Write-Error "Normal runtime performance report missing failureCount"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

Get-Content -LiteralPath $ReportPath
if (($exitCode -ne 0) -or ([int]$report.failureCount -gt 0)) {
    exit 1
}

exit 0
