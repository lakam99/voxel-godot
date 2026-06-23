param(
    [string]$BlenderPath = ""
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $ProjectRoot "assets\generated\animated"
$GeneratorScript = Join-Path $PSScriptRoot "generate_animated_assets.py"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$BlenderExe = & (Join-Path $PSScriptRoot "find-blender.ps1") -BlenderPath $BlenderPath
if (-not (Test-Path -LiteralPath $BlenderExe -PathType Leaf)) {
    throw "Resolved Blender path does not exist: $BlenderExe"
}

& $BlenderExe --background --factory-startup --python $GeneratorScript -- `
    --output-root $OutputRoot
if ($LASTEXITCODE -ne 0) {
    throw "Animated asset generation failed with exit code $LASTEXITCODE"
}

Write-Output "Generated animated assets:"
Write-Output "  Blender: $BlenderExe"
Write-Output "  Output: $OutputRoot"
