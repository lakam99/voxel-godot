param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [int]$Seed = 208158,
    [float]$CitadelScale = 1.25,
    [switch]$Visible,
    [string]$UserDataRoot = ""
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console executable was not found: $GodotExe" }
if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
    $UserDataRoot = Join-Path $ProjectPath ("artifacts\npc\runtime_userdata\citadel-life-" + [Guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Force -Path $UserDataRoot | Out-Null

Write-Host "Launching interactive Citadel Life Playtest (seed $Seed, scale $CitadelScale)."
Write-Host "The isolated test profile prevents the test runner from touching the desktop Godot profile."
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $GodotExe
$startInfo.WorkingDirectory = $ProjectPath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = -not $Visible
$startInfo.Arguments = ('--path "{0}" --resolution 1280x720 --scene res://scenes/testing/npc/CitadelLifePlaytest.tscn -- --seed {1} --citadel-scale {2}' -f $ProjectPath, $Seed, $CitadelScale)
$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA
$previousPlaytest = $env:VOXEL_PLAYTEST
$previousTestSeed = $env:VOXEL_TEST_SEED
$env:APPDATA = $UserDataRoot
$env:LOCALAPPDATA = $UserDataRoot
$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = "citadel-life-world-$Seed"
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) { throw "Citadel Life Playtest did not start." }
} finally {
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
    if ($null -eq $previousPlaytest) {
        Remove-Item Env:VOXEL_PLAYTEST -ErrorAction SilentlyContinue
    } else {
        $env:VOXEL_PLAYTEST = $previousPlaytest
    }
    if ($null -eq $previousTestSeed) {
        Remove-Item Env:VOXEL_TEST_SEED -ErrorAction SilentlyContinue
    } else {
        $env:VOXEL_TEST_SEED = $previousTestSeed
    }
}
$process.WaitForExit()
exit $process.ExitCode
