[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][ValidateSet('baseline','parity','cancellation')][string]$Phase,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$BaselineDirectory,
 [ValidateSet('houses','sites','records')][string]$Target='sites',
 [ValidateSet('omitted','empty','true')][string]$Mode='true',
 [string]$CancelStage,
 [int]$CancelOccurrence=1,
 [switch]$AuthorizeCurrent,
 [string]$ExpectedComposerSha256,
 [ValidateRange(1,90)][int]$TimeoutSeconds=90
)
$ErrorActionPreference='Stop'
$projectPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot=Join-Path $projectPath 'artifacts/citadel-runtime-integration'
$runPath=[IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if((Split-Path $runPath -Parent) -ne $artifactRoot -or (Split-Path $runPath -Leaf) -notlike 'landscape-cancellation-*'){throw 'Use an owned landscape-cancellation-* directory.'}
if(Test-Path -LiteralPath $runPath){throw 'Fresh output required.'}
if($Phase -ne 'baseline' -and -not $AuthorizeCurrent){throw 'Current API held until ready.'}
$revision='f81799da786b0a944566fa3e39cc60b69f9bded8'
$composer='scripts/buildings/CitadelUrbanPocComposer.gd'
$compoundPath=Join-Path $artifactRoot 'compound-cancellation-baseline-01/baseline.bin'
$compoundSha='12650d3e3cd9772026aaa17237511ea63535a75442aed64f5536bce3463f7ae1'
if((Get-FileHash -LiteralPath $compoundPath).Hash.ToLowerInvariant() -cne $compoundSha){throw 'Typed compound input hash changed.'}
$currentSha=(Get-FileHash -LiteralPath (Join-Path $projectPath $composer)).Hash.ToLowerInvariant()
if($ExpectedComposerSha256 -and $currentSha -cne $ExpectedComposerSha256){throw 'Current composer freeze hash changed.'}
function GitBytes([string]$relative){
 $s=[Diagnostics.ProcessStartInfo]::new('git');$s.WorkingDirectory=$projectPath;$s.UseShellExecute=$false;$s.RedirectStandardOutput=$true
 $s.ArgumentList.Add('show');$s.ArgumentList.Add("${revision}:$relative")
 $p=[Diagnostics.Process]::Start($s);$m=[IO.MemoryStream]::new();$p.StandardOutput.BaseStream.CopyTo($m);$p.WaitForExit()
 if($p.ExitCode -ne 0){throw "Git archive failed: $relative"};$b=$m.ToArray();$p.Dispose();$m.Dispose();return ,$b
}
$queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($composer)
$bytesByPath=@{};$dependencies=[ordered]@{};$gitHashes=[ordered]@{}
while($queue.Count){
 $relative=$queue.Dequeue();if($bytesByPath.ContainsKey($relative)){continue}
 $bytes=GitBytes $relative;$bytesByPath[$relative]=$bytes
 $gitHashes['res://'+$relative]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
 $source=[Text.Encoding]::UTF8.GetString($bytes)
 if($relative -ne $composer){
  $disk=Join-Path $projectPath $relative
  if([IO.File]::ReadAllText($disk).Replace("`r`n","`n") -cne $source.Replace("`r`n","`n")){throw "Unchanged literal dependency differs: $relative"}
  if($source -match 'res://scripts/buildings/CitadelUrbanPocComposer\.gd'){throw "Dependency reaches mutable composer: $relative"}
  $dependencies['res://'+$relative]=(Get-FileHash -LiteralPath $disk).Hash.ToLowerInvariant()
 }
 foreach($hit in [regex]::Matches($source,'res://([A-Za-z0-9_/.-]+\.(?:gdshader|tres|json|gd))(?![A-Za-z0-9_])')){$queue.Enqueue($hit.Groups[1].Value)}
}
New-Item -ItemType Directory -Path $runPath|Out-Null
foreach($relative in $bytesByPath.Keys){$p=Join-Path $runPath ('git/'+$relative+'.txt');[IO.Directory]::CreateDirectory((Split-Path $p -Parent))|Out-Null;[IO.File]::WriteAllBytes($p,$bytesByPath[$relative])}
$old=[regex]::Replace([Text.Encoding]::UTF8.GetString($bytesByPath[$composer]),'(?m)^class_name CitadelUrbanPocComposer\r?\n','')
$houseLine="`tadd_perimeter_neighborhoods(blueprint, grammar, keep_front_z, foundation_height, variation)"
$treeLine="`tvar selected_tree_sites := select_open_paving_tree_sites(blueprint, seed)"
if(([regex]::Matches($old,[regex]::Escape($houseLine))).Count -ne 1 -or ([regex]::Matches($old,[regex]::Escape($treeLine))).Count -ne 1){throw 'Exact capture markers changed.'}
$capture=$old.Replace($houseLine,"`thandoff[`"houseInput`"] = {`"blueprint`":blueprint.snapshot(),`"grammar`":grammar.duplicate(true),`"keepFrontZ`":keep_front_z,`"baseY`":foundation_height,`"variation`":variation}`n"+$houseLine+"`n`thandoff[`"houseOutput`"] = blueprint.snapshot()")
$treeOffset=$capture.IndexOf($treeLine)
$nextMethod=$capture.IndexOf("`nstatic func ",$treeOffset)
if($nextMethod -lt 0){throw 'Missing next method after composer capture.'}
$capture=$capture.Substring(0,$treeOffset)+"`thandoff[`"treeInput`"] = blueprint.snapshot()`n`treturn blueprint`n`n"+$capture.Substring($nextMethod)
$archiveHashes=[ordered]@{}
foreach($item in @(@('FrozenComposer.gd',$old),@('CaptureComposer.gd',$capture))){$p=Join-Path $runPath $item[0];[IO.File]::WriteAllText($p,$item[1],[Text.UTF8Encoding]::new($false));$archiveHashes[$p.Replace('\','/')]=(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant()}
$baselinePath='';$baselineSha=''
if($Phase -ne 'baseline'){
 $baselinePath=[IO.Path]::GetFullPath((Join-Path $projectPath $BaselineDirectory))
 if((Split-Path $baselinePath -Parent) -ne $artifactRoot -or (Split-Path $baselinePath -Leaf) -notlike 'landscape-cancellation-*'){throw 'Baseline outside owned artifacts.'}
 $r=Get-Content (Join-Path $baselinePath 'report.json') -Raw|ConvertFrom-Json;$w=Get-Content (Join-Path $baselinePath 'watchdog.json') -Raw|ConvertFrom-Json
 $baselineSha=(Get-FileHash (Join-Path $baselinePath 'baseline.bin')).Hash.ToLowerInvariant()
 if(-not $r.complete -or -not $r.passed -or $r.baselineSha256 -cne $baselineSha -or -not $w.cleanupPassed -or $w.overallExitCode -ne 0){throw 'Baseline integrity/cleanup failed.'}
}
$values=@{LANDSCAPE_PHASE=$Phase;LANDSCAPE_OUTPUT=$runPath.Replace('\','/');LANDSCAPE_BASELINE=$baselinePath.Replace('\','/');LANDSCAPE_TARGET=$Target;LANDSCAPE_MODE=$Mode;LANDSCAPE_CANCEL_STAGE=$CancelStage;LANDSCAPE_CANCEL_OCCURRENCE=[string]$CancelOccurrence}
[ordered]@{phase=$Phase;revision=$revision;head=(& git -C $projectPath rev-parse HEAD);dependencies=$dependencies;gitHashes=$gitHashes;archives=$archiveHashes;compoundSha256=$compoundSha;baselineSha256=$baselineSha;currentComposerSha256=$currentSha;timeoutSeconds=$TimeoutSeconds;capturePolicy='Full Git composer class_name removed; capture house input/output around original house call; original compose prefix stops immediately before tree selector after bunting. Later Source stages never execute.';dependencyPolicy='Recursive literal .gd/.tres/.gdshader/.json graph, exact Git bytes archived; live shared dependencies hash bound before/after.';testSha256=(Get-FileHash (Join-Path $projectPath 'scripts/testing/buildings/CitadelLandscapeCancellationContract.gd')).Hash.ToLowerInvariant()}|ConvertTo-Json -Depth 15|Set-Content (Join-Path $runPath 'launch.json') -Encoding utf8
[IO.File]::Copy((Join-Path $projectPath 'scripts/testing/buildings/CitadelLandscapeCancellationContract.gd'),(Join-Path $runPath 'contract.gd.txt'),$false)
$previous=@{};$watcher=$null;$runnerExit=2
try{
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 $watcher=Start-ThreadJob -ArgumentList $runPath -ScriptBlock {param($dir) while($true){foreach($name in @('stdout.log','stderr.log')){$p=Join-Path $dir $name;if(Test-Path $p){foreach($line in [IO.File]::ReadAllLines($p)){if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){[IO.File]::WriteAllText((Join-Path $dir 'stop-request.txt'),$line);return}}}};Start-Sleep -Milliseconds 200}}
 & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelLandscapeCancellationContract.gd') -TimeoutSeconds $TimeoutSeconds -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
 $runnerExit=$LASTEXITCODE
 if($runnerExit -eq 0){$r=Get-Content (Join-Path $runPath 'summary.json') -Raw|ConvertFrom-Json;if(-not $r.passed -or -not $r.complete){$runnerExit=1};if(Select-String -LiteralPath (Join-Path $runPath 'stdout.log'),(Join-Path $runPath 'stderr.log') -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:' -Quiet){$runnerExit=1}}
}finally{if($watcher){Stop-Job $watcher;Remove-Job $watcher -Force};foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}}
exit $runnerExit
