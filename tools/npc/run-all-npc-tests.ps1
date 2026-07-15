param(
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Seed = "atlas-1492",
    [string]$ReportPath = "",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe"
)

$ErrorActionPreference = "Continue"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$registryPath = Join-Path $PSScriptRoot "npc-suite-registry.json"
$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\all-npc-$($TimeMode.ToLowerInvariant()).json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

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

function To-StringArray {
    param(
        [AllowNull()]
        [object]$Value
    )
    $items = @()
    if ($null -eq $Value) {
        return $items
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
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

function Set-NamedArg {
    param(
        [string[]]$ArgList,
        [string]$Name,
        [string]$Value
    )
    $items = @($ArgList)
    $index = [array]::IndexOf($items, $Name)
    if ($index -ge 0) {
        if ($index + 1 -lt $items.Count) {
            $items[$index + 1] = $Value
        } else {
            $items += $Value
        }
    } else {
        $items += @($Name, $Value)
    }
    return $items
}

function Invoke-EvidenceValidation($Suite, [string]$SuiteReport, [string]$ScreenshotDir) {
    $id = [string]$Suite.id
    $level = [string](Get-PropValue $Suite "evidenceLevel")
    if ($level -eq "") {
        Write-Error "NPC suite $id is missing evidenceLevel in $registryPath"
        return 1
    }
    $claims = @(To-StringArray (Get-PropValue $Suite "acceptanceClaims"))
    $screenshots = @(To-StringArray (Get-PropValue $Suite "requiredScreenshots"))
    $args = @(
        "-ReportPath", $SuiteReport,
        "-RunnerId", $id,
        "-EvidenceLevel", $level,
        "-RegistryPath", $registryPath
    )
    if ($claims.Count -gt 0) {
        $args += @("-AcceptanceClaims", ($claims -join ";"))
    }
    if ($screenshots.Count -gt 0) {
        $args += @("-RequiredScreenshots", ($screenshots -join ";"))
    }
    if ($ScreenshotDir -ne "") {
        $args += @("-ScreenshotDir", $ScreenshotDir)
    }
    if (Bool-Prop $Suite "requiresForbiddenCallSelfScan" $false) {
        $args += "-RequireForbiddenCallSelfScan"
    }
    if (Bool-Prop $Suite "requiresVisualProof" $false) {
        $args += "-RequireVisualProof"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evidenceScript @args | Out-Null
    if ($null -eq $LASTEXITCODE) {
        return 0
    }
    return [int]$LASTEXITCODE
}

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
        $screenshotDir = ""
        if (Bool-Prop $suite "supportsScreenshotDir" $false) {
            $screenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\$id-$($TimeMode.ToLowerInvariant())"
        }
        $runnerArgs = @(To-StringArray -Value (Get-PropValue $suite "defaultArgs"))
        if (Bool-Prop $suite "supportsTimeMode" $true) {
            $runnerArgs = @(Set-NamedArg -ArgList $runnerArgs -Name "-TimeMode" -Value $TimeMode)
        }
        if (Bool-Prop $suite "supportsSeed" $true) {
            $runnerArgs = @(Set-NamedArg -ArgList $runnerArgs -Name "-Seed" -Value $Seed)
        }
        if (Bool-Prop $suite "supportsReportPath" $true) {
            $runnerArgs = @(Set-NamedArg -ArgList $runnerArgs -Name "-ReportPath" -Value $suiteReport)
        }
        if ($screenshotDir -ne "") {
            $runnerArgs = @(Set-NamedArg -ArgList $runnerArgs -Name "-ScreenshotDir" -Value $screenshotDir)
        }
        if ($GodotExe -ne "") {
            $runnerArgs = @(Set-NamedArg -ArgList $runnerArgs -Name "-GodotExe" -Value $GodotExe)
        }

        $suiteStarted = Get-Date
        Write-Host "== NPC suite: $id =="
        $scriptFailed = $false
        try {
            # Suite reports are the durable evidence. Some headed reports are well over
            # 100 MB, so never relay their full JSON through nested aggregate runners.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $commandPath @runnerArgs | Out-Null
        } catch {
            Write-Error $_
            $scriptFailed = $true
        }
        $exitCode = if ($scriptFailed) { 1 } elseif ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $evidenceExitCode = 0
        $evidenceValid = $false
        if (Test-Path -LiteralPath $suiteReport) {
            $evidenceExitCode = Invoke-EvidenceValidation -Suite $suite -SuiteReport $suiteReport -ScreenshotDir $screenshotDir
            $evidenceValid = $evidenceExitCode -eq 0
        } else {
            $evidenceExitCode = 1
        }
        $duration = ((Get-Date) - $suiteStarted).TotalSeconds
        $passed = ($exitCode -eq 0) -and $evidenceValid
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
            evidenceLevel = [string](Get-PropValue $suite "evidenceLevel")
            acceptanceClaims = @(To-StringArray (Get-PropValue $suite "acceptanceClaims"))
            evidenceValid = $evidenceValid
            evidenceExitCode = $evidenceExitCode
            screenshotDir = $screenshotDir
        }
    }
}
finally {
    Pop-Location
}

$report = [pscustomobject]@{
    schemaVersion = 2
    suite = "all-npc"
    evidenceLevel = "integration"
    acceptanceClaims = @()
    timeMode = $TimeMode
    seed = $Seed
    startedUtc = $started.ToUniversalTime().ToString("o")
    finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
    durationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
    resultCount = $results.Count
    failureCount = $failureCount
    results = $results
    registryPath = $registryPath
    testIntegrity = [pscustomobject]@{
        registryId = "npc_focused"
        registryPath = $registryPath
        evidenceLevel = "integration"
        liveGameplayAcceptance = $false
        validationStatus = if ($failureCount -eq 0) { "passed" } else { "failed" }
        stampedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath
Write-Host ("NPC aggregate complete: suites={0}, failures={1}, report={2}" -f $results.Count, $failureCount, $ReportPath)

if ($failureCount -gt 0) {
    exit 1
}
exit 0
