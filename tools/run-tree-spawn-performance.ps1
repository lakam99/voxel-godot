param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "artifacts\vegetation\tree-spawn-performance.json"
)

$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$AbsoluteReportPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectPath $ReportPath))
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($AbsoluteReportPath)) | Out-Null
$env:VOXEL_TREE_SPAWN_PERFORMANCE_REPORT = $AbsoluteReportPath

& $GodotExe --headless --path $ProjectPath --script res://scripts/testing/TreeSpawnPerformanceRunner.gd
$ExitCode = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $AbsoluteReportPath)) {
    throw "Tree spawn performance runner did not write report: $AbsoluteReportPath"
}
$Report = Get-Content -LiteralPath $AbsoluteReportPath -Raw | ConvertFrom-Json
Write-Output ([ordered]@{
    runnerId = $Report.runnerId
    evidenceLevel = $Report.evidenceLevel
    sampleCount = $Report.sampleCount
    publicationP99Usec = $Report.publication.p99Usec
    publicationMaxUsec = $Report.publication.maxUsec
    reportPath = $AbsoluteReportPath
} | ConvertTo-Json)
exit $ExitCode
