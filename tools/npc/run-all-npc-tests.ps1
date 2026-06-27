param(
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Seed = "atlas-1492",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Continue"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$registryPath = Join-Path $PSScriptRoot "npc-suite-registry.json"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\all-npc-$($TimeMode.ToLowerInvariant()).json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
$results = @()
$failureCount = 0
$started = Get-Date

Push-Location $projectPath
try {
    foreach ($suite in $registry.suites) {
        $id = [string]$suite.id
        $command = [string]$suite.command
        $commandPath = if ($command.StartsWith(".\")) { Join-Path $projectPath $command.Substring(2) } else { $command }
        $suiteReport = Join-Path $projectPath "artifacts\npc\reports\$id-$($TimeMode.ToLowerInvariant()).json"
        $runnerArgs = @("-TimeMode", $TimeMode, "-Seed", $Seed, "-ReportPath", $suiteReport)
        $suiteStarted = Get-Date
        Write-Host "== NPC suite: $id =="
        $scriptFailed = $false
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $commandPath -TimeMode $TimeMode -Seed $Seed -ReportPath $suiteReport
        } catch {
            Write-Error $_
            $scriptFailed = $true
        }
        $exitCode = if ($scriptFailed) { 1 } elseif ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        $duration = ((Get-Date) - $suiteStarted).TotalSeconds
        $passed = $exitCode -eq 0
        if (-not $passed) {
            $failureCount += 1
        }
        $results += [pscustomobject]@{
            id = $id
            command = $command
            args = $runnerArgs
            exitCode = $exitCode
            passed = $passed
            durationSeconds = [math]::Round($duration, 3)
            reportPath = $suiteReport
        }
    }
}
finally {
    Pop-Location
}

$report = [pscustomobject]@{
    schemaVersion = 1
    suite = "all-npc"
    timeMode = $TimeMode
    seed = $Seed
    startedUtc = $started.ToUniversalTime().ToString("o")
    finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
    durationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
    resultCount = $results.Count
    failureCount = $failureCount
    results = $results
    registryPath = $registryPath
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath
Get-Content -LiteralPath $ReportPath

if ($failureCount -gt 0) {
    exit 1
}
exit 0
