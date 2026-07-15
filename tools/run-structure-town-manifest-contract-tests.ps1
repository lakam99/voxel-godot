param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\tutorial-town\structure-town-manifest-contract.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_STRUCTURE_TOWN_MANIFEST_REPORT = $ReportPath
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/StructureTownManifestContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
Remove-Item Env:\VOXEL_STRUCTURE_TOWN_MANIFEST_REPORT -ErrorAction SilentlyContinue
if ($godotOutput) {
    $godotOutput | ForEach-Object { Write-Host $_ }
}
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing StructureSystem town manifest report: $ReportPath"
    exit 1
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ([string]$report.runnerId -ne "structure_town_manifest_contract" -or [string]$report.evidenceLevel -ne "contract") {
    Write-Error "StructureSystem town manifest report identity mismatch"
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
