[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
# Ordinary main menu, isolated user data, no gameplay-changing fixture flags.
# UI input is a separate, exact-owned-window operation after inspecting a capture.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ne (Join-Path $project 'artifacts/citadel-runtime-integration')){throw 'Use a fresh citadel-runtime-integration directory.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata'),(Join-Path $run 'screenshots') | Out-Null
$prior=@{}
$watcher=$null
$watcherErrors=@()
$watcherFailed=$false
$watchdogExit=$null
$stdout=Join-Path $run 'stdout.log'
$stderr=Join-Path $run 'stderr.log'
$stop=Join-Path $run 'stop-request.txt'
try {
 foreach($entry in Get-ChildItem Env:){
  if($entry.Name -match '^(VOXEL_|CITADEL_|BUILDING_|TREE_)'){
   $prior[$entry.Name]=$entry.Value
   [Environment]::SetEnvironmentVariable($entry.Name,$null,'Process')
  }
 }
 foreach($name in @('APPDATA','LOCALAPPDATA')){
  $prior[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
  [Environment]::SetEnvironmentVariable($name,(Join-Path $run 'userdata'),'Process')
 }
 $hashes=[ordered]@{}
 foreach($path in @('project.godot','scripts/TitleMenu.gd','scripts/MainCore.gd','scripts/StructureSystem.gd','scripts/world/CitadelPublicationService.gd','scripts/world/GeneratedStructureRuntimeBindings.gd','tools/run-citadel-main-menu-diagnostic.ps1','tools/run-godot-scene-watchdog.ps1','tools/invoke-owned-game-window.ps1')){
  $hashes[$path]=(Get-FileHash -LiteralPath (Join-Path $project $path)).Hash.ToLowerInvariant()
 }
 @{head=(& git -C $project rev-parse HEAD);sourceSha256=$hashes;recordedUtc=[DateTime]::UtcNow.ToString('o');scene='res://scenes/MainMenu.tscn';headless=$false;timeoutSeconds=600;clearedEnvironmentNames=@($prior.Keys | Where-Object {$_ -notin @('APPDATA','LOCALAPPDATA')});evidenceLevel='ordinary menu diagnostic, no engine-side fixture; no acceptance inferred'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'launch.json') -Encoding utf8
 $watcher=Start-ThreadJob -ArgumentList $stdout,$stderr,$stop -ScriptBlock {
  param($outPath,$errPath,$stopPath)
  try {
   while($true){
    foreach($path in @($outPath,$errPath)){
     if(Test-Path -LiteralPath $path){
      $stream=$null; $reader=$null
      try {
       $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
       $reader=[IO.StreamReader]::new($stream)
       while(-not $reader.EndOfStream){
        $line=$reader.ReadLine()
        if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){
         [IO.File]::WriteAllText($stopPath,$line)
         return
        }
       }
      } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
     }
    }
    Start-Sleep -Milliseconds 100
   }
  } catch {[IO.File]::WriteAllText($stopPath,'Error watcher failed: '+$_.Exception.Message); throw}
 }
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Scene 'res://scenes/MainMenu.tscn' -TimeoutSeconds 600 -StdoutPath $stdout -StderrPath $stderr -SummaryPath (Join-Path $run 'watchdog.json') -StopRequestPath $stop -LiveOwnershipPath (Join-Path $run 'live-ownership.json')
 $watchdogExit=$LASTEXITCODE
} finally {
 if($null -ne $watcher){
  $watcherFailed=$watcher.State -eq 'Failed'
  Stop-Job $watcher
  Receive-Job $watcher -ErrorVariable watcherErrors -ErrorAction SilentlyContinue | Out-Null
  Remove-Job $watcher -Force
 }
 foreach($name in $prior.Keys){[Environment]::SetEnvironmentVariable($name,$prior[$name],'Process')}
}
$summaryPath=Join-Path $run 'watchdog.json'
if(-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)){throw 'Missing terminal watchdog summary.'}
$summary=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if($watchdogExit -ne 0 -or $summary.overallExitCode -ne 0 -or $summary.cleanupPassed -ne $true -or $summary.authoritativeZeroProven -ne $true){throw 'Diagnostic failed or process cleanup unproven; inspect watchdog.json and logs.'}
if($watcherFailed -or $watcherErrors.Count){throw 'Diagnostic error watcher failed.'}
if(Select-String -LiteralPath $stdout,$stderr -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:' -Quiet){throw 'Diagnostic emitted engine errors, including possible late shutdown errors.'}
if(Test-Path -LiteralPath $stop){throw 'Diagnostic received a stop request; this is not a clean run.'}
@{launcherClean=$true;ownedZero=$true;evidenceLevel='ordinary menu diagnostic; gameplay acceptance requires inspected evidence';summaryPath=$summaryPath} | ConvertTo-Json -Compress
