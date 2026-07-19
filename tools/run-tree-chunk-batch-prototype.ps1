param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [switch]$Visible
)

if ($ReportPath -eq "") {
    $ReportPath = Join-Path $ProjectPath "artifacts\vegetation\tree-chunk-batch-prototype.json"
}
$reportDirectory = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$env:VOXEL_TREE_CHUNK_BATCH_REPORT = $ReportPath
$args = @("--fixed-fps", "60", "--path", $ProjectPath, "--script", "res://scripts/testing/TreeChunkBatchRendererPrototypeRunner.gd")
if (-not $Visible) {
    $args = @("--headless") + $args
}
& $GodotExe @args
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_TREE_CHUNK_BATCH_REPORT -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing tree renderer comparison report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "tree_chunk_batch_renderer_prototype") {
    Write-Error "Tree renderer comparison report identity mismatch"
    exit 1
}
[pscustomobject]@{
    runnerId = $report.runnerId
    evidenceLevel = $report.evidenceLevel
    passed = $report.passed
    resultCount = $report.results.Count
    failureCount = @($report.results | Where-Object { -not $_.passed }).Count
    reportPath = [System.IO.Path]::GetFullPath($ReportPath)
} | ConvertTo-Json
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}
exit 0
