[CmdletBinding()]
param(
    [ValidateSet('Import', 'Contract', 'Capture')][string]$Mode = 'Contract',
    [ValidateSet('urban', 'compound')][string]$Variant = 'urban',
    [ValidateRange(1, 2147483647)][int]$Seed = 208159,
    [string]$ProjectPath = (Split-Path $PSScriptRoot -Parent),
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe',
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

# Source-artifact capture or empty-environment visual review, never NPC acceptance.
# Each run owns a fresh output directory and a watchdog-owned process tree.
$ErrorActionPreference = 'Stop'
if ($Mode -ne 'Contract' -and $Variant -ne 'urban') { throw 'Variant applies only to source-artifact contracts.' }
$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be fresh; refusing to overwrite evidence.' }
if (@(Get-Process -Name '*godot*' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Another Godot instance is running; close it or finish its run first.'
}
New-Item -ItemType Directory -Path $outputRoot | Out-Null
$token = [Guid]::NewGuid().ToString()
$runEnvironment = @{
    APPDATA = (Join-Path $outputRoot 'appdata')
    LOCALAPPDATA = (Join-Path $outputRoot 'localappdata')
    VOXEL_CITADEL_VISUAL_PRESERVATION_REPORT = (Join-Path $outputRoot 'report.json')
    VOXEL_CITADEL_VISUAL_PRESERVATION_TOKEN = $token
    VOXEL_CITADEL_VISUAL_PRESERVATION_PROGRESS = (Join-Path $outputRoot 'progress.txt')
    VOXEL_CITADEL_URBAN_POC_REPORT = (Join-Path $outputRoot 'report.json')
    VOXEL_CITADEL_URBAN_POC_SCREENSHOT_DIR = (Join-Path $outputRoot 'screenshots')
}
$priorEnvironment = @{}
$watchdogArguments = @{
    ProjectPath = $projectRoot
    GodotExe = $GodotExe
    TimeoutSeconds = 360
    StdoutPath = (Join-Path $outputRoot 'stdout.log')
    StderrPath = (Join-Path $outputRoot 'stderr.log')
    SummaryPath = (Join-Path $outputRoot 'watchdog.json')
    StopRequestPath = (Join-Path $outputRoot 'stop-request.txt')
}
switch ($Mode) {
    'Import' {
        $watchdogArguments.Scene = '--editor'
        $watchdogArguments.SceneArguments = @('--import')
        $watchdogArguments.Headless = $true
    }
    'Contract' {
        $watchdogArguments.Scene = '--script'
        $watchdogArguments.SceneArguments = @((Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/testing/buildings/CitadelVisualPreservationContract.gd'), '--', '--variant', $Variant)
        $watchdogArguments.Headless = $true
    }
    'Capture' {
        $watchdogArguments.Scene = 'res://scenes/testing/buildings/CitadelUrbanPocTest.tscn'
        $watchdogArguments.SceneArguments = @('--', '--seed', [string]$Seed, '--citadel-scale', '1.25')
    }
}
try {
    foreach ($key in $runEnvironment.Keys) {
        $priorEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $runEnvironment[$key], 'Process')
    }
    New-Item -ItemType Directory -Path $runEnvironment.APPDATA, $runEnvironment.LOCALAPPDATA | Out-Null
    & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') @watchdogArguments
    $resultCode = $LASTEXITCODE
    if ($resultCode -ne 0) { throw "Godot/watchdog failed ($resultCode); inspect $outputRoot." }
    if ($Mode -ne 'Import' -and -not (Test-Path -LiteralPath (Join-Path $outputRoot 'report.json'))) {
        throw 'Godot exited without its required report.'
    }
    if ($Mode -eq 'Capture') {
        $captureReport = Get-Content -LiteralPath (Join-Path $outputRoot 'report.json') -Raw | ConvertFrom-Json
        if ($captureReport.seed -ne $Seed) { throw 'Capture report does not match the requested seed.' }
    }
    if (@(Get-Process -Name '*godot*' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'A Godot instance remains; inspect watchdog ownership evidence before any further launch.'
    }
} finally {
    foreach ($key in $priorEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $priorEnvironment[$key], 'Process')
    }
}
