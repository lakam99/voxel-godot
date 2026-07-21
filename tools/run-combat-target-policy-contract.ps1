param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "artifacts\combat\combat-target-policy-contract.json"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}
$ReportPath = [IO.Path]::GetFullPath((Join-Path $ProjectPath $ReportPath))
Remove-Item -LiteralPath $ReportPath -Force -ErrorAction SilentlyContinue
$env:VOXEL_COMBAT_TARGET_POLICY_REPORT = $ReportPath
$output = & $GodotExe --headless --path $ProjectPath --script res://scripts/testing/combat/CombatTargetPolicyContractRunner.gd 2>&1
$exitCode = $LASTEXITCODE
$output | Write-Host
Remove-Item Env:VOXEL_COMBAT_TARGET_POLICY_REPORT -ErrorAction SilentlyContinue
if ($output -match "SCRIPT ERROR|Parse Error|Compile Error|ERROR: Failed") {
    throw "Combat target policy contract emitted a Godot script error"
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    throw "Combat target policy contract did not produce a report: $ReportPath"
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($exitCode -ne 0 -or $true -ne $report.passed) {
    throw "Combat target policy contract failed"
}
