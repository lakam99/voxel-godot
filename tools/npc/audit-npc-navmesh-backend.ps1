param(
  [switch]$FailOnLegacy
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Patterns = @(
  @{ Name = "LocalAStarPlanner"; Pattern = "LocalAStarPlannerScript" },
  @{ Name = "HierarchicalRoutePlanner"; Pattern = "HierarchicalRoutePlannerScript" }
)
$LiveRuntimeFiles = @(
  "scripts\NpcPathing.gd",
  "scripts\npc_ai\NpcAutonomySystem.gd",
  "scripts\npc_ai\routing\NpcNavigationCoordinator.gd",
  "scripts\npc_ai\routing\NpcRouteCoordinatorAdapter.gd",
  "scripts\npc_ai\movement\NpcRouteMovementController.gd",
  "scripts\npc_ai\behavior\NpcSemanticGoalPlanner.gd",
  "scripts\npc_ai\behavior\NpcTaskPlanner.gd",
  "scripts\npc_ai\behavior\NpcPlanExecutor.gd"
)
$RuntimePaths = @(
  $LiveRuntimeFiles | ForEach-Object { Join-Path $RepoRoot $_ }
)

$Matches = @()
foreach ($item in $Patterns) {
  $hits = & rg --line-number --fixed-strings $item.Pattern @RuntimePaths 2>$null
  foreach ($hit in $hits) {
    $Matches += [ordered]@{
      name = $item.Name
      pattern = $item.Pattern
      hit = $hit
    }
  }
}

$Result = [ordered]@{
  schemaVersion = 1
  mode = if ($FailOnLegacy) { "fail_on_legacy" } else { "detect" }
  legacyPatternCount = $Matches.Count
  failOnLegacy = [bool]$FailOnLegacy
  scannedFiles = $LiveRuntimeFiles
  matches = $Matches
}

$Json = $Result | ConvertTo-Json -Depth 6
Write-Output $Json

if ($FailOnLegacy -and $Matches.Count -gt 0) {
  exit 1
}
