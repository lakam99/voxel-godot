[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('baseline', 'success', 'cancellation', 'failure', 'reuse-reference', 'reuse', 'planner')][string]$Phase,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$BaselineDirectory,
    [string]$ReuseReferenceDirectory,
    [string]$CancelStage,
    [ValidateRange(1, 1000000)][int]$CancelOccurrence = 1,
    [ValidateSet('builder', 'source')][string]$Target = 'builder',
    [ValidateSet('omitted', 'empty', 'true')][string]$Mode = 'true',
    [string]$ExpectedBuilderSha256,
    [switch]$PrepareOnly,
    [switch]$AuthorizeCurrent,
    [ValidateRange(1, 90)][int]$TimeoutSeconds = 90
)
# Source-only. Root-derived, fresh artifacts, process-owning external watchdog.
$ErrorActionPreference = 'Stop'
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot = Join-Path $projectPath 'artifacts/citadel-runtime-integration'
$runPath = [IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if ((Split-Path $runPath -Parent) -ne $artifactRoot -or (Split-Path $runPath -Leaf) -notlike 'compound-cancellation-*') { throw 'Use an owned compound-cancellation-* artifact directory.' }
if (Test-Path -LiteralPath $runPath) { throw 'Fresh output required; baseline is never overwritten.' }
if ($Phase -ne 'baseline' -and -not $AuthorizeCurrent -and -not $PrepareOnly) { throw 'Current builds held until main interfaces are ready. Pass -AuthorizeCurrent only then.' }
if ($Phase -eq 'cancellation' -and [string]::IsNullOrWhiteSpace($CancelStage)) { throw 'Cancellation requires an explicit stage.' }
$sitePath = Join-Path $artifactRoot 'actual-site-source-05/result.bin'
$siteSha = '7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf'
if ((Get-FileHash -LiteralPath $sitePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $siteSha) { throw 'Actual-site typed source hash mismatch.' }
$builderRelative = 'scripts/buildings/CastleCompoundBlueprintBuilder.gd'
$revision = '6994d2a8602aa3a76ff3f18a470d79ba2e7cbe3b'
$currentBuilderSha = (Get-FileHash -LiteralPath (Join-Path $projectPath $builderRelative)).Hash.ToLowerInvariant()
if ($ExpectedBuilderSha256 -and $ExpectedBuilderSha256 -cne $currentBuilderSha) { throw 'Current builder is not the authorized frozen revision.' }
$baselinePath = ''
$baselineSha = ''
$reusePath = ''
$reuseSha = ''
if ($Phase -eq 'reuse') {
    if ([string]::IsNullOrWhiteSpace($ReuseReferenceDirectory)) { throw 'Reuse phase needs its completed reuse-reference directory.' }
    $reusePath = [IO.Path]::GetFullPath((Join-Path $projectPath $ReuseReferenceDirectory))
    if ((Split-Path $reusePath -Parent) -ne $artifactRoot -or (Split-Path $reusePath -Leaf) -notlike 'compound-cancellation-*') { throw 'Reuse reference must stay in owned artifacts.' }
    $reuseReport = Get-Content -LiteralPath (Join-Path $reusePath 'report.json') -Raw | ConvertFrom-Json
    $reuseWatchdog = Get-Content -LiteralPath (Join-Path $reusePath 'watchdog.json') -Raw | ConvertFrom-Json
    $reuseSha = (Get-FileHash -LiteralPath (Join-Path $reusePath 'reuse-reference.bin')).Hash.ToLowerInvariant()
    if ($reuseReport.phase -ne 'reuse-reference' -or $reuseReport.passed -ne $true -or $reuseReport.complete -ne $true -or $reuseReport.reuseReferenceSha256 -cne $reuseSha -or $reuseWatchdog.overallExitCode -ne 0 -or $reuseWatchdog.cleanupPassed -ne $true) { throw 'Reuse reference integrity/cleanup gate failed.' }
}
if ($Phase -ne 'baseline') {
    if ([string]::IsNullOrWhiteSpace($BaselineDirectory)) { throw 'A completed baseline directory is required.' }
    $baselinePath = [IO.Path]::GetFullPath((Join-Path $projectPath $BaselineDirectory))
    if ((Split-Path $baselinePath -Parent) -ne $artifactRoot -or (Split-Path $baselinePath -Leaf) -notlike 'compound-cancellation-*') { throw 'Baseline must be an owned artifact directory.' }
    $baselineReport = Get-Content -LiteralPath (Join-Path $baselinePath 'report.json') -Raw | ConvertFrom-Json
    $baselineLaunch = Get-Content -LiteralPath (Join-Path $baselinePath 'launch.json') -Raw | ConvertFrom-Json -AsHashtable
    $baselineWatchdog = Get-Content -LiteralPath (Join-Path $baselinePath 'watchdog.json') -Raw | ConvertFrom-Json
    $baselineSha = (Get-FileHash -LiteralPath (Join-Path $baselinePath 'baseline.bin')).Hash.ToLowerInvariant()
    if ($baselineReport.phase -ne 'baseline' -or $baselineReport.passed -ne $true -or $baselineReport.complete -ne $true -or $baselineReport.baselineSha256 -cne $baselineSha -or $baselineWatchdog.cleanupPassed -ne $true -or $baselineWatchdog.overallExitCode -ne 0) { throw 'Baseline integrity/cleanup gate failed.' }
}
function Get-GitBytes([string]$relative) {
    $start = [Diagnostics.ProcessStartInfo]::new('git')
    $start.WorkingDirectory = $projectPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.ArgumentList.Add('show'); $start.ArgumentList.Add("${revision}:$relative")
    $process = [Diagnostics.Process]::Start($start)
    $stream = [IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($stream)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Cannot archive $relative" }
    $bytes = $stream.ToArray(); $stream.Dispose(); $process.Dispose()
    return ,$bytes
}
function Get-BytesSha([byte[]]$bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
$oldBytes = Get-GitBytes $builderRelative
$oldText = [Text.Encoding]::UTF8.GetString($oldBytes)
$frozenText = [regex]::Replace($oldText, '(?m)^class_name CastleCompoundBlueprintBuilder\r?\n', '')
if ($frozenText -eq $oldText) { throw 'Expected exactly one class_name removal.' }
$frozenBytes = [Text.Encoding]::UTF8.GetBytes($frozenText)
$pending = [Collections.Generic.Queue[string]]::new()
$pending.Enqueue('scripts/world/CitadelSiteField.gd')
foreach ($match in [regex]::Matches($frozenText, 'res://(scripts/[A-Za-z0-9_/.]+\.gd)')) { $pending.Enqueue($match.Groups[1].Value) }
$dependencies = [ordered]@{}
$liveDependencies = [ordered]@{}
$changedDependencies = [ordered]@{}
$dependencyBytes = @{}
while ($pending.Count -gt 0) {
    $relative = $pending.Dequeue()
    $key = 'res://' + $relative
    if ($dependencies.Contains($key)) { continue }
    if ($relative -eq $builderRelative) { throw 'Frozen dependency graph reaches mutable current builder.' }
    $bytes = Get-GitBytes $relative
    $sha = Get-BytesSha $bytes
    $diskText = [IO.File]::ReadAllText((Join-Path $projectPath $relative))
    $gitText = [Text.Encoding]::UTF8.GetString($bytes)
    $diskSha = (Get-FileHash -LiteralPath (Join-Path $projectPath $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
    $matchesGit = $diskText.Replace("`r`n", "`n") -ceq $gitText.Replace("`r`n", "`n")
    $approvedPlanner = $Phase -ne 'baseline' -and $relative -eq 'scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd'
    if (-not $matchesGit -and -not $approvedPlanner) { throw "Dependency differs from baseline commit: $relative" }
    if ($Phase -eq 'baseline') { $dependencies[$key] = $diskSha } else {
        if (-not $baselineLaunch.dependencies.ContainsKey($key)) { throw "Baseline dependency missing: $relative" }
        $dependencies[$key] = $baselineLaunch.dependencies[$key]
        $archived = Join-Path $baselinePath ('dependencies/' + $relative + '.txt')
        if ((Get-FileHash -LiteralPath $archived).Hash.ToLowerInvariant() -cne $sha) { throw "Archived dependency no longer equals exact Git bytes: $relative" }
    }
    if ($approvedPlanner -and $diskSha -cne $dependencies[$key]) {
        $changedDependencies[$key] = [ordered]@{ baselineSha256 = $dependencies[$key]; currentSha256 = $diskSha; policy = 'User-authorized planner continuation; old baseline captured with unchanged dependencies. Reference controls load archived old planner, never current planner.' }
    } else {
        if ($diskSha -cne $dependencies[$key]) { throw "Baseline dependency byte identity changed: $relative" }
        $liveDependencies[$key] = $diskSha
    }
    $dependencyBytes[$relative] = $bytes
    $code = [regex]::Replace($gitText, '(?m)#.*$', '')
    if ($code -match '\bCastleCompoundBlueprintBuilder\b') { throw "Global-class dependency reaches mutable builder: $relative" }
    foreach ($match in [regex]::Matches($gitText, 'res://(scripts/[A-Za-z0-9_/.]+\.gd)')) { $pending.Enqueue($match.Groups[1].Value) }
}
$currentSources = [ordered]@{}
if ($Phase -ne 'baseline') {
    $pending.Enqueue($builderRelative)
    $pending.Enqueue('scripts/buildings/CitadelRecipePreparation.gd')
    while ($pending.Count -gt 0) {
        $relative = $pending.Dequeue(); $key = 'res://' + $relative
        if ($currentSources.Contains($key)) { continue }
        $path = Join-Path $projectPath $relative
        $currentSources[$key] = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        foreach ($match in [regex]::Matches([IO.File]::ReadAllText($path), 'res://(scripts/[A-Za-z0-9_/.]+\.gd)')) { $pending.Enqueue($match.Groups[1].Value) }
    }
}
New-Item -ItemType Directory -Path $runPath | Out-Null
if ($Phase -eq 'baseline') {
    [IO.File]::WriteAllBytes((Join-Path $runPath 'GitCastleCompoundBlueprintBuilder.gd.txt'), $oldBytes)
    [IO.File]::WriteAllBytes((Join-Path $runPath 'FrozenCastleCompoundBlueprintBuilder.gd'), $frozenBytes)
    foreach ($relative in $dependencyBytes.Keys) {
        $target = Join-Path $runPath ('dependencies/' + $relative + '.txt')
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        [IO.File]::WriteAllBytes($target, $dependencyBytes[$relative])
    }
} else {
    # Preserve the original capture's class_name-only archive byte-for-byte.
    # A separate reference control binds the old builder to the old planner.
    $plannerRelative = 'scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd'
    $oldPlannerText = [Text.Encoding]::UTF8.GetString($dependencyBytes[$plannerRelative])
    $oldPlannerText = [regex]::Replace($oldPlannerText, '(?m)^class_name CastleCourtyardDistrictPlacementPlanner\r?\n', '')
    $oldPlannerPath = Join-Path $runPath 'FrozenCastleCourtyardDistrictPlacementPlanner.gd'
    [IO.File]::WriteAllText($oldPlannerPath, $oldPlannerText, [Text.UTF8Encoding]::new($false))
    $oldPlannerResource = 'res://' + [IO.Path]::GetRelativePath($projectPath, $oldPlannerPath).Replace('\', '/')
    $boundBuilderText = $frozenText.Replace('res://' + $plannerRelative, $oldPlannerResource)
    if ($boundBuilderText -ceq $frozenText) { throw 'Old planner binding was not rewritten.' }
    [IO.File]::WriteAllText((Join-Path $runPath 'BoundOldCastleCompoundBlueprintBuilder.gd'), $boundBuilderText, [Text.UTF8Encoding]::new($false))
}
$referenceSources = [ordered]@{}
if ($Phase -ne 'baseline') {
    foreach ($name in @('BoundOldCastleCompoundBlueprintBuilder.gd', 'FrozenCastleCourtyardDistrictPlacementPlanner.gd')) {
        $path = Join-Path $runPath $name
        $referenceSources[$path.Replace('\', '/')] = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
}
[IO.File]::Copy((Join-Path $projectPath 'scripts/testing/buildings/CitadelCompoundCancellationContract.gd'), (Join-Path $runPath 'contract.gd.txt'), $false)
[IO.File]::Copy($PSCommandPath, (Join-Path $runPath 'wrapper.ps1.txt'), $false)
$values = @{
    CITADEL_COMPOUND_PHASE = $Phase; CITADEL_COMPOUND_OUTPUT = $runPath.Replace('\', '/')
    CITADEL_COMPOUND_SITE = $sitePath.Replace('\', '/'); CITADEL_COMPOUND_BASELINE = $baselinePath.Replace('\', '/')
    CITADEL_COMPOUND_CANCEL_STAGE = $CancelStage
    CITADEL_COMPOUND_CANCEL_OCCURRENCE = [string]$CancelOccurrence
    CITADEL_COMPOUND_MODE = $Mode; CITADEL_COMPOUND_TARGET = $Target
    CITADEL_COMPOUND_REUSE_REFERENCE = $reusePath.Replace('\', '/')
}
$launch = [ordered]@{
    phase = $Phase; head = (& git -C $projectPath rev-parse HEAD); branch = (& git -C $projectPath branch --show-current)
    baselineRevision = $revision; gitBuilderSha256 = (Get-BytesSha $oldBytes); frozenSha256 = (Get-BytesSha $frozenBytes)
    dependencies = $dependencies; siteSha256 = $siteSha; timeoutSeconds = $TimeoutSeconds
    liveDependencies = $liveDependencies; changedDependencies = $changedDependencies; referenceSources = $referenceSources
    baselineSha256 = $baselineSha; currentSources = $currentSources; mode = $Mode
    reuseReferenceSha256 = $reuseSha
    cancelStage = $CancelStage; cancelOccurrence = $CancelOccurrence; target = $Target
    dependencyPolicy = 'Transitive literal res:// script graph plus rejection of global current-builder references; every dependency content matches Git revision (line endings normalized), disk SHA bound before/after. Exact Git dependency bytes archived.'
    runnerSha256 = (Get-FileHash -LiteralPath (Join-Path $projectPath 'scripts/testing/buildings/CitadelCompoundCancellationContract.gd')).Hash.ToLowerInvariant()
    scope = 'Source-only. No full Site rebuild, headed or navigation acceptance.'
}
$launch | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding utf8
if ($PrepareOnly) { Write-Output "Prepared reference bindings only; no Godot run or test pass: $runPath"; exit 0 }
$previous = @{}
$runnerExit = 2
$errorWatcher = $null
try {
    foreach ($key in $values.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process'); [Environment]::SetEnvironmentVariable($key, $values[$key], 'Process') }
    # Stop only this owned watchdog on unexpected engine errors. Expected failure
    # messages remain visible and their exact multiplicity is verified below.
    $errorWatcher = Start-ThreadJob -ArgumentList $runPath, $Phase -ScriptBlock {
        param($directory, $phaseName)
        $allowed = '^ERROR: Castle seed 1298433643 has missing or divergent sampler-owned palace approach authority$'
        while ($true) {
            foreach ($name in @('stdout.log', 'stderr.log')) {
                $path = Join-Path $directory $name
                if (Test-Path -LiteralPath $path) {
                    foreach ($line in [IO.File]::ReadAllLines($path)) {
                        if ($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:' -and -not ($phaseName -eq 'failure' -and $line -match $allowed)) {
                            [IO.File]::WriteAllText((Join-Path $directory 'stop-request.txt'), 'Unexpected engine error: ' + $line)
                            return
                        }
                    }
                }
            }
            Start-Sleep -Milliseconds 200
        }
    }
    & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath `
        -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' `
        -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelCompoundCancellationContract.gd') `
        -TimeoutSeconds $TimeoutSeconds -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') `
        -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
    $runnerExit = $LASTEXITCODE
    if ($runnerExit -eq 0) {
        $result = Get-Content -LiteralPath (Join-Path $runPath 'summary.json') -Raw | ConvertFrom-Json
        if ($result.complete -ne $true -or $result.passed -ne $true) { $runnerExit = 1 }
        $errorLines = @(Get-Content -LiteralPath (Join-Path $runPath 'stdout.log'), (Join-Path $runPath 'stderr.log') | Where-Object { $_ -match 'SCRIPT ERROR:|Parse Error:|ERROR:' })
        $expectedLine = 'ERROR: Castle seed 1298433643 has missing or divergent sampler-owned palace approach authority'
        $errorsPassed = if ($Phase -eq 'failure') { $errorLines.Count -eq 2 -and @($errorLines | Where-Object { $_ -cne $expectedLine }).Count -eq 0 } else { $errorLines.Count -eq 0 }
        [ordered]@{ passed = $errorsPassed; actualErrorLines = $errorLines; expectedErrorCount = $(if ($Phase -eq 'failure') { 2 } else { 0 }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runPath 'error-inventory.json') -Encoding utf8
        if (-not $errorsPassed) { $runnerExit = 1 }
    }
} finally {
    if ($null -ne $errorWatcher) { Stop-Job -Job $errorWatcher; Remove-Job -Job $errorWatcher -Force }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
}
exit $runnerExit
