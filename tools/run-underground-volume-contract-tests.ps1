param(
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ReportPath -eq "") {
    $ReportPath = Join-Path $projectPath "artifacts\underground\underground-volume-contract-report.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue

$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_UNDERGROUND_VOLUME_CONTRACT_REPORT = $ReportPath

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$godotOutput = & $GodotExe --headless --path $projectPath --script "res://scripts/testing/UndergroundVolumeContractRunner.gd" 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$godotOutput | ForEach-Object { Write-Output $_ }
Remove-Item Env:\VOXEL_UNDERGROUND_VOLUME_CONTRACT_REPORT -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $ReportPath) {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
    if ([string]$report.evidenceLevel -ne "contract") {
        Write-Error "Underground volume contract report evidenceLevel mismatch: $($report.evidenceLevel)"
        Get-Content -LiteralPath $ReportPath
        exit 1
    }
    Get-Content -LiteralPath $ReportPath
} else {
    Write-Error "Missing underground volume contract report: $ReportPath"
    exit 1
}

exit $exitCode
