param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe",
    [string]$ReportPath = "",
    [string]$ScreenshotPath = "",
    [int]$TimeoutSeconds = 75
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") { $ReportPath = Join-Path $projectPath "artifacts\vox59\voxel-tools-backend-smoke.json" }
if ($ScreenshotPath -eq "") { $ScreenshotPath = Join-Path $projectPath "artifacts\vox59\voxel-tools-backend-smoke.png" }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$ScreenshotPath = [IO.Path]::GetFullPath($ScreenshotPath)
$outLog = Join-Path $projectPath "artifacts\vox59\voxel-tools-backend-smoke.out.log"
$errLog = Join-Path $projectPath "artifacts\vox59\voxel-tools-backend-smoke.err.log"
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath,$ScreenshotPath,$outLog,$errLog -Force -ErrorAction SilentlyContinue

$env:VOXEL_TOOLS_SMOKE_REPORT = $ReportPath
$env:VOXEL_TOOLS_SMOKE_SCREENSHOT = $ScreenshotPath
$process = Start-Process -FilePath $GodotExe -ArgumentList @("--path",$projectPath,"res://scenes/testing/VoxelToolsBackendSmoke.tscn") -WorkingDirectory $projectPath -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$started = Get-Date
while (-not $process.HasExited -and ((Get-Date) - $started).TotalSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Milliseconds 250
}
if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force
    throw "Voxel Tools backend smoke timed out after $TimeoutSeconds seconds"
}
$process.WaitForExit()
$process.Refresh()
$processExitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
if (-not (Test-Path -LiteralPath $ReportPath)) {
    $errors = @()
    foreach ($path in @($outLog,$errLog)) {
        if (Test-Path -LiteralPath $path) { $errors += Get-Content -LiteralPath $path }
    }
    throw "Voxel Tools backend smoke produced no report. Output: $($errors -join [Environment]::NewLine)"
}
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($processExitCode -ne 0 -or -not [bool]$report.passed) {
    throw "Voxel Tools backend smoke failed: $($report.reason)"
}
if (-not (Test-Path -LiteralPath $ScreenshotPath)) {
    throw "Voxel Tools backend smoke passed without a screenshot"
}
$report | ConvertTo-Json -Depth 12
