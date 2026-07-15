param(
    [string]$Seed = "atlas-31684266",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\vox59\voxel-terrain-collision-publication.json"
}
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_UNDERGROUND_VISUAL_FAST_BOOT = "1"
$env:VOXEL_TERRAIN_PUBLICATION_REPORT = $ReportPath
try {
    $args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/testing/VoxelTerrainCollisionPublication.tscn")
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $GodotExe
    $process.StartInfo.WorkingDirectory = $projectPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $false
    $process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
    [void]$process.Start()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
} finally {
    Remove-Item Env:\VOXEL_TEST_SEED,Env:\VOXEL_UNDERGROUND_VISUAL_FAST_BOOT,Env:\VOXEL_TERRAIN_PUBLICATION_REPORT -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing voxel terrain collision publication report: $ReportPath"
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
Get-Content -LiteralPath $ReportPath
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}
