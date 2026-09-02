param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runPath = [IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if (Test-Path -LiteralPath $runPath) { throw 'Run path must be fresh.' }
New-Item -ItemType Directory -Path $runPath | Out-Null
$env:RETAINED_BEARING_REPORT = Join-Path $runPath 'report.json'
& (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/RetainedSurfaceBearingRecipeContract.gd') -TimeoutSeconds 45 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
exit $LASTEXITCODE
