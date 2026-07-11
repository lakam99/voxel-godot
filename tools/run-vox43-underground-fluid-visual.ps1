param(
    [string]$Seed = "atlas-71906947",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 120
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") { $ReportPath = Join-Path $projectPath "artifacts\vox43\underground-fluid-visual.json" }
if ($ProgressPath -eq "") { $ProgressPath = Join-Path $projectPath "artifacts\vox43\underground-fluid-visual-progress.txt" }
if ($ScreenshotDir -eq "") { $ScreenshotDir = Join-Path $projectPath "artifacts\vox43\screenshots\underground-fluid-visual" }
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath,$ProgressPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $ScreenshotDir "*.png") -ErrorAction SilentlyContinue

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_VOX43_FLUID_VISUAL_REPORT = $ReportPath
$env:VOXEL_VOX43_FLUID_VISUAL_PROGRESS = $ProgressPath
$env:VOXEL_VOX43_FLUID_VISUAL_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_VOX43_FLUID_VISUAL_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$args = @(
    "--fixed-fps", "60",
    "--resolution", "1280x720",
    "--path", $projectPath,
    "--scene", "res://scenes/testing/Vox43UndergroundFluidVisual.tscn"
)
$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $false
$process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
$started = Get-Date
try {
    [void]$process.Start()
    while (-not $process.HasExited) {
        if (Test-Path -LiteralPath $ReportPath) {
            try {
                $candidate = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
                if ($candidate.finished) { break }
            } catch {}
        }
        if (((Get-Date) - $started).TotalSeconds -gt ($WatchdogSeconds + 20)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
} finally {
    Remove-Item Env:VOXEL_VOX43_FLUID_VISUAL_REPORT -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_VOX43_FLUID_VISUAL_PROGRESS -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_VOX43_FLUID_VISUAL_SCREENSHOT_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_VOX43_FLUID_VISUAL_WATCHDOG_SECONDS -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $ReportPath)) { throw "VOX-43 underground fluid visual report missing: $ReportPath" }
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if (-not $report.passed) { throw "VOX-43 underground fluid visual report failed: $ReportPath" }
$requiredScreenshots = @(
    "generated_water_exposed.png",
    "generated_water_enclosed.png",
    "generated_lava_exposed.png"
)
foreach ($fileName in $requiredScreenshots) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScreenshotDir $fileName))) {
        throw "VOX-43 underground fluid visual screenshot missing: $fileName"
    }
}
& (Join-Path $projectPath "tools\assert-test-evidence-report.ps1") `
    -ReportPath $ReportPath `
    -RunnerId "vox43_underground_fluid_visual" `
    -EvidenceLevel "acceptance_visual" `
    -AcceptanceClaims @("vox43_generated_underground_fluid_visual") `
    -RequiredScreenshots $requiredScreenshots `
    -ScreenshotDir $ScreenshotDir `
    -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") `
    -RequireVisualProof | Out-Null
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($report.testIntegrity.validationStatus -ne "passed") { throw "VOX-43 underground fluid visual evidence validation failed" }
$report | ConvertTo-Json -Depth 20
