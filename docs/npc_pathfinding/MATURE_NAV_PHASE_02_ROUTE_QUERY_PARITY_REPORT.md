# Mature Nav Phase 02 Route Query Parity Report

Date: 2026-06-28

Branch: `codex/mature-navmesh-phase2-route-parity`

Controlling specification: `CODEX_MATURE_NAV_PLAN.md`

## Scope

Phase 2 adds live navmesh route-query parity behind the existing `npc_nav_backend=navmesh` backend flag. The custom backend remains available for the default path and as the comparison/oracle stack, but navmesh mode now routes through Godot navigation instead of falling back to legacy route search.

Implemented:

- Added `NavmeshRoutePlanner` as the navmesh runtime route adapter for existing NPC route callers.
- Upgraded `NavmeshWorldService.query_route()` from a placeholder to a real `NavigationServer3D.query_path` path query.
- Added closest-walkable snapping, route distance, snapshot revision, query timing, failure counters, and JSON-safe failure payloads to the navmesh service.
- Activated the dedicated NavigationServer map when created and retried an empty first query after forcing a map update, keeping the route source navmesh-only.
- Corrected generated rectangle polygon winding and descriptor closest-point snapping so test and generated surfaces produce stable walkable positions.
- Switched `NpcRouteCoordinatorAdapter` to call `NavmeshRoutePlanner` when `npc_nav_backend=navmesh`.
- Preserved `source`, `legacyFallbackUsed`, and `navmeshRoute` metadata through route-cache compaction so cached navmesh routes remain auditable.
- Added route tests for direct NavigationServer path queries, home/guard/job/forage/scripted goal kinds, and no-legacy-fallback/static provenance.

Not changed:

- NPC behavior, smart-object authority, door policy, save data, traffic reservations, and the `CharacterBody3D` motor remain project-owned.
- The default backend remains unchanged unless `npc_nav_backend=navmesh` is selected.
- Door links, dirty-region rebakes, dynamic obstacle edits, behavior-resource authoring, debug overlays, and legacy removal are later phases.
- World RNG order and generated world signatures are unchanged.

## Focused Evidence

Direct NavigationServer route query:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -Case npc_route_navmesh_query_path_uses_navigation_server -ReportPath artifacts\npc\reports\phase2-navmesh-query-path-both-rerun.json
```

Result: pass, 2 runs, 0 failures. Both day and night returned `source=navmesh`, `queryApi=query_path`, 2 path points, and `pathQueryFailureCount=0`.

Navmesh planner semantic goal kinds:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -Case npc_route_navmesh_planner_goal_kinds -ReportPath artifacts\npc\reports\phase2-navmesh-goal-kinds-both-rerun.json
```

Result: pass, 2 runs, 0 failures. Home, guard, job, forage, and scripted targets all routed with `source=navmesh`, `legacyFallbackUsed=false`, and `pathQueryFailureCount=0`.

No legacy fallback/static provenance:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -Case npc_route_navmesh_adapter_no_legacy_fallback -ReportPath artifacts\npc\reports\phase2-navmesh-adapter-static-both-rerun.json
```

Result: pass, 2 runs, 0 failures. The adapter selects the navmesh planner, `NavmeshRoutePlanner` has no `HierarchicalRoutePlanner` dependency, the service uses `query_path`, and cached routes preserve navmesh provenance fields.

Full route suite:

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase2-route-both-rerun.json
```

Result: pass, 44 results, 84 assertions, 0 failures.

NPC aggregate:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase2-all-npc-both-rerun.json
```

Result: pass, 13 suite results, 0 failures. The included real tutorial playthrough finished with `failures=0`.

Standalone NPC navigation integration:

```powershell
.\tools\run-npc-navigation-tests.ps1 -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase2-npc-navigation-rerun.json
```

Result: pass, 11 checks, 0 failures. The underlying playtest progress reported 181 results and `failed=false`.

World signature:

```powershell
.\tools\run-world-signature.ps1 -Seed atlas-1492
```

Result: pass. The generated signature matched `artifacts\baselines\world-signature\atlas-1492.json`.

Static audit:

```powershell
.\tools\npc\audit-npc-navmesh-backend.ps1
```

Result: detect-mode baseline remains at 10 legacy runtime pattern hits. This is expected before Phase 6 because the custom backend is still retained for default routing and oracle comparison; Phase 2's navmesh path is covered by the no-fallback focused test.

Diff hygiene:

```powershell
git diff --check
```

Result: pass, with only Git CRLF warnings.

## Branch Gate

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure -ReportPath artifacts\test-runners\all-test-runners-phase2-branch.json
```

Result: pass, 23 runner results, 0 failures, `stoppedEarly=false`, duration 506.112s.

Notable branch-gate evidence:

- `world_signature`: pass, baseline matched `artifacts\baselines\world-signature\atlas-1492.json`.
- `visual_manifest`: pass, 26 generated visual assets valid.
- `npc_navigation_integration`: pass.
- `npc_real_tutorial_playthrough`: pass, `exitCode=0`, `failureCount=0`, `scriptScan=passed`.
- `visual_captures`: pass.
- `playtest`: pass, 181 results, 0 failed results, `failed=false` in `playtest-progress.txt`.

## Acceptance Notes

Phase 2 fulfills the route-query parity slice of the mature navigation plan: navmesh backend route requests now use Godot navigation path queries, semantic NPC route targets have direct navmesh coverage, failures and timings are observable, and navmesh mode does not use the legacy route planner as a fallback.

Phase 3 should convert door portals to nav links with smart-object traversal and begin dirty-region rebake handling for terrain, block, prop, and door edits.
