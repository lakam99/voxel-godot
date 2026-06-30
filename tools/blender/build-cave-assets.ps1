param(
    [string]$BlenderPath = "",
    [switch]$SkipGenerate
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$CaveDir = Join-Path $ProjectRoot "assets\visual\generated\caves"
$ManifestPath = Join-Path $CaveDir "cave-asset-manifest.json"
$ContactSheetPath = Join-Path $CaveDir "contact-sheet.png"
$PreviewPath = Join-Path $CaveDir "cave-interior-preview.png"
$GeneratorScript = Join-Path $PSScriptRoot "generate_cave_assets.py"

New-Item -ItemType Directory -Force -Path $CaveDir | Out-Null

$BlenderExe = & (Join-Path $PSScriptRoot "find-blender.ps1") -BlenderPath $BlenderPath
if (-not (Test-Path -LiteralPath $BlenderExe -PathType Leaf)) {
    throw "Resolved Blender path does not exist: $BlenderExe"
}

if (-not $SkipGenerate) {
    Remove-Item -Path (Join-Path $CaveDir "*.glb") -ErrorAction SilentlyContinue
    & $BlenderExe --background --factory-startup --python $GeneratorScript -- `
        --output-root $CaveDir `
        --manifest $ManifestPath `
        --contact-sheet $ContactSheetPath `
        --preview-render $PreviewPath
    if ($LASTEXITCODE -ne 0) {
        throw "Blender cave asset generation failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Missing cave asset manifest: $ManifestPath"
}
if (-not (Test-Path -LiteralPath $ContactSheetPath -PathType Leaf)) {
    throw "Missing cave contact sheet: $ContactSheetPath"
}
if (-not (Test-Path -LiteralPath $PreviewPath -PathType Leaf)) {
    throw "Missing cave interior preview: $PreviewPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$missing = @()
foreach ($asset in $manifest.assets) {
    $path = Join-Path $ProjectRoot ([string]$asset.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $missing += $path
    }
}
if ($missing.Count -gt 0) {
    throw "Missing cave GLBs: $($missing -join ', ')"
}

Write-Output "Generated cave assets:"
Write-Output "  Blender: $BlenderExe"
Write-Output "  Manifest: $ManifestPath"
Write-Output "  Contact sheet: $ContactSheetPath"
Write-Output "  Interior preview: $PreviewPath"
