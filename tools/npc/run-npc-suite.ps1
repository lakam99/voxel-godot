param(
    [string]$Suite = "contract",
    [string]$Case = "",
    [ValidateSet("Day", "Night", "Both", "Transition", "day", "night", "both", "transition")]
    [string]$TimeMode = "Both",
    [string]$Seed = "atlas-1492",
    [string]$GodotExe = "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ReportPath = "",
    [string]$ProgressPath = "",
    [string]$TraceDir = "",
    [string]$ScreenshotDir = "",
    [ValidateSet("", "unit", "contract", "synthetic", "static_audit", "integration", "acceptance_visual")]
    [string]$EvidenceLevel = "",
    [string[]]$AcceptanceClaims = @(),
    [int]$WatchdogSeconds = 45,
    [switch]$Visible
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$timeModeValue = $TimeMode.ToLowerInvariant()
if ($ReportPath -eq "") {
    $caseSuffix = if ($Case -ne "") { "-$($Case -replace '[^A-Za-z0-9_.-]', '_')" } else { "" }
    $ReportPath = Join-Path $projectPath "artifacts\npc\reports\$Suite-$timeModeValue$caseSuffix.json"
}
if ($ProgressPath -eq "") {
    $ProgressPath = Join-Path $projectPath "artifacts\npc\progress\$Suite-$timeModeValue.txt"
}
if ($TraceDir -eq "") {
    $TraceDir = Join-Path $projectPath "artifacts\npc\traces\$Suite-$timeModeValue"
}
if ($ScreenshotDir -eq "") {
    $ScreenshotDir = Join-Path $projectPath "artifacts\npc\screenshots\$Suite-$timeModeValue"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ProgressPath = [System.IO.Path]::GetFullPath($ProgressPath)
$TraceDir = [System.IO.Path]::GetFullPath($TraceDir)
$ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ProgressPath)) | Out-Null
New-Item -ItemType Directory -Force -Path $TraceDir | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -LiteralPath $ReportPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue

$runToken = [guid]::NewGuid().ToString("N")
$branch = (& git -C $projectPath branch --show-current).Trim()
$commit = (& git -C $projectPath rev-parse HEAD).Trim()

$env:VOXEL_PLAYTEST = "1"
$env:VOXEL_TEST_SEED = $Seed
$env:VOXEL_NPC_TEST_SUITE = $Suite
$env:VOXEL_NPC_TEST_CASE = $Case
$env:VOXEL_NPC_TIME_MODE = $timeModeValue
$env:VOXEL_NPC_TEST_SEED = $Seed
$env:VOXEL_NPC_TEST_REPORT = $ReportPath
$env:VOXEL_NPC_TEST_PROGRESS = $ProgressPath
$env:VOXEL_NPC_TEST_TRACE_DIR = $TraceDir
$env:VOXEL_NPC_TEST_SCREENSHOT_DIR = $ScreenshotDir
$env:VOXEL_NPC_TEST_RUN_TOKEN = $runToken
$env:VOXEL_NPC_TEST_WATCHDOG_SECONDS = [string]$WatchdogSeconds
$env:VOXEL_GIT_BRANCH = $branch
$env:VOXEL_GIT_COMMIT = $commit

$args = @("--fixed-fps", "60", "--path", $projectPath, "--scene", "res://scenes/testing/npc/NpcAutonomyTest.tscn")
if (-not $Visible) {
    $args = @("--headless") + $args
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) {
        return
    }
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $GodotExe
$process.StartInfo.WorkingDirectory = $projectPath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = -not $Visible
$process.StartInfo.Arguments = ($args | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
$started = Get-Date
[void]$process.Start()

while (-not $process.HasExited) {
    Start-Sleep -Milliseconds 250
    if (((Get-Date) - $started).TotalSeconds -gt $WatchdogSeconds) {
        Stop-ProcessTree $process
        Write-Error "NPC test watchdog exceeded $WatchdogSeconds seconds"
        if (Test-Path -LiteralPath $ReportPath) {
            Get-Content -LiteralPath $ReportPath
        }
        exit 1
    }
}

$exitCode = $process.ExitCode
if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Missing fresh NPC test report: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
if ($report.runToken -ne $runToken) {
    Write-Error "NPC test report token mismatch; refusing stale report. Expected $runToken, got $($report.runToken)"
    Get-Content -LiteralPath $ReportPath
    exit 1
}
if ($null -eq $report.failureCount) {
    Write-Error "NPC test report missing failureCount"
    Get-Content -LiteralPath $ReportPath
    exit 1
}

$defaultEvidenceLevels = @{
    contract = "contract"
    motor = "contract"
    nav_world = "contract"
    route = "synthetic"
    repair = "synthetic"
    door = "synthetic"
    avoidance = "contract"
    traffic = "synthetic"
    behavior = "synthetic"
    interaction = "contract"
    streaming_save = "contract"
    soak = "synthetic"
}
if ($EvidenceLevel -eq "") {
    if ($defaultEvidenceLevels.ContainsKey($Suite)) {
        $EvidenceLevel = [string]$defaultEvidenceLevels[$Suite]
    } else {
        $EvidenceLevel = "contract"
    }
}
$evidenceScript = Join-Path $projectPath "tools\assert-test-evidence-report.ps1"
$evidenceArgs = @(
    "-ReportPath", $ReportPath,
    "-RunnerId", $Suite,
    "-EvidenceLevel", $EvidenceLevel,
    "-RegistryPath", (Join-Path $projectPath "tools\npc\npc-suite-registry.json")
)
if ($AcceptanceClaims.Count -gt 0) {
    $evidenceArgs += @("-AcceptanceClaims", ($AcceptanceClaims -join ";"))
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $evidenceScript @evidenceArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $ReportPath
    exit $LASTEXITCODE
}
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json

Get-Content -LiteralPath $ReportPath
if ($exitCode -ne 0 -or [int]$report.failureCount -gt 0) {
    exit 1
}

exit 0
