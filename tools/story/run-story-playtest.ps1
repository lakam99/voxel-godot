param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$Seed = "atlas-1492",
    [int]$TimeoutSeconds = 300,
    [int]$ReportGraceSeconds = 3,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\story\story-playtest-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
$progressPath = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\story\story-playtest-progress.txt"))
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $progressPath -ErrorAction SilentlyContinue

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_STORY_PLAYTEST = "1"
$env:VOXEL_STORY_PLAYTEST_REPORT = $ReportPath
$env:VOXEL_STORY_PLAYTEST_PROGRESS = $progressPath

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/story_testing/StoryPlaytest.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
}

function Stop-ProcessTreeById([int]$ProcessId) {
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTreeById -ProcessId ([int]$child.ProcessId)
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Read-FreshStoryResult([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -eq $report.PSObject.Properties["passed"]) {
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

$started = Get-Date
$reportReadyAt = $null
$reportPassed = $null
$exitCode = 1
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 250
    $now = Get-Date
    $freshResult = Read-FreshStoryResult -Path $ReportPath
    if ($null -ne $freshResult) {
        $reportPassed = $freshResult
        if ($null -eq $reportReadyAt) {
            $reportReadyAt = $now
        }
        if (($now - $reportReadyAt).TotalSeconds -ge $ReportGraceSeconds) {
            Stop-ProcessTreeById -ProcessId $process.Id
            $exitCode = if ($reportPassed) { 0 } else { 1 }
            break
        }
    }
    if ($TimeoutSeconds -gt 0 -and (($now - $started).TotalSeconds -gt $TimeoutSeconds)) {
        Write-Warning "Story playtest timeout after $TimeoutSeconds seconds"
        Stop-ProcessTreeById -ProcessId $process.Id
        $exitCode = 1
        break
    }
}

if ($process.HasExited -and $null -eq $reportPassed) {
    $reportPassed = Read-FreshStoryResult -Path $ReportPath
}
if ($process.HasExited -and $null -ne $reportPassed) {
    $exitCode = if ($reportPassed) { 0 } else { 1 }
}

if (Test-Path -LiteralPath $ReportPath) {
    Write-Host ("Story playtest complete: passed={0}, report={1}" -f $reportPassed, $ReportPath)
} else {
    Write-Error "Missing fresh story playtest report: $ReportPath"
    exit 1
}

exit $exitCode
