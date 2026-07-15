param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\project-compile-smoke-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_PROJECT_COMPILE_REPORT = $ReportPath

$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/ProjectCompileSmokeRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_PROJECT_COMPILE_REPORT -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}

if (Test-Path -LiteralPath $ReportPath) {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ([string]$report.evidenceLevel -ne "compile-smoke") {
        Write-Error "Project compile smoke evidenceLevel mismatch: $($report.evidenceLevel)"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing project compile smoke report: $ReportPath"
    exit 1
}

$engineErrors = @($godotOutput | Where-Object { $_ -match "SCRIPT ERROR|ERROR:" })
if ($engineErrors.Count -gt 0) {
    Write-Error "Project compile smoke emitted Godot errors."
    exit 1
}

exit $exitCode
