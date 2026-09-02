[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    # Confirmed production boundary strings; every observed stage is also tested.
    [hashtable]$StageMap = @{
        entry = 'physical_validation_started'; resolve = 'physical_resolve_schema'
        grid = 'physical_grid_cells'; support_resolution = 'physical_resolve_support'
        validation = 'physical_validation_part'; frame = 'physical_frame_part'
        final = 'physical_validation_completed'
    },
    [switch]$AuthorizeLaunch,
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 60,
    [string]$GodotExe = 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe'
)
# SOURCE/SERVICE ONLY. Do not launch before main confirms interface stability
# and explicitly authorizes the run. No editor import, fullbuild or headed mode.
$ErrorActionPreference = 'Stop'
if (-not $AuthorizeLaunch) { throw 'Launch deferred: main must confirm stable interfaces and authorize this run before -AuthorizeLaunch.' }
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runPath = [IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if (-not $runPath.StartsWith($projectPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output directory must stay inside the invoking project.' }
if (Test-Path -LiteralPath $runPath) { throw 'Fresh output directory required.' }
foreach ($boundary in @('entry', 'resolve', 'grid', 'support_resolution', 'validation', 'frame', 'final')) {
    if ($StageMap[$boundary] -isnot [string] -or [string]::IsNullOrWhiteSpace($StageMap[$boundary])) { throw "Missing exact stage string: $boundary" }
}
$branch = & git -C $projectPath branch --show-current
if ($LASTEXITCODE -ne 0) { throw 'Unable to record branch.' }
$head = & git -C $projectPath rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Unable to record HEAD.' }
$sourceHashes = [ordered]@{}
foreach ($relative in @(
    'scripts/buildings/BuildingBlueprint.gd', 'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/GablePurlinFrameValidator.gd', 'scripts/buildings/MandatoryPhysicalDependencyValidator.gd',
    'scripts/testing/buildings/BuildingValidationCancellationContract.gd',
    'tools/run-building-validation-cancellation-contract.ps1', 'tools/run-godot-scene-watchdog.ps1'
)) { $sourceHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $projectPath $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
$values = @{
    BUILDING_CANCELLATION_REPORT = (Join-Path $runPath 'report.json')
    BUILDING_CANCELLATION_STAGES = ($StageMap | ConvertTo-Json -Compress)
}
$previousValues = @{}
foreach ($key in $values.Keys) { $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
New-Item -ItemType Directory -Path $runPath | Out-Null
[ordered]@{
    schema = 'building_validation_cancellation_launch/v1'; branch = $branch; head = $head
    projectPath = $projectPath; sourceSha256 = $sourceHashes; stageMap = $StageMap
    timeoutSeconds = $TimeoutSeconds; launchedAtUtc = [DateTime]::UtcNow.ToString('o')
    scope = 'Small synthetic fixtures invoking real source proofs. No old/new frozen full-input differential, headed or NPC acceptance.'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding UTF8
$runnerExit = 2
try {
    foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key, $values[$key], 'Process') }
    & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') `
        -ProjectPath $projectPath -GodotExe $GodotExe -Headless -Scene '--script' `
        -SceneArguments @('res://scripts/testing/buildings/BuildingValidationCancellationContract.gd') `
        -TimeoutSeconds $TimeoutSeconds `
        -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') `
        -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
    $runnerExit = $LASTEXITCODE
    if ($runnerExit -eq 0) {
        $report = Get-Content -LiteralPath $values.BUILDING_CANCELLATION_REPORT -Raw | ConvertFrom-Json
        if ($report.complete -ne $true -or $report.passed -ne $true -or $report.schema -ne 'building_validation_cancellation_contract/v1') { $runnerExit = 1 }
        if (Select-String -LiteralPath (Join-Path $runPath 'stdout.log'), (Join-Path $runPath 'stderr.log') -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:' -Quiet) { $runnerExit = 1 }
    }
} finally {
    foreach ($key in $previousValues.Keys) { [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process') }
}
exit $runnerExit
