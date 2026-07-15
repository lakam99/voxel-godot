param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\tutorial-town\main-menu-continue-startup-readiness-smoke.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$artifactDir = [System.IO.Path]::GetDirectoryName($ReportPath)
$setupReportPath = Join-Path $artifactDir "main-menu-continue-fixture-setup.json"
$fixturePath = Join-Path $artifactDir "main-menu-continue-fixture-save.json"
$fixtureBaseName = [System.IO.Path]::GetFileNameWithoutExtension($fixturePath)
$fixtureActiveSeedPath = Join-Path $artifactDir "${fixtureBaseName}_active_seed.txt"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -LiteralPath $ReportPath,$setupReportPath,$fixturePath,$fixtureActiveSeedPath -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $artifactDir -File | Where-Object { $_.Name.StartsWith("${fixtureBaseName}_slot_", [System.StringComparison]::OrdinalIgnoreCase) } | Remove-Item -Force

function Invoke-StartupSmoke([string]$Mode, [string]$OutputPath, [bool]$PersistSave) {
    $env:VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT = $OutputPath
    $env:VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE = $Mode
    $env:VOXEL_MAIN_MENU_STARTUP_REAL_SAVE_MODE = "1"
    $env:VOXEL_SAVE_PATH_OVERRIDE = $fixturePath
    if ($PersistSave) {
        $env:VOXEL_MAIN_MENU_STARTUP_PERSIST_SAVE = "1"
    } else {
        Remove-Item Env:\VOXEL_MAIN_MENU_STARTUP_PERSIST_SAVE -ErrorAction SilentlyContinue
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/MainMenuStartupSmokeRunner.gd" 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($output) {
        $output | ForEach-Object { Write-Host $_ }
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "Missing $Mode startup smoke report: $OutputPath"
    }
    $report = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
    if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
        throw "$Mode startup smoke failed"
    }
    return $report
}

try {
    $setup = Invoke-StartupSmoke "new_game" $setupReportPath $true
    if ($true -ne $setup.details.fixtureSaved -or -not (Test-Path -LiteralPath $fixtureActiveSeedPath)) {
        throw "New Game did not produce the isolated Continue fixture"
    }
    $report = Invoke-StartupSmoke "continue" $ReportPath $false
    if ([string]$report.runnerId -ne "main_menu_continue_startup_smoke" -or [string]$report.evidenceLevel -ne "scene-load-smoke") {
        throw "Main-menu Continue readiness report identity mismatch"
    }
    [pscustomobject]@{
        runnerId = $report.runnerId
        passed = $report.passed
        setupElapsedMs = $setup.details.elapsedMs
        continueElapsedMs = $report.details.elapsedMs
        maxStepMs = $report.details.startupMaxStep.stepMs
        maxStepDomain = $report.details.startupMaxStep.domain
        readinessDomains = @($report.details.startupReadinessDomains.psobject.Properties.Name).Count
        registeredNpcCount = @($report.details.npcPhysics).Count
        reportPath = $ReportPath
        setupReportPath = $setupReportPath
    } | ConvertTo-Json
} finally {
    Remove-Item Env:\VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT,Env:\VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE,Env:\VOXEL_MAIN_MENU_STARTUP_REAL_SAVE_MODE,Env:\VOXEL_MAIN_MENU_STARTUP_PERSIST_SAVE,Env:\VOXEL_SAVE_PATH_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixturePath,$fixtureActiveSeedPath -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $artifactDir -File | Where-Object { $_.Name.StartsWith("${fixtureBaseName}_slot_", [System.StringComparison]::OrdinalIgnoreCase) } | Remove-Item -Force
}
