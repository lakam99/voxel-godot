[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ne (Join-Path $project 'artifacts/citadel-runtime-integration') -or (Split-Path $run -Leaf) -notlike 'publication-preparation-*'){throw 'Use a publication-preparation-* artifact directory.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$files=@('scripts/buildings/BuildingPublicationSource.gd','scripts/buildings/BuildingPublicationPreparation.gd','scripts/buildings/BuildingPartPublisher.gd','scripts/buildings/CastleCompoundBlueprintBuilder.gd','scripts/buildings/BuildingBlueprint.gd','scripts/buildings/BuildingPart.gd','scripts/buildings/FacadeOpeningBearingRecipe.gd','scripts/buildings/FurnishingPlan.gd','scripts/buildings/FurnishingPart.gd','scripts/testing/buildings/BuildingPublicationPreparationContract.gd','tools/run-building-publication-preparation-contract.ps1')
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant()}
@{schema='building-publication-preparation-launch/v1';sourceSha256=$hashes;head=(& git -C $project rev-parse HEAD);evidenceLevel='background_preparation_contract';timeoutSeconds=120}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $run 'launch.json') -Encoding utf8
$values=@{BUILDING_PREPARATION_REPORT=(Join-Path $run 'report.json');APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata')}
$previous=@{}
try {
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/BuildingPublicationPreparationContract.gd') -TimeoutSeconds 120 -StdoutPath (Join-Path $run 'stdout.log') -StderrPath (Join-Path $run 'stderr.log') -SummaryPath (Join-Path $run 'watchdog.json') -StopRequestPath (Join-Path $run 'stop-request.txt') | Out-Null
 $code=$LASTEXITCODE
} finally {
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
$w=Get-Content -LiteralPath (Join-Path $run 'watchdog.json') -Raw|ConvertFrom-Json
if($code -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven){throw 'Source test failed or cleanup unresolved.'}
if(Select-String -LiteralPath (Join-Path $run 'stdout.log'),(Join-Path $run 'stderr.log') -Pattern 'SCRIPT ERROR:|ERROR:|WARNING:|leaked|resources still in use' -Quiet){throw 'Source test emitted engine errors/warnings.'}
foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant() -cne $hashes[$file]){throw "Source changed during test: $file"}}
$r=Get-Content -LiteralPath (Join-Path $run 'report.json') -Raw|ConvertFrom-Json
if(-not $r.passed){throw 'Source assertions failed.'}
@{passed=$true;checks=@($r.checks.PSObject.Properties).Count;reportPath=(Join-Path $run 'report.json');mainBeginUsec=$r.mainBeginUsec}|ConvertTo-Json -Compress
