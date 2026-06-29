param(
    [Parameter(Mandatory = $true)]
    [string]$RunnerPath,
    [Parameter(Mandatory = $true)]
    [string]$ReportPath,
    [string]$TestId = "npc_acceptance_runner_static_guard",
    [string[]]$AllowedShortcutPattern = @(),
    [switch]$PassThruJson
)

$ErrorActionPreference = "Stop"

$RunnerPath = [System.IO.Path]::GetFullPath($RunnerPath)
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$normalizedAllowedShortcutPattern = @()
foreach ($pattern in $AllowedShortcutPattern) {
    foreach ($part in (([string]$pattern) -split ';')) {
        if ($part -ne "") {
            $normalizedAllowedShortcutPattern += $part
        }
    }
}
$AllowedShortcutPattern = $normalizedAllowedShortcutPattern

if (-not (Test-Path -LiteralPath $RunnerPath)) {
    Write-Error "Acceptance runner source does not exist: $RunnerPath"
    exit 1
}

$rules = @(
    [pscustomobject]@{
        Id = "direct_tutorial_door_progress"
        Pattern = '\bon_door_opened\b'
        Reason = "Acceptance tests must open doors through real input/interaction paths, not tutorial progression callbacks."
    },
    [pscustomobject]@{
        Id = "direct_tutorial_interaction"
        Pattern = '\binteract_with\b'
        Reason = "Acceptance tests must interact through player proximity, prompts, raycasts, and HUD flow."
    },
    [pscustomobject]@{
        Id = "direct_tutorial_completion"
        Pattern = '\bcomplete_step\b'
        Reason = "Acceptance tests must observe objective completion through gameplay."
    },
    [pscustomobject]@{
        Id = "direct_block_progress"
        Pattern = '\bon_block_placed\b'
        Reason = "Acceptance tests must place blocks through the placement system when placement is part of the claim."
    },
    [pscustomobject]@{
        Id = "direct_sleep_or_bed_progress"
        Pattern = '\b(on_bed_used|sleep_at_bed)\b'
        Reason = "Acceptance tests must use beds through real player interaction when sleep is part of the claim."
    },
    [pscustomobject]@{
        Id = "inventory_grant"
        Pattern = '\binventory_system\.add_item\s*\('
        Reason = "Acceptance tests must not grant progression resources during the act phase."
    },
    [pscustomobject]@{
        Id = "direct_npc_movement_helper"
        Pattern = '\bmove_npc\b'
        Reason = "Acceptance tests must let behavior, routing, and the CharacterBody motor drive NPC movement."
    },
    [pscustomobject]@{
        Id = "direct_door_service"
        Pattern = '\b(request_door_state|request_crossing)\b'
        Reason = "Acceptance tests must not directly drive door services when proving live door traversal."
    },
    [pscustomobject]@{
        Id = "fake_inside_home_metadata"
        Pattern = 'set_meta\s*\(\s*["'']npc_inside_home["'']'
        Reason = "Acceptance tests must not mark home arrival through metadata."
    },
    [pscustomobject]@{
        Id = "fake_scripted_arrival_metadata"
        Pattern = 'set_meta\s*\(\s*["'']npc_scripted_arrived["'']'
        Reason = "Acceptance tests must not mark scripted arrival through metadata."
    },
    [pscustomobject]@{
        Id = "actor_transform_write"
        Pattern = '\b(player|body|npc_body|actor|mira_body|rowan_body|niko_body|sera_body)\.global_position\s*='
        Reason = "Acceptance tests must not teleport actors during the behavior being proven."
    },
    [pscustomobject]@{
        Id = "safe_place_npc"
        Pattern = '\bsafe_place_npc\b'
        Reason = "Acceptance tests may only use safe placement as narrowly documented fixture setup."
    },
    [pscustomobject]@{
        Id = "source_scan_acceptance"
        Pattern = '\bread_text\s*\('
        Reason = "Acceptance tests must not pass by scanning source text instead of exercising behavior."
    }
)

function Test-AllowedShortcutLine([string]$Line) {
    foreach ($pattern in $AllowedShortcutPattern) {
        if ($Line -match $pattern) {
            return $true
        }
    }
    return $false
}

$lines = @(Get-Content -LiteralPath $RunnerPath)
$violations = @()
for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]
    foreach ($rule in $rules) {
        if ($line -match $rule.Pattern) {
            if (Test-AllowedShortcutLine $line) {
                continue
            }
            $violations += [pscustomobject]@{
                lineNumber = $index + 1
                line = $line.Trim()
                ruleId = $rule.Id
                reason = $rule.Reason
            }
        }
    }
}

$scan = [pscustomobject]@{
    status = if ($violations.Count -eq 0) { "passed" } else { "failed" }
    runnerPath = $RunnerPath
    testId = $TestId
    ruleCount = $rules.Count
    allowedShortcutPattern = $AllowedShortcutPattern
    matches = $violations
}

if ($violations.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
    $guardReport = [pscustomobject]@{
        schemaVersion = 1
        testId = $TestId
        finished = $true
        passed = $false
        failureCount = 1
        resultCount = 1
        forbiddenCallSelfScan = $scan
        results = @([pscustomobject]@{
            name = "npc_acceptance_runner_static_guard"
            passed = $false
            details = "acceptance runner source contains forbidden shortcut calls"
        })
    }
    $guardReport | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath
    Get-Content -LiteralPath $ReportPath
    exit 1
}

if ($PassThruJson) {
    $scan | ConvertTo-Json -Depth 12
}

exit 0
