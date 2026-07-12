param(
    [string]$ProjectPath = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$tag = "v1.6x"
$assetName = "GodotVoxelExtension.zip"
$expectedSha256 = "dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a"
$downloadUrl = "https://github.com/Zylann/godot_voxel/releases/download/$tag/$assetName"

if ($ProjectPath -eq "") {
    $ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
} else {
    $ProjectPath = [IO.Path]::GetFullPath($ProjectPath)
}

$targetDir = Join-Path $ProjectPath "addons\zylann.voxel"
$editorLibrary = Join-Path $targetDir "bin\libvoxel.windows.editor.x86_64.dll"
if ((Test-Path -LiteralPath $editorLibrary) -and -not $Force) {
    Write-Host "Voxel Tools $tag is already installed at $targetDir"
    exit 0
}

$workingDir = Join-Path ([IO.Path]::GetTempPath()) "voxel-biome-world-voxel-tools-$tag"
$archivePath = Join-Path $workingDir $assetName
$extractPath = Join-Path $workingDir "extract"
New-Item -ItemType Directory -Force -Path $workingDir | Out-Null
Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Downloading Voxel Tools $tag..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
$actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
    throw "Voxel Tools digest mismatch. Expected $expectedSha256, received $actualSha256"
}

Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
$sourceDir = Join-Path $extractPath "addons\zylann.voxel"
if (-not (Test-Path -LiteralPath (Join-Path $sourceDir "voxel.gdextension"))) {
    throw "Voxel Tools archive does not contain the expected add-on descriptor"
}

New-Item -ItemType Directory -Force -Path (Join-Path $ProjectPath "addons") | Out-Null
Copy-Item -LiteralPath $sourceDir -Destination (Join-Path $ProjectPath "addons") -Recurse -Force

if (-not (Test-Path -LiteralPath $editorLibrary)) {
    throw "Voxel Tools installation did not produce the Windows editor library"
}

Write-Host "Installed Voxel Tools $tag (SHA-256 $actualSha256)"
