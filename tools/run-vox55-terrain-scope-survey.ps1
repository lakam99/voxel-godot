param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe",
    [string]$SourceSavePath = "",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$ScreenshotDir = "",
    [string]$ProofPath = "",
    [int]$WatchdogSeconds = 210
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$saveDir = Join-Path $env:APPDATA "Godot\app_userdata\Voxel Biome World Godot"
$activeSeedPath = Join-Path $saveDir "voxel_biome_world_saves_active_seed.txt"
if (-not (Test-Path -LiteralPath $activeSeedPath)) {
    throw "Missing active seed file: $activeSeedPath"
}
$seed = (Get-Content -Raw -LiteralPath $activeSeedPath).Trim()
if ($SourceSavePath -eq "") {
    $SourceSavePath = Join-Path $saveDir ("voxel_biome_world_saves_slot_{0}.json" -f $seed)
}
if ($ReportPath -eq "") { $ReportPath = Join-Path $projectPath "artifacts\vox55\terrain-scope-survey.json" }
if ($ProgressPath -eq "") { $ProgressPath = Join-Path $projectPath "artifacts\vox55\terrain-scope-survey-progress.txt" }
if ($ScreenshotDir -eq "") { $ScreenshotDir = Join-Path $projectPath "artifacts\vox55\screenshots\terrain-scope-survey" }
if ($ProofPath -eq "") { $ProofPath = Join-Path $projectPath "artifacts\vox55\terrain-scope-survey-proof.json" }

$SourceSavePath = [IO.Path]::GetFullPath($SourceSavePath)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [IO.Path]::GetFullPath($ProgressPath)
$ScreenshotDir = [IO.Path]::GetFullPath($ScreenshotDir)
$ProofPath = [IO.Path]::GetFullPath($ProofPath)
$isolatedDir = Join-Path $projectPath "artifacts\vox55\isolated-save"
$isolatedBasePath = Join-Path $isolatedDir "voxel_biome_world_saves.json"
$isolatedSlotPath = Join-Path $isolatedDir ("voxel_biome_world_saves_slot_{0}.json" -f $seed)
$isolatedActivePath = Join-Path $isolatedDir "voxel_biome_world_saves_active_seed.txt"
$outLog = Join-Path $projectPath "artifacts\vox55\terrain-scope-survey.out.log"
$errLog = Join-Path $projectPath "artifacts\vox55\terrain-scope-survey.err.log"

if (-not (Test-Path -LiteralPath $SourceSavePath)) { throw "Missing source save: $SourceSavePath" }
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($ReportPath)),$ScreenshotDir,$isolatedDir | Out-Null
Remove-Item -LiteralPath $ReportPath,$ProgressPath,$ProofPath,$outLog,$errLog -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $ScreenshotDir -Filter "*.png" -File -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $isolatedBasePath,$isolatedSlotPath,$isolatedActivePath -Force -ErrorAction SilentlyContinue

$sourceHashBefore = (Get-FileHash -LiteralPath $SourceSavePath -Algorithm SHA256).Hash
Copy-Item -LiteralPath $SourceSavePath -Destination $isolatedSlotPath
[IO.File]::WriteAllText($isolatedBasePath, "{}")
[IO.File]::WriteAllText($isolatedActivePath, $seed)
$isolatedHashBefore = (Get-FileHash -LiteralPath $isolatedSlotPath -Algorithm SHA256).Hash
if ($sourceHashBefore -ne $isolatedHashBefore) { throw "Isolated save copy is not byte-equivalent" }

$forbidden = @("VOXEL_PLAYTEST","VOXEL_TEST_SEED","VOXEL_GOD_MODE","VOXEL_REAL_TUTORIAL_GOD_MODE","VOXEL_RUNTIME_PERF_FAST_BOOT","VOXEL_UNDERGROUND_VISUAL_FAST_BOOT")
foreach ($name in $forbidden) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
$runToken = [guid]::NewGuid().ToString("N")
$env:VOXEL_SAVE_PATH_OVERRIDE = $isolatedBasePath
$env:VOXEL_VOX55_TERRAIN_SURVEY_REAL_BOOT = "1"
$env:VOXEL_VOX55_TERRAIN_SURVEY_REPORT = $ReportPath
$env:VOXEL_VOX55_TERRAIN_SURVEY_PROGRESS = $ProgressPath
$env:VOXEL_VOX55_TERRAIN_SURVEY_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_VOX55_TERRAIN_SURVEY_RUN_TOKEN = $runToken
$env:VOXEL_VOX55_TERRAIN_SURVEY_WATCHDOG_SECONDS = [string]$WatchdogSeconds

