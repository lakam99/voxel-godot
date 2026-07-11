param(
    [string]$Seed = "",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 180
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($Seed -eq "") { $Seed = "vox43-fresh-cave-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
if ($ReportPath -eq "") { $ReportPath = Join-Path $projectPath "artifacts\vox43\surface-cave-visual.json" }
if ($ProgressPath -eq "") { $ProgressPath = Join-Path $projectPath "artifacts\vox43\surface-cave-visual-progress.txt" }
if ($ScreenshotDir -eq "") { $ScreenshotDir = Join-Path $projectPath "artifacts\vox43\screenshots\surface-cave-visual" }
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath,$ProgressPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $ScreenshotDir "*.png") -ErrorAction SilentlyContinue

$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_VOX43_CAVE_REPORT = $ReportPath
$env:VOXEL_VOX43_CAVE_PROGRESS = $ProgressPath
$env:VOXEL_VOX43_CAVE_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_VOX43_CAVE_RUN_TOKEN = $runToken
$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $false
$process.StartInfo.Arguments = '"--fixed-fps" "60" "--resolution" "1280x720" "--path" "' + $projectPath + '" "--scene" "res://scenes/testing/Vox43SurfaceCaveVisual.tscn"'
try {
    [void]$process.Start()
    $started = Get-Date
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $ReportPath) {
            try {
                $candidate = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
                if (($candidate.runToken -eq $runToken) -and ($candidate.finished)) { break }
            } catch {}
        }
        if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) { break }
    }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
} finally {
    Remove-Item Env:VOXEL_VOX43_CAVE_REPORT,Env:VOXEL_VOX43_CAVE_PROGRESS,Env:VOXEL_VOX43_CAVE_SCREENSHOT_DIR,Env:VOXEL_VOX43_CAVE_RUN_TOKEN -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $ReportPath)) { throw "Surface cave visual report missing: $ReportPath" }
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if (-not $report.passed) { throw "Surface cave visual failed: $ReportPath" }
$required = @("fresh_surface_cave_entrance.png")
& (Join-Path $projectPath "tools\assert-test-evidence-report.ps1") -ReportPath $ReportPath -RunnerId "vox43_surface_cave_visual" -EvidenceLevel "acceptance_visual" -AcceptanceClaims @("vox43_fresh_surface_cave_visual") -RequiredScreenshots $required -ScreenshotDir $ScreenshotDir -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") -RequireVisualProof | Out-Null
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($report.testIntegrity.validationStatus -ne "passed") { throw "Surface cave visual evidence validation failed" }
$report | ConvertTo-Json -Depth 20
