param(
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\caves\cave-generation-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_CAVE_GENERATION_REPORT = $ReportPath

& $GodotExe --headless --path $projectPath --script "res://scripts/testing/CaveGenerationTestRunner.gd"
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_CAVE_GENERATION_REPORT -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $ReportPath) {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ([string]$report.evidenceLevel -ne "integration") {
        Write-Error "Cave generation report evidenceLevel mismatch: $($report.evidenceLevel)"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing cave generation report: $ReportPath"
    exit 1
}

exit $exitCode
