param(
    [string]$RegistryPath = "",
    [string]$ReportPath = "",
    [string]$Seed = "atlas-1492",
    [switch]$StopOnFailure,
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Continue"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($RegistryPath -eq "") {
    $RegistryPath = Join-Path $PSScriptRoot "test-runner-registry.json"
}
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\test-runners\all-test-runners-report.json"
}
$RegistryPath = [System.IO.Path]::GetFullPath($RegistryPath)
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null

$registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
$results = @()
$failureCount = 0
$stoppedEarly = $false
$started = Get-Date
$env:VOXEL_TEST_SEED = $Seed

Push-Location $projectPath
try {
    foreach ($runner in $registry.runners) {
        $id = [string]$runner.id
        $command = [string]$runner.command
        $commandPath = if ($command.StartsWith(".\")) { Join-Path $projectPath $command.Substring(2) } else { $command }
        $runnerArgs = @()
        if ($null -ne $runner.args) {
            foreach ($arg in $runner.args) {
                $runnerArgs += [string]$arg
            }
        }
        $seedArgIndex = [array]::IndexOf($runnerArgs, "-Seed")
        if ($seedArgIndex -ge 0) {
            if ($seedArgIndex + 1 -lt $runnerArgs.Count) {
                $runnerArgs[$seedArgIndex + 1] = $Seed
            } else {
                $runnerArgs += $Seed
            }
        }
        $runnerReport = if ($null -ne $runner.reportPath) { Join-Path $projectPath ([string]$runner.reportPath) } else { "" }
        if ($runnerReport -ne "") {
            Remove-Item -LiteralPath $runnerReport -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($runnerReport)) | Out-Null
        }
        Write-Host "== Runner: $id =="
        $runnerStarted = Get-Date
        $scriptFailed = $false
        try {
            if ($commandPath.EndsWith(".ps1", [System.StringComparison]::OrdinalIgnoreCase)) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $commandPath @runnerArgs
            } elseif ($command -eq "node") {
                & $commandPath @runnerArgs
            } else {
                & $commandPath @runnerArgs
            }
        } catch {
            Write-Error $_
            $scriptFailed = $true
        }
        $exitCode = if ($scriptFailed) { 1 } elseif ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        $duration = ((Get-Date) - $runnerStarted).TotalSeconds
        $reportFresh = $true
        if ($runnerReport -ne "") {
            $reportFresh = Test-Path -LiteralPath $runnerReport
        }
        $passed = ($exitCode -eq 0) -and $reportFresh
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
            reportPath = $runnerReport
            reportFresh = $reportFresh
        }
        if (-not $passed -and $StopOnFailure) {
            Write-Error "Stopping after failed runner: $id"
            $stoppedEarly = $true
            break
        }
    }
}
finally {
    Pop-Location
}

$report = [pscustomobject]@{
    schemaVersion = 1
    registryPath = $RegistryPath
    seed = $Seed
    startedUtc = $started.ToUniversalTime().ToString("o")
    finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
    durationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
    resultCount = $results.Count
    failureCount = $failureCount
    stoppedEarly = $stoppedEarly
    stopOnFailure = [bool]$StopOnFailure
    continueOnFailure = [bool]$ContinueOnFailure
    results = $results
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath
Get-Content -LiteralPath $ReportPath

if ($failureCount -gt 0) {
    exit 1
}
exit 0
