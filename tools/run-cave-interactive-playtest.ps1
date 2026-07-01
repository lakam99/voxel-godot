param(
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe",
    [string]$Seed = "",
    [ValidateSet("any", "cliff", "underground")]
    [string]$Kind = "any",
    [int]$SearchRadius = 12,
    [switch]$RequireNaturalRoll,
    [bool]$GodMode = $true,
    [string]$LaunchInfoPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($Seed -eq "") {
    $Seed = "interactive-cave-$([guid]::NewGuid().ToString("N").Substring(0, 8))"
}
if ($LaunchInfoPath -eq "") {
    $LaunchInfoPath = Join-Path $projectPath "artifacts\caves\interactive-cave-launch.json"
}
$LaunchInfoPath = [System.IO.Path]::GetFullPath($LaunchInfoPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($LaunchInfoPath)) | Out-Null
Remove-Item -LiteralPath $LaunchInfoPath -ErrorAction SilentlyContinue

$previousEnv = @{
    VOXEL_PLAYTEST = $env:VOXEL_PLAYTEST
    VOXEL_TEST_SEED = $env:VOXEL_TEST_SEED
    VOXEL_CAVE_INTERACTIVE = $env:VOXEL_CAVE_INTERACTIVE
    VOXEL_CAVE_INTERACTIVE_KIND = $env:VOXEL_CAVE_INTERACTIVE_KIND
    VOXEL_CAVE_INTERACTIVE_SEARCH_RADIUS = $env:VOXEL_CAVE_INTERACTIVE_SEARCH_RADIUS
    VOXEL_CAVE_INTERACTIVE_REQUIRE_NATURAL_ROLL = $env:VOXEL_CAVE_INTERACTIVE_REQUIRE_NATURAL_ROLL
    VOXEL_CAVE_INTERACTIVE_GOD_MODE = $env:VOXEL_CAVE_INTERACTIVE_GOD_MODE
    VOXEL_CAVE_INTERACTIVE_LAUNCH_INFO = $env:VOXEL_CAVE_INTERACTIVE_LAUNCH_INFO
}

try {
    $env:VOXEL_PLAYTEST = "1"
    $env:VOXEL_TEST_SEED = $Seed
    $env:VOXEL_CAVE_INTERACTIVE = "1"
    $env:VOXEL_CAVE_INTERACTIVE_KIND = $Kind
    $env:VOXEL_CAVE_INTERACTIVE_SEARCH_RADIUS = [string][Math]::Max(1, $SearchRadius)
    $env:VOXEL_CAVE_INTERACTIVE_REQUIRE_NATURAL_ROLL = if ($RequireNaturalRoll) { "1" } else { "0" }
    $env:VOXEL_CAVE_INTERACTIVE_GOD_MODE = if ($GodMode) { "1" } else { "0" }
    $env:VOXEL_CAVE_INTERACTIVE_LAUNCH_INFO = $LaunchInfoPath

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
            throw "Godot exited before writing cave launch info. Exit code: $($process.ExitCode)"
        }
    }

    $launchInfo = $null
    if (Test-Path -LiteralPath $LaunchInfoPath) {
        $launchInfo = Get-Content -LiteralPath $LaunchInfoPath -Raw | ConvertFrom-Json
    }

    [pscustomobject]@{
        processId = $process.Id
        seed = $Seed
        kind = $Kind
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
