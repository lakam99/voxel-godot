[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$Seed='atlas-30895044',
    [string]$CandidateRegion='',
    [ValidateRange(90,600)][int]$TimeoutSeconds=600
)
# Headed, teleport-assisted diagnostic. No user saves, source fixtures, automatic
# clicks, route commands, altered generation policies, or broad process killing.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
$artifactRoot=Join-Path $project 'artifacts/citadel-runtime-integration'
if((Split-Path $run -Parent) -ine $artifactRoot -or (Split-Path $run -Leaf) -notlike 'candidate-teleport-*'){throw 'Use a fresh candidate-teleport-* directory directly under artifacts/citadel-runtime-integration.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required; prior evidence is never overwritten.'}
if([string]::IsNullOrWhiteSpace($Seed) -or $Seed.Length -gt 128){throw 'A nonempty seed of at most 128 characters is required.'}
if($CandidateRegion -ne ''){
    if($CandidateRegion -notmatch '^-?(0|[1-9][0-9]{0,6}),-?(0|[1-9][0-9]{0,6})$'){throw 'CandidateRegion must be canonical x,z integers.'}
    foreach($coordinate in $CandidateRegion.Split(',')){
        $value=[int]$coordinate
        if([string]$value -cne $coordinate -or $value -lt -1048576 -or $value -gt 1048575){throw 'CandidateRegion is outside the supported field.'}
    }
}
# Do not inherit any project test, fast-boot, fake source, save, or performance
# environment mode. The sole seed override lives visibly in the fixture class.
$inherited=@(Get-ChildItem Env: | Where-Object { $_.Name -like 'VOXEL_*' -and -not [string]::IsNullOrEmpty($_.Value) })
if($inherited.Count){throw ('Unset inherited VOXEL_* modes before this diagnostic: '+(($inherited | Select-Object -ExpandProperty Name)-join ', '))}
$godot='C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe'
$script='res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd'
$watchdog=Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1'
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$files=@(& git -C $project ls-files -- '*.gd' '*.tscn' 'project.godot')
$files+=@('scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd','tools/run-citadel-candidate-teleport-playtest.ps1','tools/run-godot-scene-watchdog.ps1','addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll')
$files=@($files | Sort-Object -Unique)
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $project $file) -Algorithm SHA256).Hash.ToLowerInvariant()}
$arguments=@($script,'--resolution','1280x720','--windowed')
@{schema='citadel-candidate-teleport-launch/v1';projectPath=$project;head=(& git -C $project rev-parse HEAD);seed=$Seed;requestedRegion=$CandidateRegion;
    timeoutSeconds=$TimeoutSeconds;internalDeadlineSeconds=$TimeoutSeconds-45;headed=$true;scene=$script;arguments=$arguments;
    sourceHashes=$hashes;recordedUtc=[DateTime]::UtcNow.ToString('o');
    evidenceLevel='headed teleport-assisted diagnostic; not continuous travel or NPC acceptance';
    fixtureChanges=@('seed-selector-only Main subclass','two counted exterior setup teleports','physics held only for setup clearance','isolated ordinary user data')} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $run 'launch.json') -Encoding utf8
$values=@{APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata');
    CITADEL_CANDIDATE_TELEPORT_OUTPUT=$run;CITADEL_CANDIDATE_TELEPORT_SEED=$Seed;CITADEL_CANDIDATE_TELEPORT_SECONDS=[string]$TimeoutSeconds;
    CITADEL_CANDIDATE_TELEPORT_REGION=$CandidateRegion}
