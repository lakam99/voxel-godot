param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ScreenshotDir = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\vegetation\environment-wind-visual.json"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\vegetation\environment-wind-screenshots"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_ENVIRONMENT_WIND_VISUAL_REPORT = $ReportPath
$env:VOXEL_ENVIRONMENT_WIND_SCREENSHOT_DIR = $ScreenshotDir
$godotOutput = & $GodotExe --path $projectPath --resolution 1280x720 "res://scenes/testing/EnvironmentWindVisualTest.tscn" 2>&1
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_ENVIRONMENT_WIND_VISUAL_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_ENVIRONMENT_WIND_SCREENSHOT_DIR -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing environment wind visual report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "environment_wind_visual" -or [string]$report.evidenceLevel -ne "visual_fixture") {
    Write-Error "Environment wind visual report identity mismatch"
    exit 1
}
[pscustomobject]@{
    runnerId = $report.runnerId
    passed = $report.passed
    resultCount = $report.resultCount
    failureCount = $report.failureCount
    captures = $report.captures.Count
    reportPath = $ReportPath
    screenshotDir = $ScreenshotDir
} | ConvertTo-Json
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}
exit 0
