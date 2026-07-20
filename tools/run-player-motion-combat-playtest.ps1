param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "",
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ArtifactDir -eq "") {
    $ArtifactDir = Join-Path $projectPath "artifacts\combat\player-motion-live"
}
$ArtifactDir = [System.IO.Path]::GetFullPath($ArtifactDir)
$reportPath = Join-Path $ArtifactDir "report.json"
$screenshotPath = Join-Path $ArtifactDir "final.png"
$captureDir = Join-Path $ArtifactDir "screenshots"
New-Item -ItemType Directory -Force -Path $ArtifactDir, $captureDir | Out-Null
Remove-Item -LiteralPath $reportPath, $screenshotPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $captureDir "*.png") -ErrorAction SilentlyContinue

$env:VOXEL_PLAYER_MOTION_COMBAT_CAPTURE_DIR = $captureDir
try {
    $playtestParameters = @{
        GodotExe = $GodotExe
        ReportPath = $reportPath
        Only = "player_motion_combat"
    }
    if ($Visible) {
        $playtestParameters["Visible"] = $true
        $playtestParameters["ScreenshotPath"] = $screenshotPath
    }
    & (Join-Path $PSScriptRoot "run-playtest.ps1") @playtestParameters
    exit $LASTEXITCODE
} finally {
    Remove-Item Env:\VOXEL_PLAYER_MOTION_COMBAT_CAPTURE_DIR -ErrorAction SilentlyContinue
}
