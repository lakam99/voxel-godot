[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ne (Join-Path $project 'artifacts/citadel-runtime-integration') -or (Split-Path $run -Leaf) -notlike 'publication-service-*'){throw 'Use a publication-service-* artifact directory.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$files=@('scripts/world/CitadelPublicationService.gd','scripts/world/CitadelTerrainAdmission.gd','scripts/buildings/BuildingPublicationWorker.gd','scripts/buildings/BuildingPublicationPreparation.gd','scripts/StructureSystem.gd','scripts/MainCore.gd','scripts/terrain/VoxelTerrainRuntime.gd','scripts/testing/buildings/CitadelPublicationServiceContract.gd','scripts/testing/buildings/BuildingPublicationWorkerContract.gd','tools/run-citadel-publication-service-contract.ps1')
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant()}
@{schema='citadel-publication-service-launch/v1';sourceSha256=$hashes;head=(& git -C $project rev-parse HEAD);seed='atlas-1492';evidenceLevel='historical_source_direct_service_and_synthetic_lifecycle';timeoutSeconds=120}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $run 'launch.json') -Encoding utf8
$values=@{CITADEL_PUBLICATION_REPORT=(Join-Path $run 'report.json');APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata')}
$previous=@{}
try {
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelPublicationServiceContract.gd') -TimeoutSeconds 120 -StdoutPath (Join-Path $run 'stdout.log') -StderrPath (Join-Path $run 'stderr.log') -SummaryPath (Join-Path $run 'watchdog.json') -StopRequestPath (Join-Path $run 'stop-request.txt') | Out-Null
 $code=$LASTEXITCODE
} finally {
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
$w=Get-Content -LiteralPath (Join-Path $run 'watchdog.json') -Raw|ConvertFrom-Json
if($code -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven){throw 'Service test failed or cleanup unresolved.'}
if(Select-String -LiteralPath (Join-Path $run 'stdout.log'),(Join-Path $run 'stderr.log') -Pattern 'SCRIPT ERROR:|ERROR:|WARNING:|leaked|resources still in use' -Quiet){throw 'Service test emitted engine errors/warnings.'}
foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant() -cne $hashes[$file]){throw "Source changed during test: $file"}}
$r=Get-Content -LiteralPath (Join-Path $run 'report.json') -Raw|ConvertFrom-Json
if(-not $r.passed){throw 'Service assertions failed.'}
@{passed=$true;checks=@($r.checks.PSObject.Properties).Count;reportPath=(Join-Path $run 'report.json')}|ConvertTo-Json -Compress
