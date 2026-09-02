param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runPath = [IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if (Test-Path -LiteralPath $runPath) { throw 'Run path must be fresh.' }
New-Item -ItemType Directory -Path $runPath | Out-Null
$env:VOXEL_SIGN_BOUNDS_INPUT = Join-Path $projectPath 'artifacts/citadel-runtime-integration/actual-site-shop-02/result.bin'
$env:VOXEL_SIGN_BOUNDS_FAILURE = Join-Path $projectPath 'artifacts/citadel-runtime-integration/actual-site-source-03/report.json'
$env:VOXEL_SIGN_BOUNDS_LAUNCH = Join-Path $projectPath 'artifacts/citadel-runtime-integration/actual-site-source-03/launch.json'
$env:VOXEL_SIGN_BOUNDS_REPORT = Join-Path $runPath 'report.json'
$env:VOXEL_SIGN_BOUNDS_INPUT_SHA = (Get-FileHash -LiteralPath $env:VOXEL_SIGN_BOUNDS_INPUT -Algorithm SHA256).Hash.ToLower()
$env:VOXEL_SIGN_BOUNDS_FAILURE_SHA = (Get-FileHash -LiteralPath $env:VOXEL_SIGN_BOUNDS_FAILURE -Algorithm SHA256).Hash.ToLower()
$env:VOXEL_SIGN_BOUNDS_LAUNCH_SHA = (Get-FileHash -LiteralPath $env:VOXEL_SIGN_BOUNDS_LAUNCH -Algorithm SHA256).Hash.ToLower()
$launchEvidence = Get-Content -LiteralPath (Join-Path $projectPath 'artifacts/citadel-runtime-integration/actual-site-source-03/launch.json') -Raw | ConvertFrom-Json
$env:VOXEL_SIGN_BOUNDS_RECIPE_SHA = $launchEvidence.dependencies.'res://scripts/buildings/HouseholdSignMountRecipe.gd'
$env:VOXEL_SIGN_BOUNDS_ARM = 'urban_civic_house_east_sign_arm'
$env:VOXEL_SIGN_BOUNDS_BLOCKER = 'castle_terrace_block_03_right_05'
& (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Scene '--script' -Headless -TimeoutSeconds 45 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -SceneArguments 'res://scripts/testing/buildings/CitadelSignSocketBoundsContract.gd'
exit $LASTEXITCODE
