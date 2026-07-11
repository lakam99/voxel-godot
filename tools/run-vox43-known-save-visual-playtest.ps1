param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe",
    [string]$SourceSavePath = "$env:APPDATA\Godot\app_userdata\Voxel Biome World Godot\voxel_biome_world_saves_slot_atlas-71906947.json",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [string]$ProofPath = "",
    [int]$WatchdogSeconds = 360
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\vox43\known-save-visual.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\vox43\known-save-visual-progress.txt"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\vox43\screenshots\known-save-visual"
}
if ($ProofPath -eq "") {
    $ProofPath = Join-Path $projectPath "artifacts\vox43\known-save-visual-proof.json"
}

$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [IO.Path]::GetFullPath($ScreenshotDir)
$ProofPath = [IO.Path]::GetFullPath($ProofPath)
$SourceSavePath = [IO.Path]::GetFullPath($SourceSavePath)
$isolatedDir = Join-Path $projectPath "artifacts\vox43\known-save-isolated"
$isolatedBasePath = Join-Path $isolatedDir "voxel_biome_world_saves.json"
$isolatedSlotPath = Join-Path $isolatedDir "voxel_biome_world_saves_slot_atlas-71906947.json"
$isolatedActivePath = Join-Path $isolatedDir "voxel_biome_world_saves_active_seed.txt"
$outLog = Join-Path $projectPath "artifacts\vox43\known-save-visual.out.log"
$errLog = Join-Path $projectPath "artifacts\vox43\known-save-visual.err.log"

if (-not (Test-Path -LiteralPath $SourceSavePath)) {
    Write-Error "Missing atlas-71906947 source save: $SourceSavePath"
    exit 1
}

New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $isolatedDir | Out-Null
Remove-Item -LiteralPath $ReportPath,$ProgressPath,$ProofPath,$outLog,$errLog -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ScreenshotDir -Filter "*.png" -File -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $isolatedBasePath,$isolatedSlotPath,$isolatedActivePath -Force -ErrorAction SilentlyContinue

$sourceHashBefore = (Get-FileHash -LiteralPath $SourceSavePath -Algorithm SHA256).Hash
Copy-Item -LiteralPath $SourceSavePath -Destination $isolatedSlotPath
[IO.File]::WriteAllText($isolatedBasePath, "{}")
[IO.File]::WriteAllText($isolatedActivePath, "atlas-71906947")
$isolatedHashBefore = (Get-FileHash -LiteralPath $isolatedSlotPath -Algorithm SHA256).Hash
if ($sourceHashBefore -ne $isolatedHashBefore) {
    Write-Error "Isolated save copy is not byte-equivalent to source"
    exit 1
}

$forbiddenGameplayEnvVars = @(
    "VOXEL_PLAYTEST",
    "VOXEL_TEST_SEED",
    "VOXEL_GOD_MODE",
    "VOXEL_REAL_TUTORIAL_GOD_MODE",
    "VOXEL_RUNTIME_PERF_FAST_BOOT",
    "VOXEL_UNDERGROUND_VISUAL_FAST_BOOT"
)
foreach ($name in $forbiddenGameplayEnvVars) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}

$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_SAVE_PATH_OVERRIDE = $isolatedBasePath
$env:VOXEL_VOX43_KNOWN_SAVE_REAL_BOOT = "1"
$env:VOXEL_VOX43_KNOWN_SAVE_REPORT = $ReportPath
$env:VOXEL_VOX43_KNOWN_SAVE_PROGRESS = $ProgressPath
$env:VOXEL_VOX43_KNOWN_SAVE_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_VOX43_KNOWN_SAVE_RUN_TOKEN = $runToken
$env:VOXEL_VOX43_KNOWN_SAVE_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$flagProof = [ordered]@{}
$flagsPassed = $true
foreach ($name in $forbiddenGameplayEnvVars) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    $present = -not [string]::IsNullOrEmpty($value)
    $flagProof[$name] = [pscustomobject]@{ present = $present; valueLength = if ($null -eq $value) { 0 } else { ([string]$value).Length } }
    if ($present) {
        $flagsPassed = $false
    }
}
$proof = [pscustomobject]@{
    schemaVersion = 1
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    passed = $flagsPassed
    launch = [pscustomobject]@{
        executable = $GodotExe
        arguments = @("--path", $projectPath)
        projectMainScene = "res://scenes/MainMenu.tscn"
        headed = $true
        explicitSceneOverride = $false
    }
    forbiddenGameplayFlags = [pscustomobject]$flagProof
    saveOverride = [pscustomobject]@{
        purpose = "isolated byte-equivalent copy of the real atlas-71906947 save"
        sourcePath = $SourceSavePath
        sourceSha256Before = $sourceHashBefore
        isolatedBasePath = $isolatedBasePath
        isolatedSlotPath = $isolatedSlotPath
        isolatedSha256Before = $isolatedHashBefore
        byteEquivalentBeforeLaunch = $sourceHashBefore -eq $isolatedHashBefore
    }
    runToken = $runToken
}
$proof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProofPath
if (-not $flagsPassed) {
    Write-Error "Gameplay-affecting environment flags were present; proof: $ProofPath"
    exit 1
}

