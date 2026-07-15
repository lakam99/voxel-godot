param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\tutorial-town\tutorial-actor-registration-contract.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_TUTORIAL_ACTOR_REGISTRATION_CONTRACT_REPORT = $ReportPath
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/TutorialActorRegistrationContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_TUTORIAL_ACTOR_REGISTRATION_CONTRACT_REPORT -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing tutorial actor registration contract report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "tutorial_actor_registration_contract" -or [string]$report.evidenceLevel -ne "contract") {
    Write-Error "Tutorial actor registration report identity mismatch"
    exit 1
}
[pscustomobject]@{
    runnerId = $report.runnerId
    passed = $report.passed
    resultCount = $report.resultCount
    failureCount = $report.failureCount
    reportPath = $ReportPath
} | ConvertTo-Json
if (($exitCode -ne 0) -or ($true -ne $report.passed)) {
    exit 1
}
exit 0
