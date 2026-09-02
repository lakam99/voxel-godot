[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Codec','PhaseA','PhaseB')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$PhaseADirectory,
    [string]$ProjectPath = (Split-Path $PSScriptRoot -Parent),
    [string]$GodotExe = 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe',
    [int]$Seed = 208159
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$godotPath = (Resolve-Path -LiteralPath $GodotExe).Path
$runtimeCandidate = if ($godotPath.EndsWith('_console.exe', [StringComparison]::OrdinalIgnoreCase)) { $godotPath.Substring(0, $godotPath.Length - '_console.exe'.Length) + '.exe' } else { $godotPath }
$godotRuntimePath = (Resolve-Path -LiteralPath $runtimeCandidate).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$runId = [Guid]::NewGuid().ToString('N')
$ownerPath = Join-Path ([IO.Path]::GetDirectoryName($outputRoot)) ('.' + [IO.Path]::GetFileName($outputRoot) + '.owner-' + $runId)
$ownerStream = $null
$priorEnvironment = @{}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-NoGodot {
    if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*godot*' }).Count -ne 0) {
        throw 'Another Godot instance is running.'
    }
}

function Invoke-BoundedGodot([string]$ScriptPath, [int]$TimeoutSeconds, [hashtable]$Environment) {
    foreach ($key in $Environment.Keys) {
        $priorEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }
    try {
        & (Join-Path $PSScriptRoot 'run-godot-scene-watchdog.ps1') `
            -ProjectPath $projectRoot -GodotExe $godotPath -Headless -Scene '--script' `
            -SceneArguments @((Join-Path $projectRoot $ScriptPath)) -TimeoutSeconds $TimeoutSeconds `
            -StdoutPath (Join-Path $outputRoot 'stdout.txt') -StderrPath (Join-Path $outputRoot 'stderr.txt') `
            -SummaryPath (Join-Path $outputRoot 'watchdog-summary.json') -StopRequestPath (Join-Path $outputRoot 'stop-request.txt')
        if ($LASTEXITCODE -ne 0) { throw "Godot/watchdog failed ($LASTEXITCODE); inspect $outputRoot." }
    } finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $priorEnvironment[$key], 'Process')
            $priorEnvironment.Remove($key)
        }
    }
    $watchdog = Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'watchdog-summary.json') | ConvertFrom-Json
    if ($watchdog.functionalExitCode -ne 0 -or $watchdog.overallExitCode -ne 0 -or $watchdog.timedOut `
            -or $watchdog.forcedCleanup -or -not $watchdog.cleanupPassed -or -not $watchdog.authoritativeZeroProven `
            -or -not $watchdog.finalMembershipKnown -or @($watchdog.finalJobMemberPids).Count -ne 0) {
        throw 'Watchdog evidence is not clean.'
    }
    if ((Get-Item -LiteralPath (Join-Path $outputRoot 'stderr.txt')).Length -ne 0) { throw 'Godot stderr is not empty.' }
    Assert-NoGodot
}

