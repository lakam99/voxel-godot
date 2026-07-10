param(
    [string]$ReportPath = "artifacts/npc/reports/npc-route-state-writer-audit.json",
    [switch]$PassThruJson
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ReportPath = [System.IO.Path]::GetFullPath((Join-Path $projectPath $ReportPath))

$allowedFiles = @(
    "scripts\npc_ai\routing\NpcRouteStateStore.gd",
    "scripts\npc_ai\routing\NpcRouteAuthority.gd",
    "scripts\npc_ai\routing\NpcRouteAuthorityV2.gd"
)

$rules = @(
    [pscustomobject]@{ Id = "route_status_entry_write"; Pattern = '\[\s*["'']routeStatus["'']\s*\]\s*='; Reason = "routeStatus must be written through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_reason_entry_write"; Pattern = '\[\s*["'']routeReason["'']\s*\]\s*='; Reason = "routeReason must be written through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_lease_entry_write"; Pattern = '\[\s*["'']routeLease["'']\s*\]\s*='; Reason = "routeLease must be written through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_lease_id_entry_write"; Pattern = '\[\s*["'']routeLeaseId["'']\s*\]\s*='; Reason = "routeLeaseId must be written through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_lease_generation_entry_write"; Pattern = '\[\s*["'']routeLeaseGeneration["'']\s*\]\s*='; Reason = "routeLeaseGeneration must be written through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_lease_entry_erase"; Pattern = '\.erase\(\s*["'']routeLease["'']\s*\)'; Reason = "routeLease must be cleared through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_lease_id_entry_erase"; Pattern = '\.erase\(\s*["'']routeLeaseId["'']\s*\)'; Reason = "routeLeaseId must be cleared through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_status_meta_write"; Pattern = 'set_meta\s*\(\s*["'']npc_route_status["'']'; Reason = "npc_route_status metadata must be published through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_reason_meta_write"; Pattern = 'set_meta\s*\(\s*["'']npc_route_reason["'']'; Reason = "npc_route_reason metadata must be published through NpcRouteStateStore." },
    [pscustomobject]@{ Id = "route_authority_state_write"; Pattern = '\[\s*["'']routeAuthorityState["'']\s*\]\s*='; Reason = "routeAuthorityState must be written by the route authority/store only." },
    [pscustomobject]@{ Id = "route_authority_reason_write"; Pattern = '\[\s*["'']routeAuthorityReason["'']\s*\]\s*='; Reason = "routeAuthorityReason must be written by the route authority/store only." },
    [pscustomobject]@{ Id = "route_probe_certificate_write"; Pattern = '\[\s*["'']probeCertificate["'']\s*\]\s*='; Reason = "route probe proof must be written by the route authority/store only." }
)

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

function Test-IsAllowedPath([string]$RelativePath) {
    foreach ($allowed in $allowedFiles) {
        if ($RelativePath -ieq $allowed) {
            return $true
        }
    }
    return $false
}

$violations = @()
$files = Get-ChildItem -LiteralPath (Join-Path $projectPath "scripts") -Recurse -Filter *.gd -File
foreach ($file in $files) {
    $relativePath = Convert-ToRelativePath $file.FullName
    if (Test-IsIgnoredPath $relativePath) {
        continue
    }
    if (Test-IsAllowedPath $relativePath) {
        continue
    }
    $lines = @(Get-Content -LiteralPath $file.FullName)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line.TrimStart().StartsWith("#")) {
            continue
        }
        foreach ($rule in $rules) {
            if ($line -match $rule.Pattern) {
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
    testId = "npc_route_state_writer_static_audit"
    evidenceLevel = "static_audit"
    finished = $true
    passed = $violations.Count -eq 0
    failureCount = if ($violations.Count -eq 0) { 0 } else { 1 }
    resultCount = 1
    allowedFiles = $allowedFiles
    ignoredScopes = @("scripts/testing", "scenes/testing", "addons", ".godot")
    ruleCount = $rules.Count
    forbiddenRouteStateWriterScan = [pscustomobject]@{
        status = if ($violations.Count -eq 0) { "passed" } else { "failed" }
        matches = $violations
    }
    results = @([pscustomobject]@{
        name = "npc_route_state_writer_static_audit"
        passed = $violations.Count -eq 0
        details = if ($violations.Count -eq 0) { "route state writers are locked to approved authority files" } else { "found $($violations.Count) unauthorized route-state writes" }
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
