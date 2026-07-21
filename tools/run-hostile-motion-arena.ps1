param(
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [switch]$Verify,
    [switch]$Capture,
    [switch]$DodgeVerify,
    [switch]$WolfAutoAttack,
    [switch]$WolfAutoTrack,
    [switch]$WolfAutoClaw,
    [switch]$WolfAutoPunish,
    [ValidateRange(2.34, 5.40)]
    [double]$WolfStartDistance = 4.35,
    [ValidateRange(0, 1)]
    [int]$SeedIndex = 0,
    [string]$OpponentId = "hostile.shadow",
    [ValidateSet("seeded", "lateral", "rising", "falling", "overhead")]
    [string]$MotionProfile = "seeded",
    [ValidateRange(0.02, 8.18)]
    [double]$CaptureTime = 0.48,
    [string]$ArtifactDir = "artifacts\combat\hostile-motion-arena"
)

$ErrorActionPreference = "Stop"
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot console executable was not found: $GodotExe"
}

if ($Verify -or $Capture -or $DodgeVerify) {
    $ArtifactDir = Join-Path $ProjectPath $ArtifactDir
    New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
    $reportPath = Join-Path $ArtifactDir "hostile-motion-arena-report.json"
    Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    $env:VOXEL_HOSTILE_MOTION_ARENA_AUTOVERIFY = "1"
    $env:VOXEL_HOSTILE_MOTION_ARENA_REPORT = $reportPath
	if ($DodgeVerify) {
		$env:VOXEL_HOSTILE_MOTION_ARENA_AUTODODGE = "1"
	}
	if ($WolfAutoAttack) {
		$env:VOXEL_WOLF_ARENA_AUTOATTACK = "1"
	}
	if ($WolfAutoTrack) {
		$env:VOXEL_WOLF_ARENA_AUTOTRACK = "1"
	}
	if ($WolfAutoClaw) {
		$env:VOXEL_WOLF_ARENA_AUTOCLAW = "1"
	}
	if ($WolfAutoPunish) {
		$env:VOXEL_WOLF_ARENA_AUTOPUNISH = "1"
	}
	if ($OpponentId -like "wolf.*") {
		$env:VOXEL_WOLF_ARENA_START_DISTANCE = $WolfStartDistance.ToString([Globalization.CultureInfo]::InvariantCulture)
	}
    $capturePath = Join-Path $ArtifactDir "hostile-motion-arena.png"
    if ($Capture) {
        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $env:VOXEL_HOSTILE_MOTION_ARENA_CAPTURE = $capturePath
        $env:VOXEL_HOSTILE_MOTION_ARENA_CAPTURE_TIME = $CaptureTime.ToString([Globalization.CultureInfo]::InvariantCulture)
        Write-Host "Running standalone hostile-motion arena visual fixture capture."
		& $GodotExe --path $ProjectPath --resolution 1280x720 --scene res://scenes/testing/HostileMotionArenaTest.tscn -- --arena-opponent $OpponentId --motion-profile $MotionProfile --arena-seed-index $SeedIndex
    } else {
        Write-Host "Running standalone hostile-motion arena fixture verification."
		& $GodotExe --headless --path $ProjectPath --scene res://scenes/testing/HostileMotionArenaTest.tscn -- --arena-opponent $OpponentId --motion-profile $MotionProfile --arena-seed-index $SeedIndex
    }
    Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_AUTOVERIFY -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_REPORT -ErrorAction SilentlyContinue
    Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_CAPTURE -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_CAPTURE_TIME -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_HOSTILE_MOTION_ARENA_AUTODODGE -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_WOLF_ARENA_AUTOATTACK -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_WOLF_ARENA_AUTOTRACK -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_WOLF_ARENA_AUTOCLAW -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_WOLF_ARENA_AUTOPUNISH -ErrorAction SilentlyContinue
	Remove-Item Env:VOXEL_WOLF_ARENA_START_DISTANCE -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $reportPath)) {
        throw "Hostile Motion Arena did not produce a report: $reportPath"
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $report | ConvertTo-Json -Depth 8
    if ($LASTEXITCODE -ne 0 -or $report.status -ne "passed") {
        throw "Hostile Motion Arena verification failed."
    }
    if ($Capture -and -not (Test-Path -LiteralPath $capturePath)) {
        throw "Hostile Motion Arena did not produce a visual capture: $capturePath"
    }
    exit 0
}

Write-Host "Launching the interactive Hostile Motion Arena. Close the Godot window when finished."
& $GodotExe --path $ProjectPath --resolution 1280x720 --scene res://scenes/testing/HostileMotionArenaTest.tscn -- --arena-opponent $OpponentId --motion-profile $MotionProfile --arena-seed-index $SeedIndex
if ($LASTEXITCODE -ne 0) {
    throw "Hostile Motion Arena exited with code $LASTEXITCODE"
}
