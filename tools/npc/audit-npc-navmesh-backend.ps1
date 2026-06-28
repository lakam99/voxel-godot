param(
  [switch]$FailOnLegacy
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Patterns = @(
  @{ Name = "LocalAStarPlanner"; Pattern = "LocalAStarPlannerScript" },
  @{ Name = "HierarchicalRoutePlanner"; Pattern = "HierarchicalRoutePlannerScript" },
  @{ Name = "RouteCoordinatorAdapter"; Pattern = "NpcRouteCoordinatorAdapterScript" },
  @{ Name = "GeneratedWorldNavigationAdapter"; Pattern = "GeneratedWorldNavigationAdapterScript" }
)
$RuntimePaths = @(
  (Join-Path $RepoRoot "scripts\npc_ai"),
  (Join-Path $RepoRoot "scripts\NpcPathing.gd")
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
  matches = $Matches
}

$Json = $Result | ConvertTo-Json -Depth 6
Write-Output $Json

if ($FailOnLegacy -and $Matches.Count -gt 0) {
  exit 1
}
