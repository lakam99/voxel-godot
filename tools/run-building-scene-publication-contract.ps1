[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[ValidateSet('facade','actual')][string]$Phase='actual')
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ne (Join-Path $project 'artifacts/citadel-runtime-integration') -or (Split-Path $run -Leaf) -notlike 'scene-publication-*'){throw 'Use a scene-publication-* artifact directory.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$files=@('scripts/buildings/BuildingPartPublisher.gd','scripts/buildings/FurnishingPublisher.gd','scripts/buildings/BuildingPublicationPreparation.gd','scripts/buildings/BuildingPublicationWorker.gd','scripts/MainPlaytestTools.gd','scripts/environment/TreePublicationQueue.gd','scripts/testing/buildings/BuildingScenePublicationContract.gd','tools/run-building-scene-publication-contract.ps1')
$files+=@('scripts/buildings/BuildingStaticBatchFlush.gd','scripts/buildings/BuildingMeshBatchUpload.gd','scripts/buildings/BuildingPavingPublication.gd','scripts/buildings/SettledCobbleGeometry.gd')
$files+=@('scripts/buildings/BuildingMasonryPublication.gd','scripts/buildings/MasonryDescriptorGeometry.gd','scripts/buildings/MasonryAperturePublication.gd')
$files+='scripts/buildings/BuildingRoofPublication.gd'
if($Phase -eq 'actual'){$files+='scripts/buildings/BuildingScenePublicationJob.gd'}
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant()}
$timeout=if($Phase -eq 'actual'){240}else{30}
@{schema='building-scene-publication-launch/v1';sourceSha256=$hashes;head=(& git -C $project rev-parse HEAD);phase=$Phase;seed='atlas-1492';timeoutSeconds=$timeout;headed=$false}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $run 'launch.json') -Encoding utf8
$values=@{BUILDING_SCENE_OUTPUT=$run;BUILDING_SCENE_PHASE=$Phase;APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata');VOXEL_SAVE_PATH_OVERRIDE=(Join-Path $run 'test-save.json')}
$previous=@{};$watcher=$null;$code=2
try {
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 $watcher=Start-ThreadJob -ArgumentList $run -ScriptBlock {
  param($dir)
  $ErrorActionPreference='Stop'
  $stopPath=Join-Path $dir 'stop-request.txt'
  try {
   while($true){
    foreach($name in @('stdout.log','stderr.log')){
     $path=Join-Path $dir $name
     if(Test-Path -LiteralPath $path){
      $stream=$null; $reader=$null
      try {
       $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
       $reader=[IO.StreamReader]::new($stream)
       while(-not $reader.EndOfStream){
        $line=$reader.ReadLine()
        if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){[IO.File]::WriteAllText($stopPath,$line);return}
       }
      } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
     }
    }
    Start-Sleep -Milliseconds 100
   }
  } catch {
   $message='Error watcher failed: '+$_.Exception.ToString()
   [IO.File]::WriteAllText($stopPath+'.watcher-error.txt',$message)
   [IO.File]::WriteAllText($stopPath,$message)
   throw
  }
 }
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/BuildingScenePublicationContract.gd') -TimeoutSeconds $timeout -StdoutPath (Join-Path $run 'stdout.log') -StderrPath (Join-Path $run 'stderr.log') -SummaryPath (Join-Path $run 'watchdog.json') -StopRequestPath (Join-Path $run 'stop-request.txt') | Out-Null
 $code=$LASTEXITCODE
} finally {
 if($watcher){
  $watcherFailed=$watcher.State -eq 'Failed'
  Stop-Job $watcher
  $watcherErrors=@()
  Receive-Job $watcher -ErrorVariable watcherErrors -ErrorAction SilentlyContinue | Out-Null
  if($watcherFailed -or $watcherErrors.Count){$watcherErrors | Out-String | Set-Content -LiteralPath (Join-Path $run 'watcher-error.txt') -Encoding utf8}
  Remove-Job $watcher -Force
 }
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
$w=Get-Content -LiteralPath (Join-Path $run 'watchdog.json') -Raw|ConvertFrom-Json
if($code -ne 0 -or $w.overallExitCode -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven){throw 'Scene test failed or cleanup unresolved.'}
if($watcherFailed -or $watcherErrors.Count -or (Test-Path -LiteralPath (Join-Path $run 'stop-request.txt.watcher-error.txt'))){throw 'Scene error watcher failed.'}
if(Select-String -LiteralPath (Join-Path $run 'stdout.log'),(Join-Path $run 'stderr.log') -Pattern 'SCRIPT ERROR:|ERROR:|WARNING:|leaked|resources still in use' -Quiet){throw 'Scene test emitted engine errors/warnings.'}
foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant() -cne $hashes[$file]){throw "Source changed during test: $file"}}
$r=Get-Content -LiteralPath (Join-Path $run 'report.json') -Raw|ConvertFrom-Json
if(-not $r.complete -or -not $r.passed){throw 'Scene assertions failed.'}
@{passed=$true;checks=@($r.checks.PSObject.Properties).Count;reportPath=(Join-Path $run 'report.json')}|ConvertTo-Json -Compress
