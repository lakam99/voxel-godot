param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "artifacts\combat\vox-186-wolf-behavior-contract.json"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}
$ReportPath = Join-Path $ProjectPath $ReportPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) | Out-Null
Remove-Item -LiteralPath $ReportPath -Force -ErrorAction SilentlyContinue
$env:VOXEL_WOLF_BEHAVIOR_CONTRACT_REPORT = $ReportPath
& $GodotExe --headless --path $ProjectPath --scene res://scenes/testing/WolfBehaviorContractTest.tscn
Remove-Item Env:VOXEL_WOLF_BEHAVIOR_CONTRACT_REPORT -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $ReportPath)) {
    throw "Wolf behavior contract did not produce a report: $ReportPath"
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8
if ($LASTEXITCODE -ne 0 -or $report.status -ne "passed") {
    throw "Wolf behavior contract failed."
}
