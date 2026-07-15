param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\terrain\terrain-block-light-batch-contract-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_TERRAIN_BLOCK_LIGHT_BATCH_REPORT = $ReportPath

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/TerrainBlockLightBatchContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$godotOutput | ForEach-Object { Write-Output $_ }
Remove-Item Env:\VOXEL_TERRAIN_BLOCK_LIGHT_BATCH_REPORT -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $ReportPath) {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ([string]$report.evidenceLevel -ne "contract") {
        Write-Error "Terrain block-light batch report evidenceLevel mismatch: $($report.evidenceLevel)"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing terrain block-light batch contract report: $ReportPath"
    exit 1
}

exit $exitCode