$previous=@{}
$stdout=Join-Path $run 'stdout.log'; $stderr=Join-Path $run 'stderr.log'; $stop=Join-Path $run 'stop-request.txt'
$summary=Join-Path $run 'watchdog.json'
try {
    foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
    # Existing watchdog owns the Windows Job from process creation. This helper
    # merely requests its stop on the first engine error; it never kills a PID.
    $watcher=Start-ThreadJob -ArgumentList $stdout,$stderr,$stop -ScriptBlock {
        param($outPath,$errPath,$stopPath)
        $ErrorActionPreference='Stop'
        $offsets=@{$outPath=0L;$errPath=0L}
        $tails=@{$outPath='';$errPath=''}
        try {
            while($true){
                foreach($path in @($outPath,$errPath)){
                    if(-not (Test-Path -LiteralPath $path)){continue}
                    $stream=$null; $reader=$null
                    try {
                        $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                        if($stream.Length -lt $offsets[$path]){throw 'Engine log shrank during execution.'}
                        [void]$stream.Seek($offsets[$path],[IO.SeekOrigin]::Begin)
                        $reader=[IO.StreamReader]::new($stream)
                        $text=$tails[$path]+$reader.ReadToEnd()
                        $offsets[$path]=$stream.Position
                        $tails[$path]=$text.Substring([Math]::Max(0,$text.Length-64))
                        if($text -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){
                            [IO.File]::WriteAllText($stopPath,'Immediate owned stop: '+$Matches[0]+' in '+$path)
                            return
                        }
                    } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
                }
                Start-Sleep -Milliseconds 100
            }
        } catch {
            [IO.File]::WriteAllText($stopPath+'.watcher-error.txt',$_.Exception.ToString())
            [IO.File]::WriteAllText($stopPath,'Error watcher failed; stop owned run.')
            throw
        }
    }
    try {
        & $watchdog -ProjectPath $project -GodotExe $godot -Scene '--script' -SceneArguments $arguments -TimeoutSeconds $TimeoutSeconds `
            -StdoutPath $stdout -StderrPath $stderr -SummaryPath $summary -StopRequestPath $stop -LiveOwnershipPath (Join-Path $run 'live-ownership.json') | Out-Null
    } finally {
        $watcherFailed=$watcher.State -eq 'Failed'
        Stop-Job $watcher
        $watcherErrors=@()
        Receive-Job $watcher -ErrorVariable watcherErrors -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $watcher -Force
    }
    $watch=Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
    $changed=@()
    foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $project $file) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$file]){$changed+=$file}}
    $errors=@(Select-String -LiteralPath $stdout,$stderr -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use')
    $reportPath=Join-Path $run 'report.json'
    $report=if(Test-Path -LiteralPath $reportPath){Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json}else{$null}
    $verification=@{naturalExit=($watch.rootExited -and -not $watch.forcedCleanup -and -not $watch.timedOut);functionalExitCode=$watch.functionalExitCode;ownedZero=$watch.authoritativeZeroProven;
        cleanupPassed=$watch.cleanupPassed;engineErrorWarningCount=$errors.Count;changedSources=$changed;reportPath=$reportPath;
        watcherFailed=($watcherFailed -or $watcherErrors.Count -gt 0 -or (Test-Path -LiteralPath ($stop+'.watcher-error.txt')));
        visualInspectionRequired=$true}
    $verification | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding utf8
    if($watch.overallExitCode -ne 0 -or -not $watch.cleanupPassed -or -not $watch.authoritativeZeroProven){throw 'Diagnostic failed or owned cleanup unresolved; retain report/log/watchdog evidence.'}
    if($verification.watcherFailed -or $errors.Count -or $changed.Count){throw 'Watcher, engine log, or frozen-source verification failed.'}
    if($null -eq $report -or -not $report.passed -or $report.seed -cne $Seed -or $report.actualSeed -cne $Seed){throw 'No successful exact-seed diagnostic report.'}
    foreach($capture in $report.captures){if(-not $capture.saved -or -not (Test-Path -LiteralPath $capture.path -PathType Leaf)){throw 'Missing reported viewport capture.'}}
    @{passed=$true;outcome=$report.outcome;setupPlacements=@($report.setupPlacements).Count;reportPath=$reportPath;ownedZero=$true;visualInspectionRequired=$true} | ConvertTo-Json -Compress
} finally {
    foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
