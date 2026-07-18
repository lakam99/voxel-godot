param(
    [string]$GodotExe = "C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe",
    [string]$ArtifactDir = "",
    [int]$WatchdogSeconds = 420
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ArtifactDir -eq "") {
    $ArtifactDir = Join-Path $projectPath "artifacts\vegetation\procedural-tree-interaction-matrix"
}
$ArtifactDir = [IO.Path]::GetFullPath($ArtifactDir)
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

# These are six independent headed Main Menu -> New Game -> harvest -> Continue
# runs. Each act uses the natural deterministic tree chosen by the production
# biome sampler; the runner's fixture only relocates the player and grants an
# axe before actual viewport input. Do not reduce this to direct prop removal.
$cases = @(
    @{ key = "broadleaf-mature"; biome = "forest"; architecture = "broadleaf"; ageBand = "mature" },
    @{ key = "broadleaf-old"; biome = "forest"; architecture = "broadleaf"; ageBand = "old" },
    @{ key = "conifer-mature"; biome = "taiga"; architecture = "conifer"; ageBand = "mature" },
    @{ key = "conifer-old"; biome = "taiga"; architecture = "conifer"; ageBand = "old" },
    @{ key = "savanna-mature"; biome = "savanna"; architecture = "savanna"; ageBand = "mature" },
    @{ key = "savanna-old"; biome = "savanna"; architecture = "savanna"; ageBand = "old" }
)

$runner = Join-Path $PSScriptRoot "run-canopy-release-playtest.ps1"
$results = @()
foreach ($case in $cases) {
    $caseDir = Join-Path $ArtifactDir $case.key
    Write-Host "Running $($case.key)"
    & $runner -GodotExe $GodotExe -ArtifactDir $caseDir -WatchdogSeconds $WatchdogSeconds -TargetBiome $case.biome -TargetArchitecture $case.architecture -RequiredAgeBand $case.ageBand
    $exitCode = $LASTEXITCODE
    $savePath = Join-Path $caseDir "save-and-harvest.json"
    $continuePath = Join-Path $caseDir "continue-verify.json"
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $savePath) -or -not (Test-Path -LiteralPath $continuePath)) {
        throw "Family/age interaction case failed: $($case.key)"
    }
    $save = Get-Content -LiteralPath $savePath -Raw | ConvertFrom-Json
    $continued = Get-Content -LiteralPath $continuePath -Raw | ConvertFrom-Json
    if ($true -ne $save.passed -or $true -ne $continued.passed) {
        throw "Family/age interaction reports failed: $($case.key)"
    }
    $results += [pscustomobject]@{
        case = $case.key
        biome = $case.biome
        architecture = $case.architecture
        ageBand = $case.ageBand
        seed = $save.seed
        propId = $save.harvest.propId
        recipeSignature = $save.treeBefore.recipeSignature
        branchCount = $save.treeBefore.branchCount
        foliageClusterCount = $save.treeBefore.foliageClusterCount
        breakTotalMs = $save.harvest.destroyMetrics.totalMs
        saveReport = $savePath
        continueReport = $continuePath
        screenshotDir = (Join-Path $caseDir "screenshots")
    }
}

$reportPath = Join-Path $ArtifactDir "interaction-matrix.json"
$report = [pscustomobject]@{
    runnerId = "procedural_tree_family_age_interaction_matrix"
    evidenceLevel = "headed_gameplay_acceptance"
    passed = $true
    caseCount = $results.Count
    cases = $results
    scope = "Six independent headed production Main Menu runs. Each proves a naturally generated, selected biome/family/age tree is published procedurally, targeted, broken through viewport input, falls/drops, remains removed through chunk reload, and remains removed after save/Continue."
    limitations = "The matrix proves interaction/removal persistence for each requested family and age. Recipe determinism, old-save additive loading, wind, streaming budgets, and NPC safety remain covered by their dedicated non-matrix runners."
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
