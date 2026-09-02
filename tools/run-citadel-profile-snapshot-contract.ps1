[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$GodotExe='C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe')
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot=Join-Path $projectRoot 'artifacts/citadel-runtime-integration'
$runPath=[IO.Path]::GetFullPath((Join-Path $projectRoot $OutputDirectory))
if((Split-Path $runPath -Parent) -ne $artifactRoot -or (Split-Path $runPath -Leaf) -notlike 'profile-snapshot-*'){throw 'Use a profile-snapshot-* artifact directory.'}
if(Test-Path -LiteralPath $runPath){throw 'Fresh output required.'}
$fixture=Join-Path $artifactRoot 'actual-site-source-05/result.bin'
$fixtureSha='7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf'
if((Get-FileHash -LiteralPath $fixture).Hash.ToLowerInvariant() -cne $fixtureSha){throw 'Actual Site fixture SHA mismatch.'}
New-Item -ItemType Directory -Path $runPath,(Join-Path $runPath 'userdata')|Out-Null
$files=@('scripts/WorldGenerationSystem.gd','scripts/TerrainVolumeService.gd','scripts/world/GeneratedSiteProfileStore.gd','scripts/world/BuildingTerrainProfile.gd','scripts/terrain/VoxelWorldGenerationContext.gd','scripts/terrain/VoxelTerrainGenerator.gd','scripts/testing/buildings/CitadelProfileSnapshotContract.gd','tools/run-citadel-profile-snapshot-contract.ps1')
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $projectRoot $file)).Hash.ToLowerInvariant()}
[ordered]@{schema='citadel-profile-snapshot-launch/v1';evidenceLevel='actual_frozen_profile_real_WGS_context_native_block_service';sourceSha256=$hashes;fixtureSha256=$fixtureSha;timeoutSeconds=45;head=(& git -C $projectRoot rev-parse HEAD)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding utf8
$values=@{CITADEL_PROFILE_OUTPUT=$runPath.Replace('\','/');APPDATA=(Join-Path $runPath 'userdata');LOCALAPPDATA=(Join-Path $runPath 'userdata');VOXEL_SAVE_PATH_OVERRIDE=(Join-Path $runPath 'test-save.json')}
$previous=@{};$watcher=$null;$code=2
try{
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 $watcher=Start-ThreadJob -ArgumentList $runPath -ScriptBlock {param($dir) while($true){foreach($name in @('stdout.log','stderr.log')){$p=Join-Path $dir $name;if(Test-Path $p){foreach($line in [IO.File]::ReadAllLines($p)){if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){[IO.File]::WriteAllText((Join-Path $dir 'stop-request.txt'),$line);return}}}};Start-Sleep -Milliseconds 200}}
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $projectRoot -GodotExe $GodotExe -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelProfileSnapshotContract.gd') -TimeoutSeconds 45 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt') | Out-Null
 $code=$LASTEXITCODE
}finally{
 if($watcher){Stop-Job $watcher;Remove-Job $watcher -Force}
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
$w=Get-Content -LiteralPath (Join-Path $runPath 'watchdog.json') -Raw|ConvertFrom-Json
$sourceStable=$true
foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $projectRoot $file)).Hash.ToLowerInvariant() -cne $hashes[$file]){$sourceStable=$false}}
$errors=@(Select-String -LiteralPath (Join-Path $runPath 'stdout.log'),(Join-Path $runPath 'stderr.log') -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use')
$r=$null
if(Test-Path -LiteralPath (Join-Path $runPath 'report.json')){$r=Get-Content -LiteralPath (Join-Path $runPath 'report.json') -Raw|ConvertFrom-Json}
[ordered]@{exitCode=$code;sourceStable=$sourceStable;errorWarningLines=$errors.Count;cleanupPassed=$w.cleanupPassed;authoritativeZeroProven=$w.authoritativeZeroProven;forcedCleanup=$w.forcedCleanup;timedOut=$w.timedOut;passed=($null -ne $r -and $r.passed);checks=if($r){@($r.checks.PSObject.Properties).Count}else{0}}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runPath 'summary.json') -Encoding utf8
Get-Content -LiteralPath (Join-Path $runPath 'summary.json') -Raw
if($code -ne 0 -or -not $sourceStable -or $errors.Count -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven -or $w.forcedCleanup -or $w.timedOut -or $null -eq $r -or -not $r.complete -or -not $r.passed){exit 1}
exit 0
