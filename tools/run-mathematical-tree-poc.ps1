param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [int]$Seed = 1296127048,
    [double]$Maturity = 0.92,
    [ValidateSet("broadleaf", "conifer", "savanna", "bushy_oak")]
    [string]$Species = "broadleaf",
    [double]$ReviewSeconds = 0.0,
    [string]$ReportPath = "",
    [string]$ScreenshotDir = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\vegetation\mathematical-tree-poc\report.json"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\vegetation\mathematical-tree-poc\screenshots"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_MATHEMATICAL_TREE_POC_REPORT = $ReportPath
$env:VOXEL_MATHEMATICAL_TREE_POC_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_MATHEMATICAL_TREE_POC_SEED = [string]$Seed
$env:VOXEL_MATHEMATICAL_TREE_POC_MATURITY = [string]$Maturity
$env:VOXEL_MATHEMATICAL_TREE_POC_SPECIES = $Species
$env:VOXEL_MATHEMATICAL_TREE_POC_REVIEW_SECONDS = [string]$ReviewSeconds
try {
    $godotOutput = & $GodotExe --path $projectPath --resolution 1280x720 "res://scenes/testing/MathematicalTreePocTest.tscn" 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item Env:\VOXEL_MATHEMATICAL_TREE_POC_REPORT -ErrorAction SilentlyContinue
    Remove-Item Env:\VOXEL_MATHEMATICAL_TREE_POC_SCREENSHOT_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\VOXEL_MATHEMATICAL_TREE_POC_SEED -ErrorAction SilentlyContinue
    Remove-Item Env:\VOXEL_MATHEMATICAL_TREE_POC_MATURITY -ErrorAction SilentlyContinue
    Remove-Item Env:\VOXEL_MATHEMATICAL_TREE_POC_SPECIES -ErrorAction SilentlyContinue
    Remove-Item Env:\VOXEL_MATHEMATICAL_TREE_POC_REVIEW_SECONDS -ErrorAction SilentlyContinue
}
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing mathematical tree PoC report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "mathematical_tree_poc_visual" -or [string]$report.evidenceLevel -ne "headed_isolated_visual_fixture") {
    Write-Error "Mathematical tree PoC report identity mismatch"
    exit 1
}
[pscustomobject]@{
    runnerId = $report.runnerId
    passed = $report.passed
    signature = $report.recipe.signature
	architecture = $report.recipe.architecture
    branches = $report.recipe.branchCount
    foliageClusters = $report.recipe.foliageClusterCount
    generationMilliseconds = $report.generationMilliseconds
    publicationMilliseconds = $report.publicationMilliseconds
    framesReturnedWhileGenerating = $report.framesReturnedWhileGenerating
    captures = $report.captures.Count
    reportPath = $ReportPath
    screenshotDir = $ScreenshotDir
} | ConvertTo-Json
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}
exit 0
