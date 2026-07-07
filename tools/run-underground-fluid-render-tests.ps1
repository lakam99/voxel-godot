param(
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\underground\underground-fluid-render-contract.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_UNDERGROUND_FLUID_RENDER_REPORT = $ReportPath

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/UndergroundFluidRenderContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
Remove-Item Env:\VOXEL_UNDERGROUND_FLUID_RENDER_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_TEST_SEED -ErrorAction SilentlyContinue
Remove-Item Env:\VOXEL_PLAYTEST -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}

if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing underground fluid render report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "underground_fluid_render_contract") {
    Write-Error "Underground fluid render runnerId mismatch: $($report.runnerId)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ([string]$report.evidenceLevel -ne "integration") {
    Write-Error "Underground fluid render evidenceLevel mismatch: $($report.evidenceLevel)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
Get-Content -LiteralPath $ReportPath
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}

exit 0
