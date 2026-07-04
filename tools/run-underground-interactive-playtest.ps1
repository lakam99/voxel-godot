param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe",
    [string]$Seed = "",
    [int]$SearchRadius = 32,
    [int]$MinDepthCells = 4,
    [int]$MaxDepthCells = 30,
    [bool]$GodMode = $true,
    [string]$LaunchInfoPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($Seed -eq "") {
    $Seed = "interactive-underground-$([guid]::NewGuid().ToString("N").Substring(0, 8))"
}
if ($LaunchInfoPath -eq "") {
    $LaunchInfoPath = Join-Path $projectPath "artifacts\underground\interactive-underground-launch.json"
}
$LaunchInfoPath = [System.IO.Path]::GetFullPath($LaunchInfoPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($LaunchInfoPath)) | Out-Null
Remove-Item -LiteralPath $LaunchInfoPath -ErrorAction SilentlyContinue

$previousEnv = @{
    VOXEL_PLAYTEST = $env:VOXEL_PLAYTEST
    VOXEL_TEST_SEED = $env:VOXEL_TEST_SEED
    VOXEL_UNDERGROUND_INTERACTIVE = $env:VOXEL_UNDERGROUND_INTERACTIVE
    VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS = $env:VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS
    VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH = $env:VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH
    VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH = $env:VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH
    VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE = $env:VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE
    VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO = $env:VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO
}

try {
    $env:VOXEL_PLAYTEST = "1"
    $env:VOXEL_TEST_SEED = $Seed
    $env:VOXEL_UNDERGROUND_INTERACTIVE = "1"
    $env:VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS = [string][Math]::Max(1, $SearchRadius)
    $env:VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH = [string][Math]::Max(1, $MinDepthCells)
    $env:VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH = [string][Math]::Max($MinDepthCells, $MaxDepthCells)
    $env:VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE = if ($GodMode) { "1" } else { "0" }
    $env:VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO = $LaunchInfoPath

    $args = @(
        "--resolution", "1280x720",
        "--path", $projectPath,
        "--scene", "res://scenes/Main.tscn"
    )

    $process = Start-Process `
        -FilePath $GodotExe `
        -WorkingDirectory $projectPath `
        -ArgumentList $args `
        -PassThru

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $LaunchInfoPath)) {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) {
            throw "Godot exited before writing underground launch info. Exit code: $($process.ExitCode)"
        }
    }

    $launchInfo = $null
    if (Test-Path -LiteralPath $LaunchInfoPath) {
        $launchInfo = Get-Content -LiteralPath $LaunchInfoPath -Raw | ConvertFrom-Json
    }

    [pscustomobject]@{
        processId = $process.Id
        seed = $Seed
        searchRadius = $SearchRadius
        minDepthCells = $MinDepthCells
        maxDepthCells = $MaxDepthCells
        godMode = $GodMode
        launchInfoPath = $LaunchInfoPath
        launchInfo = $launchInfo
    } | ConvertTo-Json -Depth 8
} finally {
    foreach ($key in $previousEnv.Keys) {
        if ($null -eq $previousEnv[$key]) {
            Remove-Item "Env:\$key" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:\$key" $previousEnv[$key]
        }
    }
}
