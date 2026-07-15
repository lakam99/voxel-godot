param(
    [string]$BlenderPath = "",
    [string]$NodePath = "",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [switch]$SkipGenerate
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$GeneratedRoot = Join-Path $ProjectRoot "assets\visual\generated"
$EnvironmentDir = Join-Path $GeneratedRoot "environment"
$ManifestPath = Join-Path $GeneratedRoot "visual-manifest.json"
$ContactSheetPath = Join-Path $EnvironmentDir "canopy-contact-sheet-v3.png"
$CanopyDetailSheetPath = Join-Path $EnvironmentDir "canopy-leaf-detail-sheet-v3.png"
$ValidationReportPath = Join-Path $GeneratedRoot "environment-validation.json"
$GeneratorScript = Join-Path $PSScriptRoot "generate_environment_assets.py"
$BlenderValidator = Join-Path $PSScriptRoot "validate_generated_assets.py"
$ManifestValidator = Join-Path $ProjectRoot "tools\art\validate-visual-manifest.mjs"
$GodotImportContract = Join-Path $ProjectRoot "tools\run-canopy-asset-import-contract-tests.ps1"
$GodotImportReport = Join-Path $ProjectRoot "artifacts\vegetation\canopy-asset-import-contract.json"

New-Item -ItemType Directory -Force -Path $EnvironmentDir | Out-Null

$BlenderExe = & (Join-Path $PSScriptRoot "find-blender.ps1") -BlenderPath $BlenderPath
if (-not (Test-Path -LiteralPath $BlenderExe -PathType Leaf)) {
    throw "Resolved Blender path does not exist: $BlenderExe"
}

if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCommand) {
        $NodePath = $nodeCommand.Source
    }
}
if ([string]::IsNullOrWhiteSpace($NodePath) -or -not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
    throw "Could not find node.exe. Pass -NodePath for manifest validation."
}

if (-not $SkipGenerate) {
    & $BlenderExe --background --factory-startup --python $GeneratorScript -- `
        --output-root $GeneratedRoot `
        --manifest $ManifestPath `
        --contact-sheet $ContactSheetPath
    if ($LASTEXITCODE -ne 0) {
        throw "Blender asset generation failed with exit code $LASTEXITCODE"
    }
}

& $BlenderExe --background --factory-startup --python $BlenderValidator -- `
    --manifest $ManifestPath `
    --project-root $ProjectRoot `
    --output $ValidationReportPath
if ($LASTEXITCODE -ne 0) {
    throw "Generated asset validation failed with exit code $LASTEXITCODE"
}

& $NodePath $ManifestValidator $ProjectRoot $ManifestPath
if ($LASTEXITCODE -ne 0) {
    throw "Visual manifest validation failed with exit code $LASTEXITCODE"
}

& $GodotImportContract -GodotExe $GodotExe -ReportPath $GodotImportReport
if ($LASTEXITCODE -ne 0) {
    throw "Godot canopy asset import contract failed with exit code $LASTEXITCODE"
}

Write-Output "Generated environment assets:"
Write-Output "  Blender: $BlenderExe"
Write-Output "  Manifest: $ManifestPath"
Write-Output "  Contact sheet: $ContactSheetPath"
Write-Output "  Canopy detail sheet: $CanopyDetailSheetPath"
Write-Output "  Validation: $ValidationReportPath"
Write-Output "  Godot import contract: $GodotImportReport"
