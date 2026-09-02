[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/citadel-runtime-integration/site-build-queue-contract-01'),
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe'
)

# SOURCE-ONLY SYNTHETIC THREAD CONTRACT. No Site.prepare or gameplay acceptance.
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stageRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $stageRoot) { throw 'A fresh output directory is required; prior evidence is never overwritten.' }
if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) { throw "Missing Godot executable: $GodotExe" }
New-Item -ItemType Directory -Force -Path $stageRoot, (Join-Path $stageRoot 'userdata') | Out-Null
$sourceFiles = @('scripts/world/CitadelSiteBuildQueue.gd', 'scripts/testing/buildings/CitadelSiteBuildQueueContract.gd', 'tools/run-citadel-site-build-queue-contract.ps1')
$hashes = [ordered]@{}
foreach ($path in $sourceFiles) {
    $hashes[$path] = (Get-FileHash -LiteralPath (Join-Path $projectRoot $path) -Algorithm SHA256).Hash.ToLowerInvariant()
}
[ordered]@{
    schema = 'citadel-site-build-queue-launch/v1'
    evidenceLevel = 'source_only_synthetic_threaded_queue_contract'
    recordedUtc = [DateTime]::UtcNow.ToString('o')
    timeoutSeconds = 45
    sourceSha256 = $hashes
    projectRoot = $projectRoot
    seed = 'atlas-1492'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stageRoot 'launch.json') -Encoding UTF8
$reportPath = Join-Path $stageRoot 'report.json'
$stdoutPath = Join-Path $stageRoot 'stdout.log'
$stderrPath = Join-Path $stageRoot 'stderr.log'
$watchdogPath = Join-Path $stageRoot 'watchdog.json'
$environmentValues = @{
    APPDATA = Join-Path $stageRoot 'userdata'
    LOCALAPPDATA = Join-Path $stageRoot 'userdata'
    VOXEL_SAVE_PATH_OVERRIDE = Join-Path $stageRoot 'test-save.json'
    VOXEL_CITADEL_QUEUE_REPORT = $reportPath
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
        -SceneArguments @('res://scripts/testing/buildings/CitadelSiteBuildQueueContract.gd') `
        -TimeoutSeconds 45 -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -SummaryPath $watchdogPath -StopRequestPath (Join-Path $stageRoot 'stop-request.txt') | Out-Null
    $stageExit = $LASTEXITCODE
} finally {
    foreach ($key in $previousValues.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process')
    }
}
Set-StrictMode -Version Latest
$watchdog = Get-Content -Raw -LiteralPath $watchdogPath | ConvertFrom-Json
if ($stageExit -ne 0 -or $watchdog.overallExitCode -ne 0 -or $watchdog.functionalExitCode -ne 0 -or
    -not $watchdog.cleanupPassed -or -not $watchdog.authoritativeZeroProven -or
    -not $watchdog.finalMembershipKnown -or @($watchdog.finalJobMemberPids).Count -ne 0 -or
    $watchdog.cleanupUnresolved -or $watchdog.timedOut -or $watchdog.forcedCleanup) {
    throw "Failed run or owned-process cleanup: $watchdogPath"
}
foreach ($logPath in @($stdoutPath, $stderrPath)) {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw "Missing log: $logPath" }
    if (Select-String -LiteralPath $logPath -Pattern '(?i)(SCRIPT ERROR|ERROR:|Parse Error|Compile Error|ObjectDB instances leaked|resources still in use|RID allocations.*leaked)' -Quiet) {
        throw "Engine/script errors or leaks: $logPath"
    }
}
foreach ($path in $sourceFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path $projectRoot $path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[$path]) {
        throw "Source changed during execution: $path"
    }
}
$report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
if ($report.schema -ne 'citadel-site-build-queue-contract/v1' -or -not $report.complete -or -not $report.passed -or
    $report.evidenceLevel -ne 'source_only_synthetic_threaded_queue_contract' -or @($report.failures).Count -ne 0) {
    throw "Incomplete or failing synthetic contract: $reportPath"
}
[pscustomobject]@{ passed = $true; reportPath = $reportPath; watchdogPath = $watchdogPath; maxPollUsec = $report.maxPollUsec } | ConvertTo-Json
