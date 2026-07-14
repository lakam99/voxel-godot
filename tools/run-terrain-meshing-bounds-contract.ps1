param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\terrain\terrain-meshing-bounds-contract-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_TERRAIN_MESH_BOUNDS_REPORT = $ReportPath

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/TerrainMeshingBoundsContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$godotOutput | ForEach-Object { Write-Output $_ }
Remove-Item Env:\VOXEL_TERRAIN_MESH_BOUNDS_REPORT -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $ReportPath) {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ([string]$report.evidenceLevel -ne "contract") {
        Write-Error "Terrain meshing bounds report evidenceLevel mismatch: $($report.evidenceLevel)"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing terrain meshing bounds report: $ReportPath"
    exit 1
}

exit $exitCode
