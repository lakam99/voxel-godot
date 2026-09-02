[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$GodotExe='C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe')
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot=Join-Path $projectRoot 'artifacts/citadel-runtime-integration'
$runPath=[IO.Path]::GetFullPath((Join-Path $projectRoot $OutputDirectory))
if((Split-Path $runPath -Parent) -ne $artifactRoot -or (Split-Path $runPath -Leaf) -notlike 'town-inputs-*'){throw 'Use a town-inputs-* artifact directory.'}
if(Test-Path -LiteralPath $runPath){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $runPath,(Join-Path $runPath 'userdata')|Out-Null
$files=@('scripts/TutorialSystem.gd','scripts/world/CitadelTerrainAdmission.gd','scripts/world/CitadelSiteBuildQueue.gd','scripts/terrain/VoxelTerrainRuntime.gd','scripts/terrain/VoxelWorldGenerationContext.gd','scripts/WorldGenerationSystem.gd','scripts/testing/buildings/CitadelTownInputsContract.gd','tools/run-citadel-town-inputs-contract.ps1')
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $projectRoot $file)).Hash.ToLowerInvariant()}
[ordered]@{schema='citadel-town-inputs-launch/v1';evidenceLevel='synthetic_startup_dependencies_real_tutorial_reservation_admission_runtime_context';sourceSha256=$hashes;timeoutSeconds=45;head=(& git -C $projectRoot rev-parse HEAD)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding utf8
$values=@{CITADEL_TOWN_INPUTS_OUTPUT=$runPath.Replace('\','/');APPDATA=(Join-Path $runPath 'userdata');LOCALAPPDATA=(Join-Path $runPath 'userdata');VOXEL_SAVE_PATH_OVERRIDE=(Join-Path $runPath 'test-save.json')}
$previous=@{};$watcher=$null;$code=2
try{
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 $watcher=Start-ThreadJob -ArgumentList $runPath -ScriptBlock {param($dir) while($true){foreach($name in @('stdout.log','stderr.log')){$p=Join-Path $dir $name;if(Test-Path $p){foreach($line in [IO.File]::ReadAllLines($p)){if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){[IO.File]::WriteAllText((Join-Path $dir 'stop-request.txt'),$line);return}}}};Start-Sleep -Milliseconds 200}}
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $projectRoot -GodotExe $GodotExe -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelTownInputsContract.gd') -TimeoutSeconds 45 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt') | Out-Null
 $code=$LASTEXITCODE
}finally{
 if($watcher){Stop-Job $watcher;Remove-Job $watcher -Force}
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
$w=Get-Content -LiteralPath (Join-Path $runPath 'watchdog.json') -Raw|ConvertFrom-Json
if($code -ne 0 -or $w.overallExitCode -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven -or $w.forcedCleanup -or $w.timedOut){throw "Contract/cleanup failed: $runPath"}
if(Select-String -LiteralPath (Join-Path $runPath 'stdout.log'),(Join-Path $runPath 'stderr.log') -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use' -Quiet){throw "Errors/warnings: $runPath"}
foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $projectRoot $file)).Hash.ToLowerInvariant() -cne $hashes[$file]){throw "Source changed during test: $file"}}
$r=Get-Content -LiteralPath (Join-Path $runPath 'report.json') -Raw|ConvertFrom-Json
if(-not $r.complete -or -not $r.passed -or $r.schema -ne 'citadel-town-inputs-contract/v1'){throw "Assertions failed: $runPath"}
[pscustomobject]@{passed=$true;checks=@($r.checks.PSObject.Properties).Count;reportPath=(Join-Path $runPath 'report.json');cleanupPassed=$w.cleanupPassed}|ConvertTo-Json -Compress
