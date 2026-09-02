[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
# Installed native backend plus synthetic admission/generator inputs, not gameplay.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=[IO.Path]::GetFullPath((Join-Path $project $OutputDirectory))
if((Split-Path $run -Parent) -ne (Join-Path $project 'artifacts/citadel-runtime-integration') -or (Split-Path $run -Leaf) -notlike 'native-admission-*'){throw 'Use a native-admission-* artifact directory.'}
if(Test-Path -LiteralPath $run){throw 'Fresh output required.'}
New-Item -ItemType Directory -Path $run,(Join-Path $run 'userdata') | Out-Null
$files=@('scripts/terrain/VoxelTerrainSiteGate.gd','scripts/terrain/VoxelTerrainRuntime.gd','scripts/terrain/VoxelWorldGenerationContext.gd','scripts/WorldGenerationSystem.gd','scripts/world/GeneratedSiteProfileStore.gd','scripts/testing/terrain/CitadelNativeAdmissionContract.gd','tools/run-citadel-native-admission-contract.ps1','addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll')
$files += @('scripts/PlayerController.gd','scripts/SurvivalSystem.gd','scripts/combat/runtime/PlayerDefenseController.gd','scripts/npc_ai/motor/CharacterMotor3D.gd')
$hashes=[ordered]@{}
foreach($file in $files){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant()}
@{schema='citadel-native-admission-launch/v1';sourceSha256=$hashes;head=(& git -C $project rev-parse HEAD);recordedUtc=[DateTime]::UtcNow.ToString('o');evidenceLevel='installed_native_backend_with_synthetic_input';timeoutSeconds=45}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $run 'launch.json') -Encoding utf8
$values=@{CITADEL_NATIVE_ADMISSION_OUTPUT=$run;APPDATA=(Join-Path $run 'userdata');LOCALAPPDATA=(Join-Path $run 'userdata')}
$previous=@{}
try {
 foreach($key in $values.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
 & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') -ProjectPath $project -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' -Headless -Scene '--script' -SceneArguments @('res://scripts/testing/terrain/CitadelNativeAdmissionContract.gd') -TimeoutSeconds 45 -StdoutPath (Join-Path $run 'stdout.log') -StderrPath (Join-Path $run 'stderr.log') -SummaryPath (Join-Path $run 'watchdog.json') -StopRequestPath (Join-Path $run 'stop-request.txt') | Out-Null
 $code=$LASTEXITCODE
} finally {
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
$w=Get-Content -LiteralPath (Join-Path $run 'watchdog.json') -Raw|ConvertFrom-Json
if($code -ne 0 -or -not $w.cleanupPassed -or -not $w.authoritativeZeroProven){throw 'Native test failed or cleanup unresolved.'}
if(Select-String -LiteralPath (Join-Path $run 'stdout.log'),(Join-Path $run 'stderr.log') -Pattern 'SCRIPT ERROR:|ERROR:|WARNING:|leaked|resources still in use' -Quiet){throw 'Native test emitted engine errors/warnings.'}
foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant() -cne $hashes[$file]){throw "Source changed during test: $file"}}
$r=Get-Content -LiteralPath (Join-Path $run 'report.json') -Raw|ConvertFrom-Json
if(-not $r.passed){throw 'Native admission assertions failed.'}
@{passed=$true;checks=@($r.checks.PSObject.Properties).Count;reportPath=(Join-Path $run 'report.json')}|ConvertTo-Json -Compress
