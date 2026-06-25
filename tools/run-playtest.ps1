param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ScreenshotPath = "",
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "playtest-report.json"
}
$progressPath = Join-Path $projectPath "playtest-progress.txt"
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $progressPath -ErrorAction SilentlyContinue

$env:VOXEL_PLAYTEST_REPORT = $ReportPath
$env:VOXEL_PLAYTEST_PROGRESS = $progressPath
$env:VOXEL_PLAYTEST = "1"
if ($ScreenshotPath -ne "") {
    $env:VOXEL_PLAYTEST_SCREENSHOT = $ScreenshotPath
} else {
    Remove-Item Env:\VOXEL_PLAYTEST_SCREENSHOT -ErrorAction SilentlyContinue
}

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/Playtest.tscn")
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

function Read-ReportPassed([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    if ((Test-Path -LiteralPath $progressPath) -and (Test-Path -LiteralPath $ReportPath)) {
        $progress = Get-Content -LiteralPath $progressPath -Raw -ErrorAction SilentlyContinue
        if ($progress -match "(?m)^finished$") {
            Start-Sleep -Seconds 2
            $passed = Read-ReportPassed $ReportPath
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
    $exitCode = $process.ExitCode
}

if (Test-Path -LiteralPath $ReportPath) {
    Get-Content -LiteralPath $ReportPath
}

exit $exitCode
