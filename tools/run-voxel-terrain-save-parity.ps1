param(
    [string]$Seed = "atlas-31684266",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [int]$StageWatchdogSeconds = 180
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\vox59\voxel-terrain-save-parity.json"
}
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$writeReportPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($ReportPath), "voxel-terrain-save-parity-write.json")
$saveDir = Join-Path $projectPath "artifacts\vox59\save-parity"
$savePath = Join-Path $saveDir "voxel-save-parity.json"
New-Item -ItemType Directory -Force -Path $saveDir | Out-Null
Get-ChildItem -LiteralPath $saveDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $ReportPath,$writeReportPath -ErrorAction SilentlyContinue

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

function Invoke-ParityStage([string]$StageReportPath) {
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $GodotExe
    $process.StartInfo.WorkingDirectory = $projectPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.Arguments = (@(
        "--headless",
        "--path", $projectPath,
        "--script", "res://scripts/testing/terrain/VoxelTerrainSaveParityRunner.gd"
    ) | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
    $started = Get-Date
    [void]$process.Start()
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $StageReportPath) {
            try {
                $candidate = Get-Content -LiteralPath $StageReportPath -Raw | ConvertFrom-Json
                if ($null -ne $candidate.passed) {
                    Stop-ProcessTree $process
                    return $candidate
                }
            } catch {}
        }
        if (((Get-Date) - $started).TotalSeconds -gt $StageWatchdogSeconds) {
            Stop-ProcessTree $process
            throw "Voxel terrain save parity stage watchdog exceeded $StageWatchdogSeconds seconds"
        }
    }
    if (-not (Test-Path -LiteralPath $StageReportPath)) {
        throw "Voxel terrain save parity stage exited without report: $StageReportPath"
    }
    return Get-Content -LiteralPath $StageReportPath -Raw | ConvertFrom-Json
}

$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_SAVE_PATH_OVERRIDE = $savePath
$env:VOXEL_UNDERGROUND_VISUAL_FAST_BOOT = "1"
try {
    $env:VOXEL_TERRAIN_SAVE_PARITY_STAGE = "write"
    $env:VOXEL_TERRAIN_SAVE_PARITY_REPORT = $writeReportPath
    $writeReport = Invoke-ParityStage $writeReportPath
    if ($true -ne $writeReport.passed) {
        exit 1
    }
    $target = $writeReport.targetCell
    $env:VOXEL_TERRAIN_SAVE_PARITY_TARGET = "$($target.x),$($target.y),$($target.z)"
    $env:VOXEL_TERRAIN_SAVE_PARITY_STAGE = "read"
    $env:VOXEL_TERRAIN_SAVE_PARITY_REPORT = $ReportPath
    $report = Invoke-ParityStage $ReportPath
} finally {
    Remove-Item Env:\VOXEL_TEST_SEED,Env:\VOXEL_SAVE_PATH_OVERRIDE,Env:\VOXEL_UNDERGROUND_VISUAL_FAST_BOOT,Env:\VOXEL_TERRAIN_SAVE_PARITY_REPORT,Env:\VOXEL_TERRAIN_SAVE_PARITY_STAGE,Env:\VOXEL_TERRAIN_SAVE_PARITY_TARGET -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing voxel terrain save parity report: $ReportPath"
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
Get-Content -LiteralPath $ReportPath
if ($true -ne $report.passed) {
    exit 1
}
