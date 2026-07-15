param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\vox43\exact-fluid-payload-contract.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_EXACT_FLUID_PAYLOAD_REPORT = $ReportPath
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/ExactFluidPayloadContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_EXACT_FLUID_PAYLOAD_REPORT -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}

if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing exact fluid payload contract report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "exact_fluid_payload_contract") {
    Write-Error "Exact fluid payload runnerId mismatch: $($report.runnerId)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ([string]$report.evidenceLevel -ne "contract") {
    Write-Error "Exact fluid payload evidenceLevel mismatch: $($report.evidenceLevel)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
Get-Content -LiteralPath $ReportPath
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}

exit 0
