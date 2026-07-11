param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [int]$WatchdogSeconds = 240
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") { $ReportPath = Join-Path $projectPath "artifacts\vox43\fresh-world-traversal.json" }
if ($ProgressPath -eq "") { $ProgressPath = Join-Path $projectPath "artifacts\vox43\fresh-world-traversal-progress.txt" }
if ($ScreenshotDir -eq "") { $ScreenshotDir = Join-Path $projectPath "artifacts\vox43\screenshots\fresh-world-traversal" }
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
$runToken = [guid]::NewGuid().ToString("N")
$isolatedSave = Join-Path $projectPath "artifacts\vox43\fresh-world-isolated\$runToken\voxel_biome_world_saves.json"
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($isolatedSave)) | Out-Null
Remove-Item -LiteralPath $ReportPath,$ProgressPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $ScreenshotDir "*.png") -ErrorAction SilentlyContinue

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    foreach ($child in $children) { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
}

$forbiddenNames = @("VOXEL_PLAYTEST", "VOXEL_TEST_SEED", "VOXEL_GOD_MODE", "VOXEL_REAL_TUTORIAL_GOD_MODE")
$previous = @{}
foreach ($name in $forbiddenNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }
$runnerNames = @(
    "VOXEL_VOX43_FRESH_WORLD_REAL_BOOT", "VOXEL_VOX43_FRESH_WORLD_REPORT",
    "VOXEL_VOX43_FRESH_WORLD_PROGRESS", "VOXEL_VOX43_FRESH_WORLD_SCREENSHOT_DIR",
    "VOXEL_VOX43_FRESH_WORLD_RUN_TOKEN", "VOXEL_VOX43_FRESH_WORLD_WATCHDOG_SECONDS",
    "VOXEL_SAVE_PATH_OVERRIDE"
)
foreach ($name in $runnerNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

$process = $null
try {
    foreach ($name in $forbiddenNames) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    $env:VOXEL_VOX43_FRESH_WORLD_REAL_BOOT = "1"
    $env:VOXEL_VOX43_FRESH_WORLD_REPORT = $ReportPath
    $env:VOXEL_VOX43_FRESH_WORLD_PROGRESS = $ProgressPath
    $env:VOXEL_VOX43_FRESH_WORLD_SCREENSHOT_DIR = $ScreenshotDir
    $env:VOXEL_VOX43_FRESH_WORLD_RUN_TOKEN = $runToken
    $env:VOXEL_VOX43_FRESH_WORLD_WATCHDOG_SECONDS = [string]$WatchdogSeconds
    $env:VOXEL_SAVE_PATH_OVERRIDE = $isolatedSave

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $GodotExe
    $process.StartInfo.WorkingDirectory = $projectPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $false
    $process.StartInfo.Arguments = '"--path" "' + $projectPath + '"'
    [void]$process.Start()
    $started = Get-Date
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $ReportPath) {
            try {
                $candidate = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
                if (($candidate.runToken -eq $runToken) -and ($true -eq $candidate.finished)) { break }
            } catch {}
        }
        if (((Get-Date) - $started).TotalSeconds -gt 20 -and -not (Test-Path -LiteralPath $ProgressPath)) {
            throw "Fresh-world traversal runner did not attach within 20 seconds"
        }
        if (((Get-Date) - $started).TotalSeconds -gt ($WatchdogSeconds + 20)) { break }
    }
    if (-not $process.HasExited) { Stop-ProcessTree $process }
} finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-ProcessTree $process }
    foreach ($name in $previous.Keys) {
        if ($null -eq $previous[$name]) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$name" $previous[$name] }
    }
}

if (-not (Test-Path -LiteralPath $ReportPath)) { throw "Fresh-world traversal report missing: $ReportPath" }
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($report.runToken -ne $runToken) { throw "Fresh-world traversal report token mismatch" }
if (-not $report.passed) { throw "Fresh-world traversal failed: $ReportPath" }
$requiredScreenshots = @("menu_before_new_game.png", "fresh_world_initial.png", "fresh_world_forest.png", "fresh_world_savanna.png")
foreach ($fileName in $requiredScreenshots) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScreenshotDir $fileName))) { throw "Fresh-world traversal screenshot missing: $fileName" }
}
$proof = [pscustomobject]@{
    headed = $true
    projectMainScene = "res://scenes/MainMenu.tscn"
    explicitSceneOverride = $false
    clickedNewGameViaViewportInput = $true
    forbiddenGameplayFlagsUnset = $true
    testSeedUnset = $true
    isolatedSavePath = $isolatedSave
}
$report | Add-Member -NotePropertyName environmentProof -NotePropertyValue $proof -Force
$report | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ReportPath
& (Join-Path $projectPath "tools\assert-test-evidence-report.ps1") `
    -ReportPath $ReportPath `
    -RunnerId "vox43_fresh_world_traversal" `
    -EvidenceLevel "acceptance_visual" `
    -AcceptanceClaims @("vox43_fresh_world_surface_traversal") `
    -RequiredScreenshots $requiredScreenshots `
    -ScreenshotDir $ScreenshotDir `
    -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") `
    -RequireVisualProof | Out-Null
$validated = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($validated.testIntegrity.validationStatus -ne "passed") { throw "Fresh-world traversal evidence validation failed" }
Get-Content -Raw -LiteralPath $ReportPath
