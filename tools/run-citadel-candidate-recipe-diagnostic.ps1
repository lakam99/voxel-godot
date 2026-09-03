[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[switch]$CaptureBlueprint,[switch]$ExpectReady,[switch]$CaptureFailure,
 [string]$Seed='atlas-30895044',[string]$CandidateRegion='0,-1',[ValidateRange(0,2147483647)][int]$ExpectedRecipeSeed=1747969299)
$ErrorActionPreference='Stop'
if($CaptureBlueprint -and $ExpectReady){throw 'ExpectReady requires public Recipe entry; cannot combine with CaptureBlueprint.'}
if($CaptureFailure -and ($ExpectReady -or $CaptureBlueprint)){throw 'CaptureFailure requires only public failure replay.'}
if([string]::IsNullOrWhiteSpace($Seed) -or $Seed.Length -gt 128){throw 'Invalid diagnostic seed.'}
if($CandidateRegion -notmatch '^-?(0|[1-9][0-9]{0,6}),-?(0|[1-9][0-9]{0,6})$'){throw 'Invalid diagnostic region.'}
$regionCoordinates=@($CandidateRegion.Split(',') | ForEach-Object {
 $coordinate=[int]$_
 if([string]$coordinate -cne $_ -or $coordinate -lt -1048576 -or $coordinate -gt 1048575){throw 'Invalid diagnostic region.'}
 $coordinate
})
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ine (Join-Path $project 'artifacts/citadel-runtime-integration') -or (Split-Path $run -Leaf) -notlike 'candidate-recipe-*'){throw 'Use fresh candidate-recipe-* artifacts.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$expected='ERROR: Citadel structural completion failed: facade_completion_failed'
if($ExpectReady -or $CaptureBlueprint){$expected=''}
$runSeconds=if($ExpectReady -or $CaptureFailure -or $CaptureBlueprint){540}else{180}
$sourceSeconds=if($ExpectReady -or $CaptureFailure -or $CaptureBlueprint){450}else{150}
$proofSeconds=if($ExpectReady){60}else{0}
# CaptureBlueprint shares the existing bounded source measurement ceiling;
# it exports only a failed caller and never runs independent physical proof.
$script='res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd'
$files=@(& git -C $project ls-files --cached --others --exclude-standard -- 'scripts/*.gd' 'scripts/**/*.gd')
$files+=@('scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd','tools/run-citadel-candidate-recipe-diagnostic.ps1','tools/run-godot-scene-watchdog.ps1')
$hashes=[ordered]@{}
foreach($file in @($files|Sort-Object -Unique)){$hashes[$file]=(Get-FileHash (Join-Path $project $file)).Hash.ToLowerInvariant()}
@{schema='candidate-recipe-diagnostic-launch/v1';sourceHashes=$hashes;head=(& git -C $project rev-parse HEAD);seed=$Seed;region=$regionCoordinates;recipeSeed=$ExpectedRecipeSeed;expectedError=$expected;runTimeoutSeconds=$runSeconds;sourcePreparationDeadlineSeconds=$sourceSeconds;independentPhysicalDeadlineSeconds=$proofSeconds;parseTimeoutSeconds=15;cleanupCeilingPerPhaseSeconds=15;maximumOwnedPhasesSeconds=($runSeconds+49);budgetScope='Source clock includes setup/survey and Recipe. CaptureFailure retains an inventoried failure; CaptureBlueprint retains the failed typed Composer caller. Both use the existing 450s source ceiling for measurement only, never recipe success. ExpectReady alone runs independent proof with a fresh 60s deadline after successful in-time Recipe. Export/report bounded by overall watchdog. No production or headed timeout changes.';script=$script}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $run 'launch.json') -Encoding utf8
$values=@{APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata');CITADEL_CANDIDATE_RECIPE_OUTPUT=$run}
$values['CITADEL_CANDIDATE_CAPTURE_BLUEPRINT']=if($CaptureBlueprint){'1'}else{'0'}
$values['CITADEL_CANDIDATE_EXPECT_READY']=if($ExpectReady){'1'}else{'0'}
$values['CITADEL_CANDIDATE_CAPTURE_FAILURE']=if($CaptureFailure){'1'}else{'0'}
$values['CITADEL_CANDIDATE_RECIPE_SEED']=$Seed
$values['CITADEL_CANDIDATE_RECIPE_REGION']=$CandidateRegion
$values['CITADEL_CANDIDATE_RECIPE_EXPECTED']=[string]$ExpectedRecipeSeed
@{captureBlueprint=[bool]$CaptureBlueprint;expectReady=[bool]$ExpectReady;captureFailure=[bool]$CaptureFailure;sequence=if($CaptureBlueprint){'diagnostic old-equivalent Builder -> Urban.compose_prepared; not public Recipe or success'}else{'public CitadelRecipePreparation.prepare'}}|ConvertTo-Json|Set-Content (Join-Path $run 'variant.json') -Encoding utf8
$previous=@{}
try {
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 foreach($phase in @('parse','run')){
  $prefix=if($phase -eq 'parse'){'parse-'}else{''}
  $out=Join-Path $run ($prefix+'stdout.log');$err=Join-Path $run ($prefix+'stderr.log');$stop=Join-Path $run ($prefix+'stop-request.txt');$summary=Join-Path $run ($prefix+'watchdog.json')
  $allowed=if($phase -eq 'run'){$expected}else{''}
  $watcher=Start-ThreadJob -ArgumentList $out,$err,$stop,$allowed -ScriptBlock {
   param($outPath,$errPath,$stopPath,$allowedLine)
   try {
    while($true){
     # Logs are reread from the start: count once per complete scan, not once
     # per poll. Even an inventoried header may occur only once across logs.
     $allowedCount=0
     foreach($path in @($outPath,$errPath)){
      if(-not (Test-Path -LiteralPath $path)){continue}
      $stream=$null;$reader=$null
      try {
       $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$reader=[IO.StreamReader]::new($stream)
       while(-not $reader.EndOfStream){
        $line=$reader.ReadLine()
        if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:'){
         if($allowedLine -ne '' -and $line.Trim() -ceq $allowedLine){
          $allowedCount++
          if($allowedCount -gt 1){[IO.File]::WriteAllText($stopPath,'Repeated inventoried engine error: '+$line);return}
         }else{[IO.File]::WriteAllText($stopPath,$line);return}
        }
       }
      } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
     }
     Start-Sleep -Milliseconds 100
    }
   } catch {[IO.File]::WriteAllText($stopPath+'.watcher-error.txt',$_.Exception.ToString());[IO.File]::WriteAllText($stopPath,'watcher failure');throw}
  }
  try {
   $arguments=@($script);$seconds=$runSeconds
   if($phase -eq 'parse'){$arguments+='--check-only';$seconds=15}
   & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments $arguments -TimeoutSeconds $seconds -FinalCleanupTimeoutMilliseconds 15000 -StdoutPath $out -StderrPath $err -SummaryPath $summary -StopRequestPath $stop | Out-Null
  } finally {
   $watcherFailed=$watcher.State -eq 'Failed';Stop-Job $watcher;$watcherErrors=@();Receive-Job $watcher -ErrorVariable watcherErrors -ErrorAction SilentlyContinue|Out-Null;Remove-Job $watcher -Force
  }
  $w=Get-Content $summary -Raw|ConvertFrom-Json
  if($w.overallExitCode -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven -or $watcherFailed -or $watcherErrors.Count -or (Test-Path ($stop+'.watcher-error.txt'))){throw "$phase failed; retain $summary and logs"}
  $errorLines=@(Select-String -LiteralPath $out,$err -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use'|ForEach-Object {$_.Line.Trim()})
  if(@($errorLines|Where-Object {$_ -cne $allowed}).Count){throw 'Unexpected engine error/warning.'}
  if($phase -eq 'run' -and -not $ExpectReady -and -not $CaptureBlueprint -and $errorLines.Count -ne 1){throw 'Expected exactly one inventoried Composer error.'}
 }
 $changed=@($hashes.Keys|Where-Object {(Get-FileHash (Join-Path $project $_)).Hash.ToLowerInvariant() -cne $hashes[$_]})
 $report=Get-Content (Join-Path $run 'report.json') -Raw|ConvertFrom-Json
 $verified=$changed.Count -eq 0 -and $report.diagnosticCompleted -and $report.expectedFailureReproduced -and -not $report.passed
 $recipePassed=$false;$payloadPath=Join-Path $run 'failure.json';$expectedErrors=@($expected)
 if($CaptureBlueprint){
  $payloadPath=Join-Path $run 'caller-blueprint.bin';$expectedErrors=@()
  $verified=$changed.Count -eq 0 -and $report.diagnosticCompleted -and $report.captureCompleted -and -not $report.recipePassed -and -not $report.passed -and $report.receipt.contextUnchanged -and $report.receipt.sourceWithinDeadline -and (Test-Path -LiteralPath $payloadPath)
 }
 if($ExpectReady){
  $recipePassed=$report.recipePassed -eq $true;$payloadPath=Join-Path $run 'source.bin';$expectedErrors=@()
  $verified=$changed.Count -eq 0 -and $report.diagnosticCompleted -and $recipePassed -and $report.passed -and $report.receipt.physicalPassed -and $report.receipt.physicalViolationCount -eq 0 -and $report.receipt.contextUnchanged -and (Test-Path -LiteralPath $payloadPath)
 }
 @{diagnosticVerified=$verified;recipePassed=$recipePassed;expectedErrors=$expectedErrors;unexpectedErrors=@();changedSources=$changed;ownedZero=$true;payloadPath=$payloadPath}|ConvertTo-Json -Depth 3|Set-Content (Join-Path $run 'verification.json') -Encoding utf8
 if(-not $verified){throw 'Diagnostic identity or expected failure mismatch.'}
 @{diagnosticVerified=$true;recipePassed=$recipePassed;reportPath=(Join-Path $run 'report.json');payloadPath=$payloadPath;ownedZero=$true}|ConvertTo-Json -Compress
} finally {
 try {
  # Independent evidence even when parsing, the error watcher, or the recipe
  # fails. This does not turn a failed run/cleanup into a successful run.
  $finalHashes=[ordered]@{};$auditChanges=@();$auditErrors=@()
  foreach($file in $hashes.Keys){
   try {
    $actualHash=(Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant()
    $finalHashes[$file]=$actualHash
    if($actualHash -cne $hashes[$file]){$auditChanges+=@{path=$file;expected=$hashes[$file];actual=$actualHash}}
   } catch {$auditErrors+=@{path=$file;error=$_.Exception.Message}}
  }
  @{schema='candidate-recipe-final-source-audit/v1';observedAtUtc=[DateTime]::UtcNow.ToString('o');launchPath=(Join-Path $run 'launch.json');sourceCount=$hashes.Count;unchanged=($auditChanges.Count -eq 0 -and $auditErrors.Count -eq 0);changedSources=$auditChanges;readErrors=$auditErrors;finalSourceHashes=$finalHashes;scope='Source identity only; independent of recipe, watchdog, and cleanup pass/failure.'}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $run 'source-hash-audit.json') -Encoding utf8
 } finally {foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}}
}
