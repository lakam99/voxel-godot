[CmdletBinding()]
param(
    [string]$ProjectPath = (Split-Path $PSScriptRoot -Parent),
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe',
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be fresh; refusing to overwrite evidence.' }
if (@(Get-Process -Name '*godot*' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Another Godot instance is running.' }
New-Item -ItemType Directory -Path $outputRoot | Out-Null
$runEnvironment = @{
    APPDATA = (Join-Path $outputRoot 'appdata')
    LOCALAPPDATA = (Join-Path $outputRoot 'localappdata')
    VOXEL_INTERIOR_PROGRAM_REPORT = (Join-Path $outputRoot 'report.json')
}
$priorEnvironment = @{}
try {
    foreach ($key in $runEnvironment.Keys) {
        $priorEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $runEnvironment[$key], 'Process')
    }
    New-Item -ItemType Directory -Path $runEnvironment.APPDATA, $runEnvironment.LOCALAPPDATA | Out-Null
    & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') `
        -ProjectPath $projectRoot -GodotExe $GodotExe -Headless `
        -Scene '--script' -SceneArguments @((Join-Path $projectRoot 'scripts/testing/buildings/BuildingInteriorProgramContract.gd')) `
        -TimeoutSeconds 60 -StdoutPath (Join-Path $outputRoot 'stdout.log') `
        -StderrPath (Join-Path $outputRoot 'stderr.log') -SummaryPath (Join-Path $outputRoot 'watchdog.json') `
        -StopRequestPath (Join-Path $outputRoot 'stop-request.txt')
    if ($LASTEXITCODE -ne 0) { throw "Godot/watchdog failed ($LASTEXITCODE); inspect $outputRoot." }
    $report = Get-Content -LiteralPath (Join-Path $outputRoot 'report.json') -Raw | ConvertFrom-Json
    $watchdog = Get-Content -LiteralPath (Join-Path $outputRoot 'watchdog.json') -Raw | ConvertFrom-Json
    if (-not $report.passed -or $watchdog.functionalExitCode -ne 0 -or -not $watchdog.cleanupPassed `
            -or -not $watchdog.authoritativeZeroProven -or $watchdog.timedOut -or $watchdog.forcedCleanup) {
        throw 'Contract or watchdog evidence is not clean.'
    }
    if ((Get-Item -LiteralPath (Join-Path $outputRoot 'stderr.log')).Length -ne 0) { throw 'Godot stderr is not empty.' }
    if (@(Get-Process -Name '*godot*' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'A Godot instance remains.' }
} finally {
    foreach ($key in $priorEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $priorEnvironment[$key], 'Process')
    }
}
