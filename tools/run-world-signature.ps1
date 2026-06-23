param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$OutputPath = "",
    [switch]$UpdateBaseline,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($OutputPath -eq "") {
    $OutputPath = Join-Path $projectPath "artifacts\world-signature\latest\atlas-1492.json"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$baselinePath = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\baselines\world-signature\atlas-1492.json"))

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_WORLD_SIGNATURE_OUTPUT = $OutputPath

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($OutputPath)) | Out-Null

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/WorldSignature.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
}

& $GodotExe @args
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    exit $exitCode
}

if ($UpdateBaseline) {
    $baselineRoot = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\baselines"))
    if (-not $baselinePath.StartsWith($baselineRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to update baseline outside artifacts\baselines: $baselinePath"
    }
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($baselinePath)) | Out-Null
    Copy-Item -LiteralPath $OutputPath -Destination $baselinePath -Force
    Write-Host "Updated world signature baseline: $baselinePath"
    exit 0
}

if (-not (Test-Path -LiteralPath $baselinePath)) {
    Write-Error "Missing world signature baseline. Run with -UpdateBaseline to create it."
    exit 1
}

$currentHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
$baselineHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash
if ($currentHash -ne $baselineHash) {
    Write-Error "World signature mismatch. Current: $OutputPath Baseline: $baselinePath"
    exit 1
}

Write-Host "World signature matches baseline: $baselinePath"
exit 0
