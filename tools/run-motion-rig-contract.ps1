param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "artifacts\combat\motion-rig-contract"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$ArtifactDir = [IO.Path]::GetFullPath((Join-Path $ProjectPath $ArtifactDir))
$ReportPath = Join-Path $ArtifactDir "motion-rig-contract.json"
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
Remove-Item -LiteralPath $ReportPath -Force -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }

$env:VOXEL_MOTION_RIG_CONTRACT_REPORT = $ReportPath
$PreviousNativeErrorActionPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
    $Output = & $GodotExe --headless --path $ProjectPath --script res://scripts/testing/combat/MotionRigContractRunner.gd 2>&1
    $ExitCode = $LASTEXITCODE
} finally {
    $PSNativeCommandUseErrorActionPreference = $PreviousNativeErrorActionPreference
    Remove-Item Env:VOXEL_MOTION_RIG_CONTRACT_REPORT -ErrorAction SilentlyContinue
}
$Output | Write-Host
if ($Output -match "SCRIPT ERROR|Parse Error|Compile Error|ERROR: Failed") { throw "Motion rig contract emitted a Godot script error" }
if (-not (Test-Path -LiteralPath $ReportPath)) { throw "Motion rig contract did not write a report" }
$Report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($ExitCode -ne 0 -or $true -ne $Report.passed) { throw "Motion rig contract failed" }
$Report | ConvertTo-Json -Depth 10
