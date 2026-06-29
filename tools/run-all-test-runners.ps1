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
$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null

function Get-PropValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

function To-StringArray($Value) {
    $items = @()
    if ($null -eq $Value) {
        return $items
    }
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if ($null -ne $item) {
                $items += [string]$item
            }
        }
        return $items
    }
    $items += [string]$Value
    return $items
}

function Bool-Prop($Object, [string]$Name, [bool]$DefaultValue) {
    $value = Get-PropValue $Object $Name
    if ($null -eq $value) {
        return $DefaultValue
    }
    return [bool]$value
}

function Invoke-EvidenceValidation($Runner, [string]$RunnerReport) {
    $id = [string]$Runner.id
    $level = [string](Get-PropValue $Runner "evidenceLevel")
    if ($level -eq "") {
        Write-Error "Test runner $id is missing evidenceLevel in $RegistryPath"
        return 1
    }
    if ($RunnerReport -eq "") {
        return 0
    }
    $claims = @(To-StringArray (Get-PropValue $Runner "acceptanceClaims"))
    $screenshots = @(To-StringArray (Get-PropValue $Runner "requiredScreenshots"))
    $screenshotDirValue = [string](Get-PropValue $Runner "screenshotDir")
    $screenshotDir = ""
    if ($screenshotDirValue -ne "") {
        $screenshotDir = if ([System.IO.Path]::IsPathRooted($screenshotDirValue)) {
            $screenshotDirValue
        } else {
            Join-Path $projectPath $screenshotDirValue
        }
    }
    $args = @(
        "-ReportPath", $RunnerReport,
        "-RunnerId", $id,
        "-EvidenceLevel", $level,
        "-RegistryPath", $RegistryPath
    )
    if ($claims.Count -gt 0) {
        $args += @("-AcceptanceClaims", ($claims -join ";"))
    }
    if ($screenshots.Count -gt 0) {
        $args += @("-RequiredScreenshots", ($screenshots -join ";"))
    }
    if ($screenshotDir -ne "") {
        $args += @("-ScreenshotDir", $screenshotDir)
    }
    if (Bool-Prop $Runner "requiresForbiddenCallSelfScan" $false) {
        $args += "-RequireForbiddenCallSelfScan"
    }
    if (Bool-Prop $Runner "requiresVisualProof" $false) {
        $args += "-RequireVisualProof"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evidenceScript @args | Out-Null
    if ($null -eq $LASTEXITCODE) {
        return 0
    }
    return [int]$LASTEXITCODE
}

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
        $exitCode = if ($scriptFailed) { 1 } elseif ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $duration = ((Get-Date) - $runnerStarted).TotalSeconds
        $reportFresh = $true
        if ($runnerReport -ne "") {
            $reportFresh = Test-Path -LiteralPath $runnerReport
        }
        $evidenceExitCode = 0
        $evidenceValid = $false
        if ($reportFresh) {
            $evidenceExitCode = Invoke-EvidenceValidation -Runner $runner -RunnerReport $runnerReport
            $evidenceValid = $evidenceExitCode -eq 0
        } else {
            $evidenceExitCode = 1
        }
        $passed = ($exitCode -eq 0) -and $reportFresh -and $evidenceValid
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
            evidenceLevel = [string](Get-PropValue $runner "evidenceLevel")
            acceptanceClaims = @(To-StringArray (Get-PropValue $runner "acceptanceClaims"))
            evidenceValid = $evidenceValid
            evidenceExitCode = $evidenceExitCode
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
    schemaVersion = 2
    registryPath = $RegistryPath
    evidenceLevel = "integration"
    acceptanceClaims = @()
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
    testIntegrity = [pscustomobject]@{
        registryId = "all-test-runners"
        registryPath = $RegistryPath
        evidenceLevel = "integration"
        liveGameplayAcceptance = $false
        validationStatus = if ($failureCount -eq 0) { "passed" } else { "failed" }
        stampedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath
Get-Content -LiteralPath $ReportPath

if ($failureCount -gt 0) {
    exit 1
}
exit 0
