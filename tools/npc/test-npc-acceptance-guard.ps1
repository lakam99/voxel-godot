param(
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Continue"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\npc-acceptance-guard-self-test.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$workDir = Join-Path $projectPath "artifacts\npc\guard-self-test"
$guardScript = Join-Path $PSScriptRoot "assert-npc-acceptance-runner-clean.ps1"
$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"

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

function Run-Guard([string]$RunnerPath, [string]$OutReport, [string]$TestId, [string[]]$Allowed = @()) {
    $guardArgs = @(
        "-RunnerPath", $RunnerPath,
        "-ReportPath", $OutReport,
        "-TestId", $TestId,
        "-PassThruJson"
    )
    if ($Allowed.Count -gt 0) {
        $guardArgs += @("-AllowedShortcutPattern", ($Allowed -join ";"))
    }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardScript @guardArgs 2>&1
    $capturedExitCode = if ($null -eq $LASTEXITCODE -or [string]$LASTEXITCODE -eq "") { -1 } else { [int]$LASTEXITCODE }
    return [pscustomobject]@{
        exitCode = $capturedExitCode
        output = $output
    }
}

$realTutorialRunner = Join-Path $projectPath "scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd"
$goHomeRunner = Join-Path $projectPath "scripts\testing\npc\NpcGoHomeVisualPlaytestRunner.gd"
$goHomeAllowed = @(
    'safe_place_npc.*visual_go_home_spawn',
    'player\.global_position\s*=\s*Vector3\(float\(center\.x - 10\)'
)

$tutorialScan = Run-Guard `
    -RunnerPath $realTutorialRunner `
    -OutReport (Join-Path $workDir "real-tutorial-guard.json") `
    -TestId "npc_tutorial_real_knock_repair_sleep_morning_foragers"
Add-Result `
    -Name "guard_passes_real_tutorial_runner" `
    -Passed ($tutorialScan.exitCode -eq 0) `
    -Details "exitCode=$($tutorialScan.exitCode)"

$goHomeScan = Run-Guard `
    -RunnerPath $goHomeRunner `
    -OutReport (Join-Path $workDir "go-home-visual-guard.json") `
    -TestId "npc_go_home_visual_door_traversal" `
    -Allowed $goHomeAllowed
Add-Result `
    -Name "guard_passes_go_home_runner_with_documented_fixture_allowances" `
    -Passed ($goHomeScan.exitCode -eq 0) `
    -Details "exitCode=$($goHomeScan.exitCode)"

$fakeRunner = Join-Path $workDir "FakeAcceptanceRunner.gd"
$fakeReport = Join-Path $workDir "fake-runner-guard-report.json"
@"
extends Node

func _ready() -> void:
    on_door_opened(null)
"@ | Set-Content -LiteralPath $fakeRunner

$fakeScan = Run-Guard `
    -RunnerPath $fakeRunner `
    -OutReport $fakeReport `
    -TestId "fake_acceptance_runner"
$fakeReportHasOffense = $false
$fakeGuardStatus = ""
if (Test-Path -LiteralPath $fakeReport) {
    $fakeReportJson = Get-Content -LiteralPath $fakeReport -Raw | ConvertFrom-Json
    $fakeScan = $fakeReportJson.forbiddenCallSelfScan
    $fakeGuardStatus = [string]$fakeScan.status
    $fakeReportHasOffense = ($fakeGuardStatus -eq "failed") -and ($null -ne $fakeScan.matches) -and ($fakeScan.matches.Count -gt 0)
}
Add-Result `
    -Name "guard_fails_fake_runner_and_reports_offending_line" `
    -Passed $fakeReportHasOffense `
    -Details "guardStatus=$fakeGuardStatus reportHasOffense=$fakeReportHasOffense"

$fixedDelayRunner = Join-Path $workDir "FixedPostLoadDelayRunner.gd"
$fixedDelayReport = Join-Path $workDir "fixed-post-load-delay-guard-report.json"
@"
extends Node

const STARTUP_FRAMES := 80

func _ready() -> void:
    await wait_physics_frames(STARTUP_FRAMES)
"@ | Set-Content -LiteralPath $fixedDelayRunner

$fixedDelayScan = Run-Guard `
    -RunnerPath $fixedDelayRunner `
    -OutReport $fixedDelayReport `
    -TestId "fixed_post_load_delay_acceptance_runner"
$fixedDelayReportHasOffense = $false
$fixedDelayGuardStatus = ""
if (Test-Path -LiteralPath $fixedDelayReport) {
    $fixedDelayReportJson = Get-Content -LiteralPath $fixedDelayReport -Raw | ConvertFrom-Json
    $fixedDelayScan = $fixedDelayReportJson.forbiddenCallSelfScan
    $fixedDelayGuardStatus = [string]$fixedDelayScan.status
    $fixedDelayReportHasOffense = ($fixedDelayGuardStatus -eq "failed") -and ($null -ne $fixedDelayScan.matches) -and ($fixedDelayScan.matches.Count -gt 0)
}
Add-Result `
    -Name "guard_fails_fixed_post_load_startup_delay" `
    -Passed $fixedDelayReportHasOffense `
    -Details "guardStatus=$fixedDelayGuardStatus reportHasOffense=$fixedDelayReportHasOffense"

$report = [pscustomobject]@{
    schemaVersion = 1
    testId = "npc_acceptance_guard_self_test"
    evidenceLevel = "static_audit"
    acceptanceClaims = @()
    finished = $true
    passed = $failureCount -eq 0
    failureCount = $failureCount
    resultCount = $results.Count
    results = $results
    guardReports = [pscustomobject]@{
        realTutorial = Join-Path $workDir "real-tutorial-guard.json"
        goHomeVisual = Join-Path $workDir "go-home-visual-guard.json"
        fakeRunner = $fakeReport
        fixedPostLoadDelay = $fixedDelayReport
    }
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath

& $evidenceScript `
    -ReportPath $ReportPath `
    -RunnerId "npc_acceptance_guard_self_test" `
    -EvidenceLevel "static_audit" `
    -RegistryPath (Join-Path $projectPath "tools\test-runner-registry.json") | Out-Null

Get-Content -LiteralPath $ReportPath
if ($failureCount -gt 0) {
    exit 1
}
exit 0
