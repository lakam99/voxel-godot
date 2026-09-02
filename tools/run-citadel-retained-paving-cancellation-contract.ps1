[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('baseline','success','cancellation','synthetic')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$BaselineDirectory,
    [ValidateSet('adapter','helper')][string]$Target='adapter',
    [ValidateSet('omitted','empty','true')][string]$Mode='true',
    [string]$CancelStage,
    [string]$ArmStage,
    [ValidateRange(1,1000000)][int]$CancelOccurrence=1,
    [switch]$AuthorizeCurrent,
    [string]$ExpectedHelperSha256,
    [string]$ExpectedComposerSha256,
    [ValidateRange(1,90)][int]$TimeoutSeconds=90
)
$ErrorActionPreference='Stop'
$projectPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot=Join-Path $projectPath 'artifacts/citadel-runtime-integration'
$runPath=[IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if((Split-Path $runPath -Parent) -ne $artifactRoot -or (Split-Path $runPath -Leaf) -notlike 'retained-cancellation-*'){throw 'Use a fresh owned retained-cancellation-* directory.'}
if(Test-Path -LiteralPath $runPath){throw 'Output must be fresh.'}
if($Phase -ne 'baseline' -and -not $AuthorizeCurrent){throw 'Current API runs held until main freezes interfaces.'}
$revision='d9cb0ce068b2cecab09889486678953834a568af'
$helper='scripts/buildings/RetainedSurfaceBearingRecipe.gd'
$composer='scripts/buildings/CitadelUrbanPocComposer.gd'
if($ExpectedHelperSha256 -and (Get-FileHash -LiteralPath (Join-Path $projectPath $helper)).Hash.ToLowerInvariant() -cne $ExpectedHelperSha256){throw 'Helper freeze hash mismatch.'}
if($ExpectedComposerSha256 -and (Get-FileHash -LiteralPath (Join-Path $projectPath $composer)).Hash.ToLowerInvariant() -cne $ExpectedComposerSha256){throw 'Composer freeze hash mismatch.'}
$historical=[ordered]@{
    'actual-site-shop-02/result.bin'='b9244f0d92fd3810d525a29fd115ce295fe56e17135908f9ae11b68d1b992c2d'
    'paving-source-diagnosis-01/pre-urban.bin'='19793b8d996f22eeaf6a1c33fba274a3c4ff8d0a696ef8a6e2b75c08ede4f439'
}
foreach($relative in $historical.Keys){if((Get-FileHash -LiteralPath (Join-Path $artifactRoot $relative)).Hash.ToLowerInvariant() -cne $historical[$relative]){throw "Historical input hash mismatch: $relative"}}
function GitBytes([string]$relative){
    $start=[Diagnostics.ProcessStartInfo]::new('git');$start.WorkingDirectory=$projectPath;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true
    $start.ArgumentList.Add('show');$start.ArgumentList.Add("${revision}:$relative")
    $p=[Diagnostics.Process]::Start($start);$m=[IO.MemoryStream]::new();$p.StandardOutput.BaseStream.CopyTo($m);$p.WaitForExit()
    if($p.ExitCode -ne 0){throw "Git archive failed: $relative"}
    $b=$m.ToArray();$m.Dispose();$p.Dispose();return ,$b
}
function BytesSha([byte[]]$bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
$pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($helper);$pending.Enqueue($composer)
$gitBytes=@{};$dependencies=[ordered]@{};$gitHashes=[ordered]@{}
while($pending.Count){
    $relative=$pending.Dequeue();if($gitBytes.ContainsKey($relative)){continue}
    $bytes=GitBytes $relative;$gitBytes[$relative]=$bytes;$gitHashes['res://'+$relative]=BytesSha $bytes
    $gitText=[Text.Encoding]::UTF8.GetString($bytes)
    if($relative -ne $helper -and $relative -ne $composer){
        $disk=Join-Path $projectPath $relative
        if([IO.File]::ReadAllText($disk).Replace("`r`n","`n") -cne $gitText.Replace("`r`n","`n")){throw "Unchanged dependency differs from Git: $relative"}
        $code=[regex]::Replace($gitText,'(?m)#.*$','')
        if($code -match '\bCitadelUrbanPocComposer\b|\bRetainedSurfaceBearingRecipe\b' -and $code -notmatch 'res://scripts/buildings/(CitadelUrbanPocComposer|RetainedSurfaceBearingRecipe)\.gd'){throw "Global mutable root dependency requires explicit binding: $relative"}
        $dependencies['res://'+$relative]=(Get-FileHash -LiteralPath $disk).Hash.ToLowerInvariant()
    }
    foreach($match in [regex]::Matches($gitText,'res://(scripts/[A-Za-z0-9_/.]+\.gd)')){$pending.Enqueue($match.Groups[1].Value)}
}
New-Item -ItemType Directory -Path $runPath | Out-Null
foreach($relative in $gitBytes.Keys){$path=Join-Path $runPath ('git/'+$relative+'.txt');[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllBytes($path,$gitBytes[$relative])}
$resourcePrefix='res://'+[IO.Path]::GetRelativePath($projectPath,$runPath).Replace('\','/')+'/'
$oldHelper=[regex]::Replace([Text.Encoding]::UTF8.GetString($gitBytes[$helper]),'(?m)^class_name \w+\r?\n','')
$oldComposer=[regex]::Replace([Text.Encoding]::UTF8.GetString($gitBytes[$composer]),'(?m)^class_name \w+\r?\n','')
$oldComposer=$oldComposer.Replace('res://'+$helper,$resourcePrefix+'FrozenRetainedSurfaceBearingRecipe.gd')
if($oldComposer.Contains('res://'+$helper)){throw 'Composer still depends on current helper.'}
$returnLine='return RetainedBearingRecipeScript.prepare(blueprint, retired_roots, targets, protected)'
if(([regex]::Matches($oldComposer,[regex]::Escape($returnLine))).Count -ne 1){throw 'Cannot extract exact old helper-input handoff.'}
# Capture only the old adapter's exact prepared argument values. Its unchanged
# original counterpart below performs the real proof and supplies baseline output.
$inputCapture=$oldComposer.Replace($returnLine,'return {"targets":targets,"voids":protected}')
$archived=[ordered]@{'FrozenRetainedSurfaceBearingRecipe.gd'=$oldHelper;'FrozenCitadelUrbanPocComposer.gd'=$oldComposer;'CaptureOldRetainedInput.gd'=$inputCapture}
$archiveHashes=[ordered]@{}
foreach($name in $archived.Keys){$path=Join-Path $runPath $name;[IO.File]::WriteAllText($path,$archived[$name],[Text.UTF8Encoding]::new($false));$archiveHashes[$path.Replace('\','/')]=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
$baselinePath='';$baselineSha=''
if($Phase -ne 'baseline'){
    $baselinePath=[IO.Path]::GetFullPath((Join-Path $projectPath $BaselineDirectory))
    if((Split-Path $baselinePath -Parent) -ne $artifactRoot -or (Split-Path $baselinePath -Leaf) -notlike 'retained-cancellation-*'){throw 'Baseline must be an owned retained-cancellation directory.'}
    $r=Get-Content -LiteralPath (Join-Path $baselinePath 'report.json') -Raw|ConvertFrom-Json
    $w=Get-Content -LiteralPath (Join-Path $baselinePath 'watchdog.json') -Raw|ConvertFrom-Json
    $baselineSha=(Get-FileHash -LiteralPath (Join-Path $baselinePath 'baseline.bin')).Hash.ToLowerInvariant()
    if(-not $r.passed -or -not $r.complete -or $r.baselineSha256 -cne $baselineSha -or -not $w.cleanupPassed -or $w.overallExitCode -ne 0){throw 'Baseline integrity/cleanup failed.'}
}
$current=[ordered]@{}
if($Phase -ne 'baseline'){foreach($relative in $gitBytes.Keys){$current['res://'+$relative]=(Get-FileHash -LiteralPath (Join-Path $projectPath $relative)).Hash.ToLowerInvariant()}}
$values=@{RETAINED_CANCEL_PHASE=$Phase;RETAINED_CANCEL_OUTPUT=$runPath.Replace('\','/');RETAINED_CANCEL_BASELINE=$baselinePath.Replace('\','/');RETAINED_CANCEL_TARGET=$Target;RETAINED_CANCEL_MODE=$Mode;RETAINED_CANCEL_STAGE=$CancelStage;RETAINED_CANCEL_ARM_STAGE=$ArmStage;RETAINED_CANCEL_OCCURRENCE=[string]$CancelOccurrence}
$launch=[ordered]@{phase=$Phase;head=(& git -C $projectPath rev-parse HEAD);revision=$revision;dependencies=$dependencies;gitHashes=$gitHashes;archives=$archiveHashes;currentSources=$current;historical=$historical;baselineSha256=$baselineSha;timeoutSeconds=$TimeoutSeconds;scope='Historical actual adapter input reconstructed from saved pre-urban/shop artifacts, NOT a fresh full Source build.';inputCapturePolicy='Full old composer, only class_name removed, helper preload bound to full frozen helper; capture variant replaces the sole helper return with targets/voids. Original bound composer executes actual baseline helper proof.';testSha256=(Get-FileHash -LiteralPath (Join-Path $projectPath 'scripts/testing/buildings/CitadelRetainedPavingCancellationContract.gd')).Hash.ToLowerInvariant()}
$launch|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $runPath 'launch.json') -Encoding utf8
[IO.File]::Copy((Join-Path $projectPath 'scripts/testing/buildings/CitadelRetainedPavingCancellationContract.gd'),(Join-Path $runPath 'contract.gd.txt'),$false)
[IO.File]::Copy($PSCommandPath,(Join-Path $runPath 'wrapper.ps1.txt'),$false)
$previous=@{};$runnerExit=2;$watcher=$null
try{
    foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
    $watcher=Start-ThreadJob -ArgumentList $runPath -ScriptBlock {param($dir) while($true){foreach($name in @('stdout.log','stderr.log')){$p=Join-Path $dir $name;if(Test-Path -LiteralPath $p){foreach($line in [IO.File]::ReadAllLines($p)){if($line -match 'SCRIPT ERROR:|Parse Error:|ERROR:'){[IO.File]::WriteAllText((Join-Path $dir 'stop-request.txt'),$line);return}}}};Start-Sleep -Milliseconds 200}}
    & (Join-Path $projectPath 'tools/run-godot-scene-watchdog.ps1') -ProjectPath $projectPath -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/buildings/CitadelRetainedPavingCancellationContract.gd') -TimeoutSeconds $TimeoutSeconds -StdoutPath (Join-Path $runPath 'stdout.log') -StderrPath (Join-Path $runPath 'stderr.log') -SummaryPath (Join-Path $runPath 'watchdog.json') -StopRequestPath (Join-Path $runPath 'stop-request.txt')
    $runnerExit=$LASTEXITCODE
    if($runnerExit -eq 0){$r=Get-Content -LiteralPath (Join-Path $runPath 'summary.json') -Raw|ConvertFrom-Json;if(-not $r.passed -or -not $r.complete){$runnerExit=1};if(Select-String -LiteralPath (Join-Path $runPath 'stdout.log'),(Join-Path $runPath 'stderr.log') -Pattern 'SCRIPT ERROR:|Parse Error:|ERROR:' -Quiet){$runnerExit=1}}
}finally{if($null -ne $watcher){Stop-Job -Job $watcher;Remove-Job -Job $watcher -Force};foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}}
exit $runnerExit
