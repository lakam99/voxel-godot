param(
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 120
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\terrain-volume\town-ground-visual-playtest.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\terrain-volume\town-ground-visual-playtest-progress.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\terrain-volume\screenshots\town-ground-visual"
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

$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_TOWN_GROUND_VISUAL_REPORT = $ReportPath
$env:VOXEL_TOWN_GROUND_VISUAL_PROGRESS = $ProgressPath
$env:VOXEL_TOWN_GROUND_VISUAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_TOWN_GROUND_VISUAL_RUN_TOKEN = $runToken
$env:VOXEL_TOWN_GROUND_VISUAL_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$args = @(
    "--fixed-fps", "60",
    "--resolution", "1280x720",
    "--path", $projectPath,
    "--scene", "res://scenes/testing/TownGroundVisualPlaytest.tscn"
)

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) {
        return
    }
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $false
$process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
$started = Get-Date
[void]$process.Start()

$reportFinished = $false
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $ReportPath) {
        try {
            $candidate = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
            if (($candidate.runToken -eq $runToken) -and ($true -eq $candidate.finished)) {
                $reportFinished = $true
                Stop-ProcessTree $process
                break
            }
        } catch {}
    }
    if ((Test-Path -LiteralPath $ProgressPath) -and (Test-Path -LiteralPath $ReportPath)) {
        $progressHead = Get-Content -LiteralPath $ProgressPath -TotalCount 1 -ErrorAction SilentlyContinue
        if ($progressHead -like "finish:*") {
            $reportFinished = $true
            Stop-ProcessTree $process
            break
        }
    }
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-ProcessTree $process
        Write-Error "Town ground visual playtest watchdog exceeded $WatchdogSeconds seconds"
        if (Test-Path -LiteralPath $ProgressPath) {
            Get-Content -LiteralPath $ProgressPath
        }
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

if ($reportFinished -and -not $process.HasExited) {
    Stop-ProcessTree $process
}
$exitCode = if ($reportFinished) { 0 } else { $process.ExitCode }
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh town ground visual report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "Town ground visual report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($true -ne $report.nonHeadlessRequired) {
    Write-Error "Town ground visual report did not mark nonHeadlessRequired=true"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$requiredScreenshot = Join-Path $ScreenshotDir "town_ground_edge_volume.png"
if (-not (Test-Path -LiteralPath $requiredScreenshot)) {
    Write-Error "Missing town ground visual proof screenshot: $requiredScreenshot"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($true -ne $report.passed) {
    Write-Error "Town ground visual playtest failed"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

Get-Content -LiteralPath $ReportPath
exit $exitCode
