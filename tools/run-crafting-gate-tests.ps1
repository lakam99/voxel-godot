param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $reportDir = Join-Path $projectPath "artifacts\crafting"
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $ReportPath = Join-Path $reportDir "crafting-gate-report.json"
} else {
    $parent = Split-Path -Parent $ReportPath
    if ($parent -ne "") {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
}

Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
$env:VOXEL_CRAFTING_GATE_REPORT = $ReportPath

& $GodotExe --headless --path $projectPath --script "res://scripts/testing/CraftingGateTestRunner.gd"
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_CRAFTING_GATE_REPORT -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $ReportPath) {
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing crafting gate report: $ReportPath"
    exit 1
}

exit $exitCode
