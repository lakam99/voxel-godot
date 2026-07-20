param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "artifacts\combat\hostile-motion-live",
    [switch]$Visible
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$artifactPath = [IO.Path]::GetFullPath((Join-Path $projectPath $ArtifactDir))
$captureDir = Join-Path $artifactPath "screenshots"
$reportPath = Join-Path $artifactPath "report.json"
$screenshotPath = Join-Path $artifactPath "final.png"
New-Item -ItemType Directory -Force -Path $captureDir | Out-Null
Remove-Item -LiteralPath $reportPath, $screenshotPath -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $captureDir "*.png") -ErrorAction SilentlyContinue

$env:VOXEL_HOSTILE_MOTION_COMBAT_CAPTURE_DIR = $captureDir
try {
    $playtestParameters = @{
        GodotExe = $GodotExe
        ReportPath = $reportPath
        Only = "hostile_motion_combat"
    }
    if ($Visible) {
        $playtestParameters["Visible"] = $true
        $playtestParameters["ScreenshotPath"] = $screenshotPath
    }
    & (Join-Path $PSScriptRoot "run-playtest.ps1") @playtestParameters
    exit $LASTEXITCODE
} finally {
    Remove-Item Env:\VOXEL_HOSTILE_MOTION_COMBAT_CAPTURE_DIR -ErrorAction SilentlyContinue
}
