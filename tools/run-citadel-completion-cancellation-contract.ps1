[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('cancellation', 'parity')][string]$Phase,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$AuthorizeLaunch,
    [string]$Archive = 'artifacts/citadel-visual-reset/opening-head-batch-06/candidate.bin',
    [string]$LaterStage = 'bracket_first_started',
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 60
)
# SOURCE/SERVICE CONTRACT ONLY. Main must authorize launch; no headed/fullbuild.
# Each phase owns exactly its watchdog process job and a fresh output directory.
$ErrorActionPreference = 'Stop'
if (-not $AuthorizeLaunch) { throw 'Launch deferred. Main must authorize this watchdog run; then pass -AuthorizeLaunch.' }
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$branch = & git -C $projectPath branch --show-current
if ($LASTEXITCODE -ne 0) { throw 'Unable to record branch.' }
$head = & git -C $projectPath rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Unable to record HEAD.' }
$runPath = [IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if (-not $runPath.StartsWith($projectPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output directory must stay inside the designated worktree.' }
if (Test-Path -LiteralPath $runPath) { throw 'Fresh output directory required.' }
$archivePath = [IO.Path]::GetFullPath((Join-Path $projectPath $Archive))
$archiveSha = '65149b8198ceaa52b19d27a1a8c2ee82edd5614e52bfd3d1e2cc65928e8b78cb'
if ($Phase -eq 'cancellation') {
    if (-not $archivePath.StartsWith($projectPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive must stay inside the designated worktree.' }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveSha) { throw 'Immutable opening-head archive hash mismatch.' }
    if ([string]::IsNullOrWhiteSpace($LaterStage)) { throw 'A nonempty actual later structural stage is required.' }
}
$values = @{
    CITADEL_COMPLETION_PHASE = $Phase
    CITADEL_COMPLETION_REPORT = (Join-Path $runPath 'report.json')
    CITADEL_COMPLETION_PROGRESS = (Join-Path $runPath 'progress.json')
    CITADEL_COMPLETION_ARCHIVE = $archivePath
    CITADEL_COMPLETION_LATER_STAGE = $LaterStage
}
$sourceHashes = [ordered]@{}
foreach ($relative in @(
    'scripts/testing/buildings/CitadelCompletionCancellationContract.gd',
    'scripts/buildings/CitadelStructuralCompletionRecipe.gd',
    'scripts/buildings/CitadelFacadeCompletionRecipe.gd',
    'scripts/buildings/OpeningHeadBandRecipe.gd',
    'scripts/buildings/LowerFacadeBearingRecipe.gd',
    'scripts/buildings/CitadelUrbanPocComposer.gd',
    'tools/run-citadel-completion-cancellation-contract.ps1',
    'tools/run-godot-scene-watchdog.ps1'
)) { $sourceHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $projectPath $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
$previousValues = @{}
foreach ($key in $values.Keys) { $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
New-Item -ItemType Directory -Path $runPath | Out-Null
[ordered]@{
    schema = 'citadel_completion_contract_launch/v1'; phase = $Phase; branch = $branch; head = $head
    sourceSha256 = $sourceHashes; archive = $archivePath; archiveSha256 = $archiveSha
    laterStage = $LaterStage; timeoutSeconds = $TimeoutSeconds; launchedAtUtc = [DateTime]::UtcNow.ToString('o')
    scope = 'Source/service contract only. NPC baseline deferred. No fullbuild, headed or runtime acceptance.'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding UTF8
$runnerExit = 2
try {
    foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key, $values[$key], 'Process') }
    & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') `
        -ProjectPath $projectPath `
        -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' `
        -Headless -Scene '--script' `
        -SceneArguments @('res://scripts/testing/buildings/CitadelCompletionCancellationContract.gd') `
        -TimeoutSeconds $TimeoutSeconds `
        -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') `
        -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
    $runnerExit = $LASTEXITCODE
    if ($runnerExit -eq 0) {
        $report = Get-Content -LiteralPath $values.CITADEL_COMPLETION_REPORT -Raw | ConvertFrom-Json
        if ($report.complete -ne $true -or $report.passed -ne $true -or $report.phase -ne $Phase) { $runnerExit = 1 }
        if (Select-String -LiteralPath (Join-Path $runPath 'stdout.log'), (Join-Path $runPath 'stderr.log') -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:' -Quiet) { $runnerExit = 1 }
    }
} finally {
    foreach ($key in $previousValues.Keys) { [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process') }
}
exit $runnerExit
