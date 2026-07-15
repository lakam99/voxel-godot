param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "artifacts\vegetation\canopy-runtime-contract.json"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$AbsoluteReportPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $ReportPath))
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($AbsoluteReportPath)) | Out-Null
$env:VOXEL_CANOPY_RUNTIME_CONTRACT_REPORT = $AbsoluteReportPath

& $GodotExe --headless --path $ProjectRoot --script "res://scripts/testing/CanopyRuntimeContractRunner.gd"
$ExitCode = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $AbsoluteReportPath)) {
    throw "Canopy runtime contract did not write report: $AbsoluteReportPath"
}
$Report = Get-Content -LiteralPath $AbsoluteReportPath -Raw | ConvertFrom-Json
Write-Output ([ordered]@{
    runnerId = $Report.runnerId
    passed = $Report.passed
    resultCount = $Report.resultCount
    failureCount = $Report.failureCount
    reportPath = $AbsoluteReportPath
} | ConvertTo-Json)
exit $ExitCode
