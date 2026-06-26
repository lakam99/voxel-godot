param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$OutputPath = "",
    [string]$Seed = "atlas-1492",
    [switch]$UpdateBaseline,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($OutputPath -eq "") {
    $OutputPath = Join-Path $projectPath "artifacts\world-signature\latest\atlas-1492.json"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$baselineRoot = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\baselines"))
$baselinePath = [System.IO.Path]::GetFullPath((Join-Path $projectPath "artifacts\baselines\world-signature\atlas-1492.json"))

function Get-RepoRelativePath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($projectPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project: $fullPath"
    }
    return $fullPath.Substring($projectPath.Length).TrimStart("\", "/").Replace("\", "/")
}

function Test-PathInside([string]$Path, [string]$RootPath) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd("\", "/")
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith("$fullRoot\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-GitTrackedBaseline {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return $true
    }
    $relativeBaseline = Get-RepoRelativePath $baselinePath
    & git -C $projectPath ls-files --error-unmatch -- $relativeBaseline *> $null
    return $LASTEXITCODE -eq 0
}

function Assert-GitTrackedBaseline([string]$Mode) {
    if (-not (Test-GitTrackedBaseline)) {
        $relativeBaseline = Get-RepoRelativePath $baselinePath
        Write-Error "World signature baseline is not tracked by Git: $relativeBaseline. This is a tracked deterministic regression baseline, not disposable save/output data. Restore it or intentionally stage it before $Mode."
        exit 1
    }
}

function Assert-GitCleanBaseline([string]$Mode) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return
    }
    $relativeBaseline = Get-RepoRelativePath $baselinePath
    & git -C $projectPath diff --quiet -- $relativeBaseline
    if ($LASTEXITCODE -ne 0) {
        Write-Error "World signature baseline has unstaged local modifications: $relativeBaseline. Refusing to continue while $Mode because this tracked baseline is not disposable runner output."
        exit 1
    }
    & git -C $projectPath diff --cached --quiet -- $relativeBaseline
    if ($LASTEXITCODE -ne 0) {
        Write-Error "World signature baseline has staged local modifications: $relativeBaseline. Refusing to continue while $Mode until that baseline decision is committed or reverted."
        exit 1
    }
}

if (Test-PathInside $OutputPath $baselineRoot) {
    Write-Error "Refusing to write generated world-signature output inside artifacts\baselines: $OutputPath. Write to artifacts\world-signature or artifacts\test-runners, then use -UpdateBaseline only after investigating intentional drift."
    exit 1
}

Assert-GitTrackedBaseline "preparing a world signature run"
Assert-GitCleanBaseline "preparing a world signature run"

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_WORLD_SIGNATURE_OUTPUT = $OutputPath
$env:VOXEL_TEST_SEED = $Seed

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
    if (-not (Test-PathInside $baselinePath $baselineRoot)) {
        throw "Refusing to update baseline outside artifacts\baselines: $baselinePath"
    }
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($baselinePath)) | Out-Null
    Copy-Item -LiteralPath $OutputPath -Destination $baselinePath -Force
    Assert-GitTrackedBaseline "accepting an updated world signature baseline"
    Write-Host "Updated world signature baseline: $baselinePath"
    exit 0
}

if (-not (Test-Path -LiteralPath $baselinePath)) {
    Write-Error "Missing world signature baseline. Run with -UpdateBaseline to create it."
    exit 1
}
Assert-GitTrackedBaseline "running the world signature comparison"

$currentHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
$baselineHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash
if ($currentHash -ne $baselineHash) {
    Write-Error "World signature mismatch. Current: $OutputPath Baseline: $baselinePath"
    exit 1
}

Write-Host "World signature matches baseline: $baselinePath"
exit 0
