param(
    [Parameter(Mandatory=$true)][ValidateSet('final_old','final_new','initial','blocked')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$FinalSnapshot='artifacts/citadel-runtime-integration/final-structural-source-01/result.bin',
    [string]$ReferenceSnapshot='artifacts/citadel-runtime-integration/source-reference-01/reference.bin'
)
$ErrorActionPreference='Stop'
$projectPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runPath=[IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if (Test-Path -LiteralPath $runPath) { throw 'Fresh run path required.' }
$finalPath=[IO.Path]::GetFullPath((Join-Path $projectPath $FinalSnapshot))
$referencePath=[IO.Path]::GetFullPath((Join-Path $projectPath $ReferenceSnapshot))
$values=@{
    SIGN_COMPLETION_FINAL=$finalPath
    SIGN_COMPLETION_REFERENCE=$referencePath
    SIGN_COMPLETION_FINAL_SHA=(Get-FileHash -LiteralPath $finalPath).Hash.ToLower()
    SIGN_COMPLETION_REFERENCE_SHA=(Get-FileHash -LiteralPath $referencePath).Hash.ToLower()
    SIGN_COMPLETION_PHASE=$Phase
    SIGN_COMPLETION_REPORT=(Join-Path $runPath 'report.json')
}
$previousValues=@{}
foreach ($key in $values.Keys) { $previousValues[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
New-Item -ItemType Directory -Path $runPath | Out-Null
try {
    foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key,$values[$key],'Process') }
    & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelSignCompletionContract.gd') -TimeoutSeconds 45 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
    $runnerExit=$LASTEXITCODE
} finally {
    foreach ($key in $previousValues.Keys) { [Environment]::SetEnvironmentVariable($key,$previousValues[$key],'Process') }
}
exit $runnerExit
