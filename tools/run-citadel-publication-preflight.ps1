[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$GodotExe='C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe')
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot=Join-Path $projectRoot 'artifacts/citadel-runtime-integration'
$runPath=[IO.Path]::GetFullPath((Join-Path $projectRoot $OutputDirectory))
if((Split-Path $runPath -Parent) -ne $artifactRoot -or (Split-Path $runPath -Leaf) -notlike 'publication-preflight-*'){throw 'Use a publication-preflight-* artifact directory.'}
if(Test-Path -LiteralPath $runPath){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $runPath,(Join-Path $runPath 'userdata')|Out-Null
$files=@('scripts/buildings/BuildingPartPublisher.gd','scripts/buildings/BuildingBlueprint.gd','scripts/buildings/FacadeOpeningBearingRecipe.gd','scripts/buildings/FurnishingPlan.gd','scripts/buildings/FurnishingPart.gd','scripts/buildings/SurfaceHistoryField.gd','scripts/buildings/MasonryAperturePublication.gd','scripts/buildings/PavingFootingAssemblyRecipe.gd','scripts/buildings/CastleCompoundBlueprintBuilder.gd','scripts/testing/buildings/CitadelPublicationPreflight.gd','tools/run-citadel-publication-preflight.ps1')
$fixture=Join-Path $projectRoot 'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'
if((Get-FileHash -LiteralPath $fixture).Hash.ToLowerInvariant() -cne '7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf'){throw 'Fixture SHA mismatch.'}
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $projectRoot $file)).Hash.ToLowerInvariant()}
[ordered]@{schema='citadel-publication-preflight-launch/v1';evidenceLevel='historical_actual_source_worker_restore_main_begin';sourceSha256=$hashes;timeoutSeconds=450;head=(& git -C $projectRoot rev-parse HEAD)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding utf8
$values=@{CITADEL_PUBLICATION_PREFLIGHT_OUTPUT=$runPath.Replace('\','/');APPDATA=(Join-Path $runPath 'userdata');LOCALAPPDATA=(Join-Path $runPath 'userdata');VOXEL_SAVE_PATH_OVERRIDE=(Join-Path $runPath 'test-save.json')}
$previous=@{};$watcher=$null;$code=2
try{
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 $watcher=Start-ThreadJob -ArgumentList $runPath -ScriptBlock {param($dir) while($true){foreach($name in @('stdout.log','stderr.log')){$p=Join-Path $dir $name;if(Test-Path $p){foreach($line in [IO.File]::ReadAllLines($p)){if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){[IO.File]::WriteAllText((Join-Path $dir 'stop-request.txt'),$line);return}}}};Start-Sleep -Milliseconds 200}}
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $projectRoot -GodotExe $GodotExe -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelPublicationPreflight.gd') -TimeoutSeconds 450 -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt') | Out-Null
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
if(-not $r.complete -or -not $r.passed -or $r.schema -ne 'citadel-publication-preflight/v1'){throw "Assertions failed: $runPath"}
[pscustomobject]@{passed=$true;checks=@($r.checks.PSObject.Properties).Count;reportPath=(Join-Path $runPath 'report.json');cleanupPassed=$w.cleanupPassed}|ConvertTo-Json -Compress