$process = Start-Process -FilePath $GodotExe `
    -ArgumentList @("--path", $projectPath) `
    -WorkingDirectory $projectPath `
    -PassThru `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog
$started = Get-Date
$lastProgressWrite = [datetime]::MinValue
Write-Host "Started headed VOX-43 known-save run PID $($process.Id)"
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    $scriptErrors = @()
    foreach ($logPath in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $logPath) {
            $scriptErrors += @(Select-String -LiteralPath $logPath -Pattern 'SCRIPT ERROR:|Parse Error:|Failed to load script' -ErrorAction SilentlyContinue)
        }
    }
    if ($scriptErrors.Count -gt 0) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Write-Error "VOX-43 known-save runner script error; see $errLog"
        exit 1
    }
    if (Test-Path -LiteralPath $ProgressPath) {
        $item = Get-Item -LiteralPath $ProgressPath
        if ($item.LastWriteTimeUtc -gt $lastProgressWrite) {
            $lastProgressWrite = $item.LastWriteTimeUtc
            Write-Host "progress: $((Get-Content -LiteralPath $ProgressPath -Raw).Trim())"
        }
    }
    if (Test-Path -LiteralPath $ReportPath) {
        try {
            $live = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
            if ($live.runToken -eq $runToken -and [bool]$live.finished) {
                if (-not $process.WaitForExit(5000)) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
                break
            }
        } catch {
        }
    }
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Write-Error "VOX-43 known-save visual watchdog exceeded $WatchdogSeconds seconds"
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing VOX-43 known-save report: $ReportPath"
    if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog }
    exit 1
}

$sourceHashAfter = (Get-FileHash -LiteralPath $SourceSavePath -Algorithm SHA256).Hash
$isolatedHashAfter = (Get-FileHash -LiteralPath $isolatedSlotPath -Algorithm SHA256).Hash
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$proof.saveOverride | Add-Member -Force -NotePropertyName sourceSha256After -NotePropertyValue $sourceHashAfter
$proof.saveOverride | Add-Member -Force -NotePropertyName isolatedSha256After -NotePropertyValue $isolatedHashAfter
$proof.saveOverride | Add-Member -Force -NotePropertyName sourceUnchanged -NotePropertyValue ($sourceHashBefore -eq $sourceHashAfter)
$proof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProofPath
$report | Add-Member -Force -NotePropertyName environmentAndSaveProof -NotePropertyValue $proof
$report | Add-Member -Force -NotePropertyName environmentAndSaveProofPath -NotePropertyValue $ProofPath
$report | Add-Member -Force -NotePropertyName stdoutLog -NotePropertyValue $outLog
$report | Add-Member -Force -NotePropertyName stderrLog -NotePropertyValue $errLog
$report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath

$requiredScreenshots = @(
    "menu_before_continue.png",
    "known_save_initial.png",
    "known_save_forest.png",
    "known_save_savanna.png",
    "known_save_failure_area.png"
)
foreach ($name in $requiredScreenshots) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScreenshotDir $name))) {
        Write-Error "Missing required VOX-43 screenshot: $name"
        exit 1
    }
}
if ($report.runToken -ne $runToken -or $true -ne $report.finished) {
    Write-Error "VOX-43 known-save report is stale or unfinished"
    exit 1
}
if ($sourceHashBefore -ne $sourceHashAfter) {
    Write-Error "The real source save changed during isolated acceptance"
    exit 1
}
if ($true -ne $report.passed) {
    Get-Content -LiteralPath $ReportPath
    exit 1
}

& (Join-Path $projectPath "tools\assert-test-evidence-report.ps1") `
    -ReportPath $ReportPath `
    -RunnerId "vox43_known_save_visual" `
    -EvidenceLevel "acceptance_visual" `
    -AcceptanceClaims @("vox43_known_save_surface_fluid_visual") `
    -RequiredScreenshots $requiredScreenshots `
    -ScreenshotDir $ScreenshotDir `
    -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") `
    -RequireVisualProof | Out-Null
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($report.testIntegrity.validationStatus -ne "passed") {
    Write-Error "VOX-43 known-save evidence validation failed"
    exit 1
}

Get-Content -LiteralPath $ReportPath
exit 0
