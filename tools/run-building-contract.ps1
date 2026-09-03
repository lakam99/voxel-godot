[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$Contract,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$ReportEnvironment,
 [switch]$OutputIsDirectory,
 [ValidateRange(1,240)][int]$TimeoutSeconds=30
)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ne (Join-Path $project 'artifacts/citadel-runtime-integration')){throw 'Use a fresh citadel-runtime-integration artifact directory.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
if($ReportEnvironment -notmatch '^[A-Z][A-Z0-9_]+$'){throw 'Invalid report variable.'}
if($Contract -match '^[A-Za-z0-9]+\.gd$'){$scriptPath='res://scripts/testing/buildings/'+$Contract}
elseif($Contract.StartsWith('res://artifacts/citadel-runtime-integration/')){
 $resolved=[IO.Path]::GetFullPath((Join-Path $project $Contract.Substring(6)))
 $allowed=(Join-Path $project 'artifacts/citadel-runtime-integration')+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($resolved) -ne '.gd'){throw 'Invalid artifact contract path.'}
 $scriptPath=$Contract
}else{throw 'Invalid contract.'}
$godot='C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe'
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$values=@{APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata')}
$values[$ReportEnvironment]=if($OutputIsDirectory){$run}else{Join-Path $run 'report.json'}
$previous=@{}
try {
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 foreach($phase in @('parse','run')) {
  $prefix=if($phase -eq 'parse'){'parse-'}else{''}
  $stdout=Join-Path $run ($prefix+'stdout.log'); $stderr=Join-Path $run ($prefix+'stderr.log')
  $stop=Join-Path $run ($prefix+'stop-request.txt'); $summary=Join-Path $run ($prefix+'watchdog.json')
  $watcher=Start-ThreadJob -ArgumentList $stdout,$stderr,$stop -ScriptBlock {
   param($outPath,$errPath,$stopPath)
   $ErrorActionPreference='Stop'
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
  try {
   $arguments=@($scriptPath)
   if($phase -eq 'parse'){$arguments+='--check-only'}
   & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe $godot -Headless -Scene '--script' -SceneArguments $arguments -TimeoutSeconds $TimeoutSeconds -StdoutPath $stdout -StderrPath $stderr -SummaryPath $summary -StopRequestPath $stop | Out-Null
  } finally {
   $watcherFailed=$watcher.State -eq 'Failed'
   Stop-Job $watcher
   $watcherErrors=@()
   Receive-Job $watcher -ErrorVariable watcherErrors -ErrorAction SilentlyContinue | Out-Null
   if($watcherFailed -or $watcherErrors.Count){
    $watcherErrors | Out-String | Set-Content -LiteralPath ($stop+'.watcher-error.txt') -Encoding utf8
   }
   Remove-Job $watcher -Force
  }
  $watch=Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
  if($watch.overallExitCode -ne 0 -or -not $watch.cleanupPassed -or -not $watch.authoritativeZeroProven){throw "$phase failed; inspect $summary"}
  if($watcherFailed -or $watcherErrors.Count -or (Test-Path -LiteralPath ($stop+'.watcher-error.txt'))){throw "$phase error watcher failed"}
  if(Select-String -LiteralPath $stdout,$stderr -Pattern 'SCRIPT ERROR:|ERROR:|WARNING:|leaked|resources still in use' -Quiet){throw "$phase emitted engine errors/warnings"}
 }
 if(-not (Test-Path -LiteralPath (Join-Path $run 'report.json'))){throw 'No completed report.'}
 [pscustomobject]@{reportPath=(Join-Path $run 'report.json');ownedZero=$true;engineLogsClean=$true}|ConvertTo-Json -Compress
} finally {
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
