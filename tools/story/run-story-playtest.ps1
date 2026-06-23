param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\story\story-playtest-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_STORY_PLAYTEST = "1"
$env:VOXEL_STORY_PLAYTEST_REPORT = $ReportPath
$env:VOXEL_STORY_PLAYTEST_PROGRESS = Join-Path $projectPath "artifacts\story\story-playtest-progress.txt"

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/story_testing/StoryPlaytest.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
}

& $GodotExe @args
$exitCode = $LASTEXITCODE

if (Test-Path -LiteralPath $ReportPath) {
    Get-Content -LiteralPath $ReportPath
}

exit $exitCode
