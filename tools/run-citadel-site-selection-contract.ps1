[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe'
)

# SOURCE CONTRACT ONLY. Do not launch until main review approves this runner.
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stageRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $stageRoot) { throw 'A fresh output directory is required; prior evidence is never overwritten.' }
if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) { throw "Godot executable not found: $GodotExe" }

# Generate and persist before Godot starts, including if parsing or setup fails.
$freshSeed = 'atlas-site-' + [Guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Path $stageRoot, (Join-Path $stageRoot 'userdata') | Out-Null
$reportPath = Join-Path $stageRoot 'report.json'
$stdoutPath = Join-Path $stageRoot 'stdout.log'
$stderrPath = Join-Path $stageRoot 'stderr.log'
$watchdogPath = Join-Path $stageRoot 'watchdog.json'
$sourceFiles = @(
    'scripts/world/CitadelSiteField.gd',
    'scripts/world/CitadelSiteSurvey.gd',
    'scripts/WorldGenerationSystem.gd',
    'scripts/terrain/VoxelWorldGenerationContext.gd',
    'scripts/world/BiomeRegionField.gd',
    'scripts/testing/buildings/CitadelSiteSelectionContract.gd',
    'tools/run-citadel-site-selection-contract.ps1'
)
$sourceHashes = [ordered]@{}
foreach ($relativePath in $sourceFiles) {
    $sourceHashes[$relativePath] = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relativePath) -Algorithm SHA256).Hash.ToLowerInvariant()
}
[ordered]@{
    schema = 'citadel-site-selection-launch/v1'
    recordedUtc = [DateTime]::UtcNow.ToString('o')
    projectRoot = $projectRoot
    fixedSeed = 'atlas-1492'
    randomSeed = $freshSeed
    densitySecondarySeed = $freshSeed + ':density-secondary'
    timeoutSeconds = 90
    evidenceLevel = 'source_service_contract'
    sourceSha256 = $sourceHashes
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stageRoot 'launch.json') -Encoding UTF8
Write-Host "Citadel source contract seed: $freshSeed; fixed seed: atlas-1492; evidence: $stageRoot"

$environmentValues = @{
    APPDATA = Join-Path $stageRoot 'userdata'
    LOCALAPPDATA = Join-Path $stageRoot 'userdata'
    VOXEL_SAVE_PATH_OVERRIDE = Join-Path $stageRoot 'test-save.json'
    VOXEL_CITADEL_SITE_REPORT = $reportPath
    VOXEL_CITADEL_SITE_SEED = $freshSeed
}
$previousValues = @{}
$stageExit = $null
try {
    foreach ($key in $environmentValues.Keys) {
        $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $environmentValues[$key], 'Process')
    }
    & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') `
        -ProjectPath $projectRoot -GodotExe $GodotExe -Headless -Scene '--script' `
        -SceneArguments @('res://scripts/testing/buildings/CitadelSiteSelectionContract.gd') `
        -TimeoutSeconds 90 -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -SummaryPath $watchdogPath -StopRequestPath (Join-Path $stageRoot 'stop-request.txt') | Out-Null
    $stageExit = $LASTEXITCODE
} finally {
    foreach ($key in $previousValues.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process')
    }
}

# Fail closed on missing evidence properties without changing the existing
# watchdog's execution scope or imposing StrictMode on that shared script.
Set-StrictMode -Version Latest
$watchdog = Get-Content -Raw -LiteralPath $watchdogPath | ConvertFrom-Json
if ($stageExit -ne 0 -or $watchdog.overallExitCode -ne 0 -or $watchdog.functionalExitCode -ne 0 -or
    -not $watchdog.cleanupPassed -or -not $watchdog.authoritativeZeroProven -or
    -not $watchdog.finalMembershipKnown -or @($watchdog.finalJobMemberPids).Count -ne 0 -or
    $watchdog.cleanupUnresolved -or $watchdog.timedOut -or $watchdog.forcedCleanup) {
    throw "Contract failed or owned processes did not exit cleanly; inspect $watchdogPath"
}
# A report boolean cannot overrule script/engine errors or leaked resources.
foreach ($logPath in @($stdoutPath, $stderrPath)) {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw "Missing log: $logPath" }
    if (Select-String -LiteralPath $logPath -Pattern '(?i)(SCRIPT ERROR|ERROR:|Parse Error|Compile Error|ObjectDB instances leaked|resources still in use|RID allocations.*leaked)' -Quiet) {
        throw "Engine/script errors or leaks remain; inspect $logPath"
    }
}
foreach ($relativePath in $sourceFiles) {
    $currentHash = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relativePath) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -ne $sourceHashes[$relativePath]) { throw "Source changed during execution: $relativePath" }
}
$report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
if ($report.schema -ne 'citadel-site-selection-contract/v1' -or -not $report.passed -or -not $report.complete -or
    $report.evidenceLevel -ne 'source_service_contract' -or @($report.failures).Count -ne 0 -or
    @($report.seeds).Count -ne 3 -or $report.seeds[0] -ne 'atlas-1492' -or $report.seeds[1] -ne $freshSeed -or
    $report.seeds[2] -ne ($freshSeed + ':density-secondary') -or @($report.density).Count -ne 3) {
    throw "Incomplete, mismatched, or failing source contract: $reportPath"
}
[pscustomobject]@{
    passed = $report.passed
    evidenceLevel = $report.evidenceLevel
    randomSeed = $freshSeed
    elapsedSeconds = $report.elapsedUsec / 1000000.0
    reportPath = $reportPath
    watchdogPath = $watchdogPath
} | ConvertTo-Json
