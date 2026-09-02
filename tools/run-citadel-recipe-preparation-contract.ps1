param(
    [Parameter(Mandatory = $true)][ValidateSet('reference', 'fixture', 'worker')][string]$Phase,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ReferenceDirectory = '',
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stageRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $stageRoot) { throw 'Each phase requires a fresh output directory.' }
$referenceHash = ''
if ($Phase -eq 'reference') {
    $referencePath = Join-Path $stageRoot 'reference.bin'
} else {
    if ($ReferenceDirectory -eq '') { throw 'A completed reference phase is required.' }
    $referenceRoot = (Resolve-Path -LiteralPath $ReferenceDirectory).Path
    $referenceReport = Get-Content -Raw -LiteralPath (Join-Path $referenceRoot 'report.json') | ConvertFrom-Json
    $referenceWatchdog = Get-Content -Raw -LiteralPath (Join-Path $referenceRoot 'watchdog.json') | ConvertFrom-Json
    if (-not $referenceReport.passed -or -not $referenceReport.complete -or
        -not $referenceReport.referenceSnapshotComplete -or $referenceReport.phase -ne 'reference' -or
        -not $referenceWatchdog.cleanupPassed -or $referenceWatchdog.overallExitCode -ne 0) {
        throw 'Reference phase has not completed successfully with clean owned-process exit.'
    }
    $referencePath = Join-Path $referenceRoot 'reference.bin'
    $referenceHash = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($referenceHash -ne $referenceReport.referenceSha256) { throw 'Reference artifact hash mismatch.' }
    if (Select-String -LiteralPath (Join-Path $referenceRoot 'stderr.log') -Pattern '^(SCRIPT ERROR|ERROR):' -Quiet) {
        throw 'Reference phase logged engine errors; it cannot admit consumers.'
    }
}
New-Item -ItemType Directory -Path $stageRoot, (Join-Path $stageRoot 'userdata') | Out-Null
$reportPath = Join-Path $stageRoot 'report.json'
$environmentValues = @{
    APPDATA = Join-Path $stageRoot 'userdata'
    LOCALAPPDATA = Join-Path $stageRoot 'userdata'
    VOXEL_SAVE_PATH_OVERRIDE = Join-Path $stageRoot 'test-save.json'
    VOXEL_CITADEL_RECIPE_PREPARATION_REPORT = $reportPath
    VOXEL_CITADEL_RECIPE_PREPARATION_PHASE = $Phase
    VOXEL_CITADEL_RECIPE_REFERENCE = $referencePath
    VOXEL_CITADEL_RECIPE_REFERENCE_SHA256 = $referenceHash
}
$previousValues = @{}
$timeout = if ($Phase -eq 'worker') { 900 } else { 450 }
try {
    foreach ($key in $environmentValues.Keys) {
        $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $environmentValues[$key], 'Process')
    }
    & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') `
        -ProjectPath $projectRoot -GodotExe $GodotExe -Headless -Scene '--script' `
        -SceneArguments @('res://scripts/testing/buildings/CitadelRecipePreparationContract.gd') `
        -TimeoutSeconds $timeout -StdoutPath (Join-Path $stageRoot 'stdout.log') `
        -StderrPath (Join-Path $stageRoot 'stderr.log') -SummaryPath (Join-Path $stageRoot 'watchdog.json') `
        -StopRequestPath (Join-Path $stageRoot 'stop-request.txt') | Out-Null
    $stageExit = $LASTEXITCODE
} finally {
    foreach ($key in $previousValues.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process')
    }
}
$watchdog = Get-Content -Raw -LiteralPath (Join-Path $stageRoot 'watchdog.json') | ConvertFrom-Json
if ($stageExit -ne 0 -or -not $watchdog.cleanupPassed -or $watchdog.overallExitCode -ne 0) {
    throw "Phase $Phase failed; retained logs and cleanup evidence in $stageRoot"
}
$report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
$evidenceComplete = if ($Phase -eq 'reference') { $report.referenceSnapshotComplete } else { $report.fullArtifactsCompared }
if (-not $report.passed -or -not $report.complete -or -not $evidenceComplete -or $report.phase -ne $Phase) {
    throw "Phase $Phase has incomplete or failed source evidence: $reportPath"
}
if ($Phase -ne 'reference' -and $report.referenceSha256 -ne $referenceHash) { throw 'Consumer reference binding mismatch.' }
if (Select-String -LiteralPath (Join-Path $stageRoot 'stderr.log') -Pattern '^(SCRIPT ERROR|ERROR):' -Quiet) {
    throw 'Engine errors remain despite test booleans; inspect stderr.'
}
[pscustomobject]@{ phase = $Phase; passed = $report.passed; elapsedSeconds = $report.elapsedUsec / 1000000.0; referenceSha256 = $report.referenceSha256; reportPath = $reportPath } | ConvertTo-Json
