param(
    [string]$ReportPath = "artifacts/npc/reports/npc-legacy-pathfinding-audit.json",
    [switch]$PassThruJson
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ReportPath = [System.IO.Path]::GetFullPath((Join-Path $projectPath $ReportPath))

function Convert-ToRelativePath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($projectPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($projectPath.Length).TrimStart("\", "/")
    }
    return $full
}

function Test-IsIgnoredPath([string]$RelativePath) {
    return $RelativePath -like "scripts\testing\*" -or
        $RelativePath -like "scenes\testing\*" -or
        $RelativePath -like "addons\*" -or
        $RelativePath -like ".godot\*"
}

function Test-IsFunctionDefinition([string]$Line, [string]$FunctionName) {
    return $Line -match ("^\s*func\s+" + [regex]::Escape($FunctionName) + "\s*\(")
}

$rules = @(
    [pscustomobject]@{
        Id = "generated_cell_fallback_flag_write"
        Pattern = '\[\s*["'']safeOpenTerrainGeneratedFallback["'']\s*\]\s*='
        Reason = "Production code must not enable generated-cell bridge fallback."
        FunctionName = ""
    },
    [pscustomobject]@{
        Id = "generated_cell_public_route_call"
        Pattern = '\bplan_generated_cell_route\s*\('
        Reason = "Production routing must not call the generated-cell bridge route API."
        FunctionName = "plan_generated_cell_route"
    },
    [pscustomobject]@{
        Id = "generated_cell_private_route_call"
        Pattern = '\b_plan_generated_cell_bridge_route\s*\('
        Reason = "Production routing must not call the generated-cell bridge implementation."
        FunctionName = "_plan_generated_cell_bridge_route"
    },
    [pscustomobject]@{
        Id = "exact_home_lattice_route_call"
        Pattern = '\b_plan_exact_home_collision_lattice_route\s*\('
        Reason = "Production routing must not call exact-home collision lattice as a separate planner."
        FunctionName = "_plan_exact_home_collision_lattice_route"
    },
    [pscustomobject]@{
        Id = "exact_home_lattice_selector_call"
        Pattern = '\b_should_try_exact_home_collision_lattice_route\s*\('
        Reason = "Production routing must not select exact-home collision lattice recovery."
        FunctionName = "_should_try_exact_home_collision_lattice_route"
    },
    [pscustomobject]@{
        Id = "collision_lattice_repair_call"
        Pattern = '\b_plan_collision_lattice_repair_route\s*\('
        Reason = "Production routing must not repair routes through collision lattice/generated-cell fallback."
        FunctionName = "_plan_collision_lattice_repair_route"
    },
    [pscustomobject]@{
        Id = "fallback_only_generated_bridge_flag"
        Pattern = '\[\s*["'']generatedBridgeFallbackOnly["'']\s*\]\s*='
        Reason = "Production code must not enable generated bridge fallback-only routing."
        FunctionName = ""
    },
    [pscustomobject]@{
        Id = "home_cell_bridge_repair_flag"
        Pattern = '\[\s*["'']allowHomeCellBridgeRepair["'']\s*\]\s*='
        Reason = "Production code must not enable home cell-bridge repair."
        FunctionName = ""
    },
    [pscustomobject]@{
        Id = "runtime_partial_endpoint_status"
        Pattern = 'status\s*:?\=\s*["'']partial["'']|["'']status["'']\s*:\s*["'']partial["'']'
        Reason = "Production runtime routing must not claim partial endpoint success."
        FunctionName = ""
    }
)

$violations = @()
$files = Get-ChildItem -LiteralPath (Join-Path $projectPath "scripts") -Recurse -Filter *.gd -File
foreach ($file in $files) {
    $relativePath = Convert-ToRelativePath $file.FullName
    if (Test-IsIgnoredPath $relativePath) {
        continue
    }
    $lines = @(Get-Content -LiteralPath $file.FullName)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith("#")) {
            continue
        }
        foreach ($rule in $rules) {
            if ($line -match $rule.Pattern) {
                if ($rule.FunctionName -ne "" -and (Test-IsFunctionDefinition $line $rule.FunctionName)) {
                    continue
                }
                $violations += [pscustomobject]@{
                    file = $relativePath
                    lineNumber = $index + 1
                    line = $line.Trim()
                    ruleId = $rule.Id
                    reason = $rule.Reason
                }
            }
        }
    }
}

$report = [pscustomobject]@{
    schemaVersion = 1
    testId = "npc_legacy_pathfinding_static_audit"
    evidenceLevel = "static_audit"
    finished = $true
    passed = $violations.Count -eq 0
    failureCount = if ($violations.Count -eq 0) { 0 } else { 1 }
    resultCount = 1
    ignoredScopes = @("scripts/testing", "scenes/testing", "addons", ".godot")
    ruleCount = $rules.Count
    forbiddenLegacyPathfindingScan = [pscustomobject]@{
        status = if ($violations.Count -eq 0) { "passed" } else { "failed" }
        matches = $violations
    }
    results = @([pscustomobject]@{
        name = "npc_legacy_pathfinding_static_audit"
        passed = $violations.Count -eq 0
        details = if ($violations.Count -eq 0) { "no active production generated-cell, exact-lattice, or partial-endpoint fallback source found" } else { "found $($violations.Count) active legacy pathfinding source matches" }
    })
}

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath

if ($PassThruJson) {
    Get-Content -LiteralPath $ReportPath
}

if ($violations.Count -gt 0) {
    Get-Content -LiteralPath $ReportPath
    exit 1
}

exit 0
