param(
    [string]$ReportPath = "artifacts/underground-volume-audit.json"
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedReportPath = [System.IO.Path]::GetFullPath((Join-Path $projectPath $ReportPath))
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($resolvedReportPath)) | Out-Null

$legacy = "ca" + "ve"
$checks = @(
    [pscustomobject]@{
        Id = "world-generation-legacy-feature-api"
        Files = @("scripts/WorldGenerationSystem.gd")
        ForbiddenPattern = "func $($legacy)_feature_|find_$($legacy)_biome_sample|$($legacy)Value|$($legacy)_features_near_world"
        Requirement = "WorldGenerationSystem must expose underground volume through sample_world and find_underground_air_sample, not legacy feature records."
    },
    [pscustomobject]@{
        Id = "production-legacy-feature-authority"
        Files = @("scripts/MainCore.gd", "scripts/MainPlaytestTools.gd", "scripts/MainSaveState.gd", "scripts/StructureSystem.gd", "scripts/SubsurfaceSystem.gd")
        ForbiddenPattern = "find_$($legacy)_biome_sample|$($legacy)_feature|$($legacy)Id|VOXEL_$($legacy.ToUpper())"
        Requirement = "Production systems must not depend on legacy underground feature IDs, regions, launch variables, or geometry."
    },
    [pscustomobject]@{
        Id = "underground-sampler-entrypoints"
        Files = @("scripts/WorldGenerationSystem.gd")
        RequiredPattern = "func sample_world|func find_underground_air_sample|UNDERGROUND_GENERATED_DEPTH_CELLS := 32|UNDERGROUND_AIR_BIOME := `"underground_air`""
        Requirement = "Unified underground generation must expose sample_world, find_underground_air_sample, the 32-cell depth cap, and the underground_air state."
    }
)

$findings = @()
foreach ($check in $checks) {
    foreach ($relativePath in $check.Files) {
        $path = Join-Path $projectPath $relativePath
        if (-not (Test-Path -LiteralPath $path)) {
            $findings += [pscustomobject]@{
                id = $check.Id
                file = $relativePath
                type = "missing_file"
                requirement = $check.Requirement
            }
            continue
        }
        $source = Get-Content -LiteralPath $path -Raw
        if ($check.PSObject.Properties["ForbiddenPattern"] -and $check.ForbiddenPattern -ne "") {
            if ($source -match $check.ForbiddenPattern) {
                $findings += [pscustomobject]@{
                    id = $check.Id
                    file = $relativePath
                    type = "forbidden_pattern"
                    pattern = $check.ForbiddenPattern
                    requirement = $check.Requirement
                }
            }
        }
        if ($check.PSObject.Properties["RequiredPattern"] -and $check.RequiredPattern -ne "") {
            foreach ($pattern in ($check.RequiredPattern -split "\|")) {
                if ($source -notmatch $pattern) {
                    $findings += [pscustomobject]@{
                        id = $check.Id
                        file = $relativePath
                        type = "missing_required_pattern"
                        pattern = $pattern
                        requirement = $check.Requirement
                    }
                }
            }
        }
    }
}

$report = [pscustomobject]@{
    schemaVersion = 1
    runnerId = "underground_volume_static_audit"
    evidenceLevel = "static_audit"
    status = if ($findings.Count -eq 0) { "passed" } else { "failed" }
    findingCount = $findings.Count
    findings = $findings
}
$report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $resolvedReportPath

if ($findings.Count -gt 0) {
    Get-Content -LiteralPath $resolvedReportPath
    exit 1
}

Get-Content -LiteralPath $resolvedReportPath
exit 0
