param(
    [string]$BlenderPath = ""
)

$ErrorActionPreference = "Stop"

function Test-BlenderExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return [System.IO.Path]::GetFileName($Path).ToLowerInvariant() -eq "blender.exe"
}

if (Test-BlenderExecutable $BlenderPath) {
    Write-Output (Resolve-Path -LiteralPath $BlenderPath).Path
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($env:BLENDER_EXE) -and (Test-BlenderExecutable $env:BLENDER_EXE)) {
    Write-Output (Resolve-Path -LiteralPath $env:BLENDER_EXE).Path
    exit 0
}

$command = Get-Command blender -ErrorAction SilentlyContinue
if ($command -and (Test-BlenderExecutable $command.Source)) {
    Write-Output (Resolve-Path -LiteralPath $command.Source).Path
    exit 0
}

$roots = @(
    "$env:ProgramFiles\Blender Foundation",
    "${env:ProgramFiles(x86)}\Blender Foundation",
    "$env:LOCALAPPDATA\Programs"
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Container) }

$candidates = @()
foreach ($root in $roots) {
    $candidates += Get-ChildItem -LiteralPath $root -Recurse -Filter blender.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\Blender( Foundation)?\\" -or $_.FullName -match "\\Blender " }
}

$selected = $candidates |
    Sort-Object @{ Expression = { $_.FullName }; Descending = $true } |
    Select-Object -First 1

if ($selected -and (Test-BlenderExecutable $selected.FullName)) {
    Write-Output $selected.FullName
    exit 0
}

throw "Could not find blender.exe. Pass -BlenderPath or set BLENDER_EXE."
