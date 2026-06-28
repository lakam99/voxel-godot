param(
    [ValidateSet("All", "CrowdedDoorTraffic", "MarketWorkday", "NightShelter", "TerrainEdit", "PropRemoval", "TutorialAutomation")]
    [string]$Scenario = "All",
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Seed = "atlas-1492",
    [string]$ReportPath = "",
    [int]$WatchdogSeconds = 45,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\scenario-$Scenario-$($TimeMode.ToLowerInvariant()).json"
}

$scenarioNames = if ($Scenario -eq "All") {
    @("CrowdedDoorTraffic", "MarketWorkday", "NightShelter", "TerrainEdit", "PropRemoval", "TutorialAutomation")
} else {
    @($Scenario)
}

$results = @()
$failureCount = 0
$started = Get-Date

foreach ($scenarioName in $scenarioNames) {
    $scenarioReport = if ($scenarioNames.Count -eq 1) {
        $ReportPath
    } else {
        Join-Path ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ReportPath))) "$scenarioName-$($TimeMode.ToLowerInvariant()).json"
    }
    $args = @(
        "-Scenario", $scenarioName,
        "-TimeMode", $TimeMode,
        "-Seed", $Seed,
        "-ReportPath", $scenarioReport,
        "-WatchdogSeconds", $WatchdogSeconds
    )
    if ($Visible) {
        $args += "-Visible"
    }
    Write-Host "== NPC scenario: $scenarioName =="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "run-npc-observation-tests.ps1") @args
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        $failureCount += 1
    }
    $results += [pscustomobject]@{
        scenario = $scenarioName
        reportPath = [System.IO.Path]::GetFullPath($scenarioReport)
        exitCode = $exitCode
        passed = $exitCode -eq 0
    }
    if ($exitCode -ne 0) {
        break
    }
}

if ($scenarioNames.Count -gt 1) {
    $report = [pscustomobject]@{
        schemaVersion = 1
        suite = "npc_phase5_scenarios"
        scenario = $Scenario
        timeMode = $TimeMode
        seed = $Seed
        startedUtc = $started.ToUniversalTime().ToString("o")
        finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
        durationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
        resultCount = $results.Count
        failureCount = $failureCount
        results = $results
    }
    $ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath
    Get-Content -LiteralPath $ReportPath
}

if ($failureCount -gt 0) {
    exit 1
}
exit 0
