param(
    [string]$BlenderPath = "",
    [switch]$SkipGenerate
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$GeneratedRoot = Join-Path $ProjectRoot "assets\visual\generated"
$CharacterDir = Join-Path $GeneratedRoot "characters"
$ManifestPath = Join-Path $CharacterDir "character-manifest.json"
$ContactSheetPath = Join-Path $CharacterDir "contact-sheet.png"
$ValidationReportPath = Join-Path $CharacterDir "character-validation.json"
$GeneratorScript = Join-Path $PSScriptRoot "generate_character_assets.py"
$BlenderValidator = Join-Path $PSScriptRoot "validate_generated_assets.py"

New-Item -ItemType Directory -Force -Path $CharacterDir | Out-Null

$BlenderExe = & (Join-Path $PSScriptRoot "find-blender.ps1") -BlenderPath $BlenderPath
if (-not (Test-Path -LiteralPath $BlenderExe -PathType Leaf)) {
    throw "Resolved Blender path does not exist: $BlenderExe"
}

if (-not $SkipGenerate) {
    & $BlenderExe --background --factory-startup --python $GeneratorScript -- `
        --output-root $GeneratedRoot `
        --manifest $ManifestPath `
        --contact-sheet $ContactSheetPath
    if ($LASTEXITCODE -ne 0) {
        throw "Blender character asset generation failed with exit code $LASTEXITCODE"
    }
}

& $BlenderExe --background --factory-startup --python $BlenderValidator -- `
    --manifest $ManifestPath `
    --project-root $ProjectRoot `
    --output $ValidationReportPath
if ($LASTEXITCODE -ne 0) {
    throw "Generated character asset validation failed with exit code $LASTEXITCODE"
}

Write-Output "Generated character assets:"
Write-Output "  Blender: $BlenderExe"
Write-Output "  Manifest: $ManifestPath"
Write-Output "  Contact sheet: $ContactSheetPath"
Write-Output "  Validation: $ValidationReportPath"
