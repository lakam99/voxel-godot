param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\tutorial-town\startup-loading-readiness-contract.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_STARTUP_READINESS_CONTRACT_REPORT = $ReportPath
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/StartupLoadingReadinessContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_STARTUP_READINESS_CONTRACT_REPORT -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing startup loading readiness contract report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "startup_loading_readiness_contract" -or [string]$report.evidenceLevel -ne "contract") {
    Write-Error "Startup loading readiness report identity mismatch"
    exit 1
}
[pscustomobject]@{
    runnerId = $report.runnerId
    passed = $report.passed
    resultCount = $report.resultCount
    failureCount = $report.failureCount
    reportPath = $ReportPath
} | ConvertTo-Json
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}
exit 0