$flagProof = [ordered]@{}
$flagsPassed = $true
foreach ($name in $forbidden) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    $present = -not [string]::IsNullOrEmpty($value)
    $flagProof[$name] = [pscustomobject]@{ present = $present; valueLength = if ($null -eq $value) { 0 } else { ([string]$value).Length } }
    if ($present) { $flagsPassed = $false }
}
$proof = [pscustomobject]@{
    schemaVersion = 1
    passed = $flagsPassed
    seed = $seed
    launch = [pscustomobject]@{ executable = $GodotExe; arguments = @("--path",$projectPath); headed = $true; mainScene = "res://scenes/MainMenu.tscn" }
    forbiddenGameplayFlags = [pscustomobject]$flagProof
    saveOverride = [pscustomobject]@{ sourcePath = $SourceSavePath; sourceSha256Before = $sourceHashBefore; isolatedPath = $isolatedSlotPath; isolatedSha256Before = $isolatedHashBefore; byteEquivalent = $sourceHashBefore -eq $isolatedHashBefore }
    runToken = $runToken
}
$proof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProofPath
if (-not $flagsPassed) { throw "Gameplay-affecting flags were present" }

$process = Start-Process -FilePath $GodotExe -ArgumentList @("--path",$projectPath) -WorkingDirectory $projectPath -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$started = Get-Date
$lastProgress = [datetime]::MinValue
while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    foreach ($logPath in @($outLog,$errLog)) {
        if (Test-Path $logPath) {
            $errors = @(Select-String -LiteralPath $logPath -Pattern 'SCRIPT ERROR:|Parse Error:|Failed to load script' -ErrorAction SilentlyContinue)
            if ($errors.Count -gt 0) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                throw "VOX-55 survey script error; see $errLog"
            }
        }
    }
    if (Test-Path $ProgressPath) {
        $item = Get-Item $ProgressPath
        if ($item.LastWriteTimeUtc -gt $lastProgress) {
            $lastProgress = $item.LastWriteTimeUtc
            Write-Host "progress: $((Get-Content -Raw $ProgressPath).Trim())"
        }
    }
    if (Test-Path $ReportPath) {
        try {
            $live = Get-Content -Raw $ReportPath | ConvertFrom-Json
            if ($live.runToken -eq $runToken -and [bool]$live.finished) {
                if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
                break
            }
        } catch {}
    }
    if (((Get-Date)-$started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "VOX-55 terrain survey watchdog exceeded $WatchdogSeconds seconds"
    }
}

if (-not (Test-Path $ReportPath)) { throw "Missing VOX-55 terrain survey report" }
$sourceHashAfter = (Get-FileHash -LiteralPath $SourceSavePath -Algorithm SHA256).Hash
$report = Get-Content -Raw $ReportPath | ConvertFrom-Json
$proof.saveOverride | Add-Member -Force -NotePropertyName sourceSha256After -NotePropertyValue $sourceHashAfter
$proof.saveOverride | Add-Member -Force -NotePropertyName sourceUnchanged -NotePropertyValue ($sourceHashBefore -eq $sourceHashAfter)
$proof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ProofPath
$report | Add-Member -Force -NotePropertyName environmentAndSaveProof -NotePropertyValue $proof
$report | Add-Member -Force -NotePropertyName environmentAndSaveProofPath -NotePropertyValue $ProofPath
$report | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $ReportPath
if ($report.runToken -ne $runToken -or $true -ne $report.finished -or $true -ne $report.passed) { throw "VOX-55 diagnostic survey did not complete cleanly" }
if ($sourceHashBefore -ne $sourceHashAfter) { throw "Real source save changed during isolated survey" }
Get-Content -Raw $ReportPath
