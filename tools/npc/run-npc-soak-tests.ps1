param(
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Case = "",
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [int]$WatchdogSeconds = 90,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$suiteArgs = @{
    Suite = "soak"
    TimeMode = $TimeMode
    Seed = $Seed
    GodotExe = $GodotExe
    WatchdogSeconds = $WatchdogSeconds
}
if ($Case -ne "") {
    $suiteArgs.Case = $Case
}
if ($ReportPath -ne "") {
    $suiteArgs.ReportPath = $ReportPath
}
if ($Visible) {
    $suiteArgs.Visible = $true
}

& (Join-Path $PSScriptRoot "run-npc-suite.ps1") @suiteArgs
exit $LASTEXITCODE
