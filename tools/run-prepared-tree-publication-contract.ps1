param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stageRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $stageRoot) { throw 'Use a fresh output directory.' }
New-Item -ItemType Directory -Path $stageRoot, (Join-Path $stageRoot 'userdata') | Out-Null
$reportPath = Join-Path $stageRoot 'report.json'
$environmentValues = @{
    APPDATA = Join-Path $stageRoot 'userdata'
    LOCALAPPDATA = Join-Path $stageRoot 'userdata'
    VOXEL_SAVE_PATH_OVERRIDE = Join-Path $stageRoot 'test-save.json'
    VOXEL_PREPARED_TREE_CONTRACT_REPORT = $reportPath
}
$previousValues = @{}
try {
    foreach ($key in $environmentValues.Keys) {
        $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $environmentValues[$key], 'Process')
    }
    & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') `
        -ProjectPath $projectRoot -GodotExe $GodotExe -Headless -Scene '--script' `
        -SceneArguments @('res://scripts/testing/trees/PreparedTreePublicationContract.gd') `
        -TimeoutSeconds 180 -StdoutPath (Join-Path $stageRoot 'stdout.log') `
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
    throw "Contract or owned-process cleanup failed: $stageRoot"
}
$report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
if (-not $report.passed -or -not $report.complete) { throw "Incomplete or failing contract: $reportPath" }
if (Select-String -LiteralPath (Join-Path $stageRoot 'stderr.log') -Pattern '^(SCRIPT ERROR|ERROR):' -Quiet) {
    throw 'Engine errors remain despite contract booleans; inspect stderr.'
}
[pscustomobject]@{ passed = $report.passed; checks = $report.checks.Count; reportPath = $reportPath; cleanupPassed = $watchdog.cleanupPassed } | ConvertTo-Json
