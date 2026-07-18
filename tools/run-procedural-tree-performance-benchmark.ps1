param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "artifacts\vegetation\procedural-tree-performance.json"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$AbsoluteReportPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectPath $ReportPath))
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($AbsoluteReportPath)) | Out-Null
$env:VOXEL_PROCEDURAL_TREE_PERFORMANCE_REPORT = $AbsoluteReportPath

& $GodotExe --headless --fixed-fps 60 --path $ProjectPath --script res://scripts/testing/ProceduralTreePerformanceBenchmarkRunner.gd
$ExitCode = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $AbsoluteReportPath)) {
    throw "Procedural tree benchmark did not write report: $AbsoluteReportPath"
}
$Report = Get-Content -LiteralPath $AbsoluteReportPath -Raw | ConvertFrom-Json
Write-Output ([ordered]@{
    runnerId = $Report.runnerId
    evidenceLevel = $Report.evidenceLevel
    recipeRows = @($Report.recipeByFamilyTier).Count
    cacheHits = $Report.sameRequestCache.metrics.recipeCacheHits
    stagedPublished = $Report.stagedPublication.metrics.published
    stagedPublicationP99Usec = $Report.stagedPublication.metrics.publicationTiming.p99Usec
    reportPath = $AbsoluteReportPath
} | ConvertTo-Json)
exit $ExitCode
