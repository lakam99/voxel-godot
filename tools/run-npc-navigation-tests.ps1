param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ScreenshotPath = "",
    [string]$Seed = "atlas-1492",
    [int]$TimeoutSeconds = 1800,
    [int]$StaleProgressSeconds = 300,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "npc-navigation-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$progressPath = [System.IO.Path]::GetFullPath((Join-Path $projectPath "npc-navigation-progress.txt"))
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($progressPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $progressPath -ErrorAction SilentlyContinue

$runToken = [guid]::NewGuid().ToString("N")

$env:VOXEL_PLAYTEST_REPORT = $ReportPath
$env:VOXEL_PLAYTEST_PROGRESS = $progressPath
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_PLAYTEST_RUN_TOKEN = $runToken
if ($ScreenshotPath -ne "") {
    $env:VOXEL_PLAYTEST_SCREENSHOT = $ScreenshotPath
} else {
    Remove-Item Env:\VOXEL_PLAYTEST_SCREENSHOT -ErrorAction SilentlyContinue
}

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/NpcNavigationTest.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) {
        return
    }
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        try {
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
    if (-not $Process.HasExited) {
        try {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
}

function Read-ReportPassed([string]$Path, [string]$ExpectedRunToken) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($ExpectedRunToken -ne "" -and $report.runToken -ne $ExpectedRunToken) {
            return $null
        }
        if (-not [bool]$report.finished) {
            return $null
        }
        return [bool]$report.passed
    } catch {
        return $null
    }
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = -not $Visible
$process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
[void]$process.Start()

$finishedByReport = $false
$exitCode = 1
$started = Get-Date
$lastProgressText = ""
$lastProgressAt = Get-Date
$watchdogReason = ""
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    $now = Get-Date
    if ($TimeoutSeconds -gt 0 -and (($now - $started).TotalSeconds -gt $TimeoutSeconds)) {
        $watchdogReason = "NPC navigation test timeout after $TimeoutSeconds seconds"
        Write-Warning $watchdogReason
        Stop-ProcessTree $process
        $exitCode = 1
        break
    }
    if (Test-Path -LiteralPath $progressPath) {
        $progress = Get-Content -LiteralPath $progressPath -Raw -ErrorAction SilentlyContinue
        if ($progress -ne $lastProgressText) {
            $lastProgressText = $progress
            $lastProgressAt = $now
        } elseif ($StaleProgressSeconds -gt 0 -and (($now - $lastProgressAt).TotalSeconds -gt $StaleProgressSeconds)) {
            $watchdogReason = "NPC navigation progress stale for $StaleProgressSeconds seconds"
            Write-Warning "$watchdogReason`n$progress"
            Stop-ProcessTree $process
            $exitCode = 1
            break
        }
    }
    if ((Test-Path -LiteralPath $env:VOXEL_PLAYTEST_PROGRESS) -and (Test-Path -LiteralPath $ReportPath)) {
        $progress = Get-Content -LiteralPath $env:VOXEL_PLAYTEST_PROGRESS -Raw -ErrorAction SilentlyContinue
        if ($progress -match "(?m)^finished$") {
            Start-Sleep -Seconds 2
            $passed = Read-ReportPassed $ReportPath $runToken
            if ($null -ne $passed) {
                $finishedByReport = $true
                Stop-ProcessTree $process
                $exitCode = if ($passed) { 0 } else { 1 }
                break
            }
        }
    }
}

if (-not $finishedByReport) {
    if ($process.HasExited) {
        $exitCode = $process.ExitCode
    }
    if ($watchdogReason -eq "") {
        $watchdogReason = "NPC navigation test exited before writing the finished progress marker"
    }
    $exitCode = 1
}

if (Test-Path -LiteralPath $ReportPath) {
    if (-not $finishedByReport -and $watchdogReason -ne "") {
        Write-Warning $watchdogReason
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ($report.runToken -ne $runToken) {
        Write-Error "NPC navigation report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing fresh NPC navigation report: $ReportPath"
    exit 1
}

exit $exitCode
