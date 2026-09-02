param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$InputSnapshot = 'artifacts/sign-socket-investigation/raw-01/fixture.bin',
    [string]$ReferenceSnapshot = 'artifacts/citadel-runtime-integration/source-reference-01/reference.bin'
)
$ErrorActionPreference = 'Stop'
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runPath = [IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
$inputPath = [IO.Path]::GetFullPath((Join-Path $projectPath $InputSnapshot))
$referencePath = [IO.Path]::GetFullPath((Join-Path $projectPath $ReferenceSnapshot))
if (Test-Path -LiteralPath $runPath) { throw 'Run path must be fresh.' }
$inputHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLower()
$referenceHash = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash.ToLower()
New-Item -ItemType Directory -Path $runPath | Out-Null
$values = @{
    VOXEL_SIGN_PLACEMENT_INPUT = $inputPath
    VOXEL_SIGN_PLACEMENT_REFERENCE = $referencePath
    VOXEL_SIGN_PLACEMENT_REPORT = (Join-Path $runPath 'report.json')
    VOXEL_SIGN_PLACEMENT_INPUT_SHA = $inputHash
    VOXEL_SIGN_PLACEMENT_REFERENCE_SHA = $referenceHash
}
$previousValues = @{}
foreach ($key in $values.Keys) { $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
try {
    foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key, $values[$key], 'Process') }
    & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/HouseholdSignPlacementContract.gd') -TimeoutSeconds 45 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
    $runnerExit = $LASTEXITCODE
} finally {
    foreach ($key in $previousValues.Keys) { [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process') }
}
exit $runnerExit
