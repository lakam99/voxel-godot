[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ine (Join-Path $project 'artifacts/citadel-runtime-integration') -or (Test-Path -LiteralPath $run)){throw 'Use a fresh direct integration artifact directory.'}
$path=Join-Path $PSScriptRoot 'run-citadel-candidate-recipe-diagnostic.ps1'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Wrapper parse failed.'}
# Execute the actual wrapper watcher, not a copied approximation.
$command=$ast.Find({param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-ThreadJob'},$true)
$expression=@($command.CommandElements | Where-Object {$_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]})
if($expression.Count -ne 1){throw 'Ambiguous watcher script block.'}
$watcher=$expression[0].ScriptBlock.GetScriptBlock()
New-Item -ItemType Directory -Path $run|Out-Null
$header='ERROR: Citadel structural completion failed: facade_completion_failed'
$rows=@()
foreach($kind in @('duplicate_same_log','duplicate_other_log','unexpected_error','warning','no_allowed_error')){
 $dir=Join-Path $run $kind
 New-Item -ItemType Directory -Path $dir|Out-Null
 $out=Join-Path $dir 'stdout.log';$err=Join-Path $dir 'stderr.log';$stop=Join-Path $dir 'stop.txt'
 [IO.File]::WriteAllText($out,$header+[Environment]::NewLine)
 [IO.File]::WriteAllText($err,'')
 $allowed=if($kind -eq 'no_allowed_error'){''}else{$header}
 $job=Start-ThreadJob -ScriptBlock $watcher -ArgumentList $out,$err,$stop,$allowed
 try {
  if($kind -ne 'no_allowed_error'){
   # Several polling intervals with an unchanged first header must not count
   # as repeated errors. Benign appends also leave that same header in place.
   for($poll=0;$poll -lt 4;$poll++){
    Start-Sleep -Milliseconds 200
    if(Test-Path -LiteralPath $stop){throw 'One header incorrectly stopped across polls.'}
    [IO.File]::AppendAllText($out,'benign trace'+[Environment]::NewLine)
   }
   switch($kind){
    'duplicate_same_log' {[IO.File]::AppendAllText($out,$header+[Environment]::NewLine)}
    'duplicate_other_log' {[IO.File]::AppendAllText($err,$header+[Environment]::NewLine)}
    'unexpected_error' {[IO.File]::AppendAllText($err,'SCRIPT ERROR: unexpected'+[Environment]::NewLine)}
    'warning' {[IO.File]::AppendAllText($err,'WARNING: unexpected'+[Environment]::NewLine)}
   }
  }
  $done=Wait-Job $job -Timeout 3
  if($null -eq $done -or -not (Test-Path -LiteralPath $stop)){throw 'Error did not stop promptly.'}
  Receive-Job $job -ErrorAction Stop|Out-Null
  $reason=[IO.File]::ReadAllText($stop)
  if($kind -like 'duplicate_*' -and -not $reason.StartsWith('Repeated inventoried engine error:')){throw 'Wrong duplicate stop reason.'}
  $rows+=@{case=$kind;passed=$true;reason=$reason}
 }finally{Stop-Job $job;Remove-Job $job -Force}
}
@{passed=$true;checks=$rows;sourceSha256=(Get-FileHash $path).Hash.ToLowerInvariant();evidenceLevel='synthetic log watcher; no Godot process or recipe execution'}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $run 'report.json') -Encoding utf8
$rows|ConvertTo-Json -Depth 3