Assert-NoGodot
if (Test-Path -LiteralPath $outputRoot) { throw 'OutputDirectory must be fresh.' }
$ownerStream = [IO.File]::Open($ownerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $ownerBytes = [Text.Encoding]::UTF8.GetBytes($runId)
    $ownerStream.Write($ownerBytes, 0, $ownerBytes.Length)
    $ownerStream.Flush($true)
    New-Item -ItemType Directory -Path $outputRoot -ErrorAction Stop | Out-Null
    $appData = Join-Path $outputRoot 'appdata'
    $localAppData = Join-Path $outputRoot 'localappdata'
    New-Item -ItemType Directory -Path $appData, $localAppData -ErrorAction Stop | Out-Null
    $godotShaBefore = Get-Sha256 $godotPath
    $godotRuntimeShaBefore = Get-Sha256 $godotRuntimePath
    $baseEnvironment = @{ APPDATA = $appData; LOCALAPPDATA = $localAppData; VOXEL_GODOT_EXE = $godotPath; VOXEL_GODOT_RUNTIME_EXE = $godotRuntimePath; VOXEL_STRUCTURAL_COMPOSER_SEED = [string]$Seed; VOXEL_STRUCTURAL_RUN_ID = $runId }

    if ($Mode -eq 'Codec') {
        $reportPath = Join-Path $outputRoot 'report.json'
        $environment = $baseEnvironment.Clone()
        $environment.VOXEL_STRUCTURAL_CODEC_REPORT = $reportPath
        $environment.VOXEL_STRUCTURAL_CODEC_ARTIFACT_DIR = $outputRoot
        Invoke-BoundedGodot 'scripts\testing\buildings\CitadelStructuralComposerCheckpointCodecContract.gd' 120 $environment
        $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
        if (-not $report.passed) { throw 'Codec contract failed.' }
    } elseif ($Mode -eq 'PhaseA') {
        $reportPath = Join-Path $outputRoot 'phase-a-report.json'
        $checkpointPath = Join-Path $outputRoot 'checkpoint.bin'
        $environment = $baseEnvironment.Clone()
        $environment.VOXEL_STRUCTURAL_PHASE_A_REPORT = $reportPath
        $environment.VOXEL_STRUCTURAL_PHASE_A_REPORT_TEMP = Join-Path $outputRoot ('.phase-a-report-' + $runId + '.tmp')
        $environment.VOXEL_STRUCTURAL_CHECKPOINT = $checkpointPath
        $environment.VOXEL_STRUCTURAL_CHECKPOINT_TEMP = Join-Path $outputRoot ('.checkpoint-' + $runId + '.tmp')
        Invoke-BoundedGodot 'scripts\testing\buildings\CitadelStructuralCompletionComposerPhaseAContract.gd' 360 $environment
        $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
        if (-not $report.passed -or $report.runId -ne $runId -or $report.checkpointSha256 -ne (Get-Sha256 $checkpointPath) `
                -or [int64]$report.checkpointSize -ne (Get-Item -LiteralPath $checkpointPath).Length) { throw 'Phase A binding failed.' }
    } else {
        if ([string]::IsNullOrWhiteSpace($PhaseADirectory)) { throw 'PhaseADirectory is required for PhaseB.' }
        $phaseARoot = (Resolve-Path -LiteralPath $PhaseADirectory).Path
        $phaseAReportPath = Join-Path $phaseARoot 'phase-a-report.json'
        $checkpointPath = Join-Path $phaseARoot 'checkpoint.bin'
        $phaseAReport = Get-Content -Raw -LiteralPath $phaseAReportPath | ConvertFrom-Json
        if (-not $phaseAReport.passed -or $phaseAReport.seed -ne $Seed) { throw 'Phase A report is not eligible.' }
        $runId = [string]$phaseAReport.runId
        $baseEnvironment.VOXEL_STRUCTURAL_RUN_ID = $runId
        $reportPath = Join-Path $outputRoot 'phase-b-report.json'
        $environment = $baseEnvironment.Clone()
        $environment.VOXEL_STRUCTURAL_PHASE_A_REPORT = $phaseAReportPath
        $environment.VOXEL_STRUCTURAL_CHECKPOINT = $checkpointPath
        $environment.VOXEL_STRUCTURAL_PHASE_A_REPORT_SHA256 = Get-Sha256 $phaseAReportPath
        $environment.VOXEL_STRUCTURAL_CHECKPOINT_SHA256 = Get-Sha256 $checkpointPath
        $environment.VOXEL_STRUCTURAL_PHASE_B_REPORT = $reportPath
        $environment.VOXEL_STRUCTURAL_PHASE_B_REPORT_TEMP = Join-Path $outputRoot ('.phase-b-report-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        Invoke-BoundedGodot 'scripts\testing\buildings\CitadelStructuralCompletionComposerPhaseBContract.gd' 120 $environment
        $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
        if (-not $report.passed) { throw 'Phase B contract failed.' }
    }
    $godotShaAfter = Get-Sha256 $godotPath
    $godotRuntimeShaAfter = Get-Sha256 $godotRuntimePath
    if ($godotShaBefore -ne $godotShaAfter -or $godotRuntimeShaBefore -ne $godotRuntimeShaAfter) { throw 'Godot launcher or runtime executable changed during the run.' }
} finally {
    if ($null -ne $ownerStream) { $ownerStream.Dispose() }
}
