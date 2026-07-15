param(
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 90
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\underground\underground-visual-playtest.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\underground\underground-visual-playtest-progress.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\underground\screenshots\underground-visual"
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
$env:VOXEL_UNDERGROUND_VISUAL_REPORT = $ReportPath
$env:VOXEL_UNDERGROUND_VISUAL_PROGRESS = $ProgressPath
$env:VOXEL_UNDERGROUND_VISUAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_UNDERGROUND_VISUAL_RUN_TOKEN = $runToken
$env:VOXEL_UNDERGROUND_VISUAL_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$args = @(
    "--fixed-fps", "60",
    "--resolution", "1280x720",
    "--path", $projectPath,
    "--scene", "res://scenes/testing/UndergroundVisualPlaytest.tscn"
)

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
$process.StartInfo.CreateNoWindow = $false
$process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
$started = Get-Date
[void]$process.Start()

while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 250
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-ProcessTree $process
        Write-Error "Underground visual playtest watchdog exceeded $WatchdogSeconds seconds"
        if (Test-Path -LiteralPath $ProgressPath) {
            Get-Content -LiteralPath $ProgressPath
        }
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

$exitCode = $process.ExitCode
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh underground visual report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "Underground visual report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($true -ne $report.nonHeadlessRequired) {
    Write-Error "Underground visual report did not mark nonHeadlessRequired=true"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$requiredScreenshots = @(
    "underground_air_reference.png",
    "underground_wall_boundary.png",
    "underground_floor_boundary.png",
    "underground_ceiling_boundary.png",
    "underground_material_probe.png",
    "underground_collision_probe.png"
)
foreach ($fileName in $requiredScreenshots) {
    $path = Join-Path $ScreenshotDir $fileName
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "Missing underground visual proof screenshot: $path"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
}

$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
& $evidenceScript `
    -ReportPath $ReportPath `
    -RunnerId "underground_visual_playtest" `
    -EvidenceLevel "acceptance_visual" `
    -AcceptanceClaims @("procedural_underground_volume_visual") `
    -RequiredScreenshots $requiredScreenshots `
    -ScreenshotDir $ScreenshotDir `
    -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") `
    -RequireVisualProof | Out-Null
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $ReportPath
    exit $LASTEXITCODE
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
Get-Content -LiteralPath $ReportPath
if (($exitCode -ne 0) -or ([int]$report.failureCount -gt 0)) {
    exit 1
}

exit 0
