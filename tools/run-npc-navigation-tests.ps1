param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ScreenshotPath = "",
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "npc-navigation-report.json"
}

$env:VOXEL_PLAYTEST_REPORT = $ReportPath
$env:VOXEL_PLAYTEST_PROGRESS = Join-Path $projectPath "npc-navigation-progress.txt"
$env:VOXEL_PLAYTEST = "1"
if ($ScreenshotPath -ne "") {
    $env:VOXEL_PLAYTEST_SCREENSHOT = $ScreenshotPath
} else {
    Remove-Item Env:\VOXEL_PLAYTEST_SCREENSHOT -ErrorAction SilentlyContinue
}

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/NpcNavigationTest.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
}

& $GodotExe @args
$exitCode = $LASTEXITCODE

if (Test-Path -LiteralPath $ReportPath) {
    Get-Content -LiteralPath $ReportPath
}

exit $exitCode
