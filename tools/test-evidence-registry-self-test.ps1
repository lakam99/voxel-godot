param(
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Continue"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\test-runners\test-evidence-registry-self-test.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$workDir = Join-Path $projectPath "artifacts\test-runners\evidence-self-test"
$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
$registryPath = Join-Path $projectPath "tools\test-runner-registry.json"

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$results = @()
$failureCount = 0

function Add-Result([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{
        name = $Name
        passed = $Passed
        details = $Details
    }
    if (-not $Passed) {
        $script:failureCount += 1
    }
}

function Run-Evidence([string[]]$EvidenceArgs) {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evidenceScript @EvidenceArgs 2>&1
    return [pscustomobject]@{
        exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        output = $output
    }
}

$syntheticClaimReport = Join-Path $workDir "synthetic-claims-acceptance.json"
[pscustomobject]@{
    schemaVersion = 1
    testId = "synthetic_claims_acceptance"
    evidenceLevel = "acceptance_visual"
    acceptanceClaims = @("fake_live_door_traversal")
    finished = $true
    passed = $true
    failureCount = 0
    resultCount = 0
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $syntheticClaimReport
$syntheticResult = Run-Evidence -EvidenceArgs @(
    "-ReportPath", $syntheticClaimReport,
    "-RunnerId", "synthetic_claims_acceptance",
    "-EvidenceLevel", "synthetic",
    "-RegistryPath", $registryPath
)
Add-Result `
    -Name "synthetic_report_claiming_acceptance_fails" `
    -Passed ($syntheticResult.exitCode -ne 0) `
    -Details "exitCode=$($syntheticResult.exitCode)"

$screenshotDir = Join-Path $workDir "good-acceptance-screenshots"
New-Item -ItemType Directory -Force -Path $screenshotDir | Out-Null
foreach ($fileName in @("spawn.png", "door_open.png")) {
    Set-Content -LiteralPath (Join-Path $screenshotDir $fileName) -Value "placeholder screenshot proof"
}
$goodAcceptanceReport = Join-Path $workDir "good-acceptance.json"
[pscustomobject]@{
    schemaVersion = 1
    testId = "good_acceptance"
    finished = $true
    passed = $true
    failureCount = 0
    resultCount = 1
    forbiddenCallSelfScan = [pscustomobject]@{ status = "passed" }
    captures = @([pscustomobject]@{ stage = "spawn"; saved = $true })
    timeline = @([pscustomobject]@{ event = "door_open"; time = 1.0 })
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $goodAcceptanceReport
$goodAcceptanceResult = Run-Evidence -EvidenceArgs @(
    "-ReportPath", $goodAcceptanceReport,
    "-RunnerId", "good_acceptance",
    "-EvidenceLevel", "acceptance_visual",
    "-AcceptanceClaims", "proves_real_behavior",
    "-RequiredScreenshots", "spawn.png;door_open.png",
    "-ScreenshotDir", $screenshotDir,
    "-RegistryPath", $registryPath,
    "-RequireForbiddenCallSelfScan",
    "-RequireVisualProof"
)
Add-Result `
    -Name "acceptance_report_with_guard_screenshots_and_timeline_passes" `
    -Passed ($goodAcceptanceResult.exitCode -eq 0) `
    -Details "exitCode=$($goodAcceptanceResult.exitCode)"

$integrationVisualReport = Join-Path $workDir "integration-visual-without-claims.json"
[pscustomobject]@{
    schemaVersion = 1
    testId = "integration_visual_without_claims"
    evidenceLevel = "integration"
    acceptanceClaims = @()
    finished = $true
    passed = $true
    failureCount = 0
    resultCount = 1
    captures = @([pscustomobject]@{ stage = "spawn"; saved = $true })
    timeline = @([pscustomobject]@{ event = "camera_pose"; time = 1.0 })
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $integrationVisualReport
$integrationVisualResult = Run-Evidence -EvidenceArgs @(
    "-ReportPath", $integrationVisualReport,
    "-RunnerId", "integration_visual_without_claims",
    "-EvidenceLevel", "integration",
    "-RequiredScreenshots", "spawn.png;door_open.png",
    "-ScreenshotDir", $screenshotDir,
    "-RegistryPath", $registryPath,
    "-RequireVisualProof"
)
Add-Result `
    -Name "integration_visual_report_without_acceptance_claims_passes" `
    -Passed ($integrationVisualResult.exitCode -eq 0) `
    -Details "exitCode=$($integrationVisualResult.exitCode)"

$badGuardReport = Join-Path $workDir "bad-guard-acceptance.json"
[pscustomobject]@{
    schemaVersion = 1
    testId = "bad_guard_acceptance"
    finished = $true
    passed = $true
    failureCount = 0
    resultCount = 1
    forbiddenCallSelfScan = [pscustomobject]@{ status = "failed" }
    captures = @([pscustomobject]@{ stage = "spawn"; saved = $true })
    timeline = @([pscustomobject]@{ event = "door_open"; time = 1.0 })
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $badGuardReport
$badGuardResult = Run-Evidence -EvidenceArgs @(
    "-ReportPath", $badGuardReport,
    "-RunnerId", "bad_guard_acceptance",
    "-EvidenceLevel", "acceptance_visual",
    "-AcceptanceClaims", "proves_real_behavior",
    "-RequiredScreenshots", "spawn.png;door_open.png",
    "-ScreenshotDir", $screenshotDir,
    "-RegistryPath", $registryPath,
    "-RequireForbiddenCallSelfScan",
    "-RequireVisualProof"
)
Add-Result `
    -Name "acceptance_report_with_failed_guard_fails" `
    -Passed ($badGuardResult.exitCode -ne 0) `
    -Details "exitCode=$($badGuardResult.exitCode)"

$report = [pscustomobject]@{
    schemaVersion = 1
    testId = "test_evidence_registry_self_test"
    evidenceLevel = "static_audit"
    acceptanceClaims = @()
    finished = $true
    passed = $failureCount -eq 0
    failureCount = $failureCount
    resultCount = $results.Count
    results = $results
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath

& $evidenceScript `
    -ReportPath $ReportPath `
    -RunnerId "test_evidence_registry_self_test" `
    -EvidenceLevel "static_audit" `
    -RegistryPath $registryPath | Out-Null

Get-Content -LiteralPath $ReportPath
if ($failureCount -gt 0) {
    exit 1
}
exit 0
