# Mature Nav Phase 01 Navmesh World Service Report

Date: 2026-06-28

Branch: `codex/mature-navmesh-phase1-service`

Controlling specification: `CODEX_MATURE_NAV_PLAN.md`

## Scope

Phase 1 adds deterministic generated-world descriptor input and real NavigationServer region ownership for the new navmesh backend while keeping the live default backend on the existing custom stack.

Implemented:

- Added deterministic chunk region IDs and semantic region IDs to `NavigationBakeDescriptor`.
- Added `NavigationBakeDescriptor.from_tile_snapshot()` for stable per-chunk walkable surfaces, blockers, semantic anchors, and door portals derived from already-generated world facts.
- Added `NavigationBakeDescriptor.from_semantic_region()` for starter-town interior and semantic anchor descriptors.
- Upgraded `NavmeshWorldService` to install one NavigationServer region per loaded descriptor, track region RIDs, free regions on unload, and report install metrics.
- Added navmesh descriptor registration for autonomy semantic regions and tile snapshots when `npc_nav_backend=navmesh`.
- Kept custom backend free of NavigationServer map allocation so normal tutorial/playtest runs do not leak nav map RIDs.
- Added owner-side cleanup in `NpcAutonomySystem` so navmesh RIDs are released before service replacement or node deletion.

Not changed:

- Live NPC route following remains on the custom backend by default.
- `NpcPathing.gd`, behavior tasks, door authority, smart-object ownership, save data, traffic reservations, and CharacterBody motor ownership remain project-owned.
- World RNG order and generated world signatures are unchanged.

## Focused Evidence

Deterministic tile descriptor:

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_tile_snapshot_descriptor_deterministic -ReportPath artifacts\npc\reports\phase1-tile-descriptor-day.json
```

Result: pass, 1 result, 0 failures.

NavigationServer region install:

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_service_installs_navigation_region -ReportPath artifacts\npc\reports\phase1-region-install-day-rerun.json
```

Result: pass, 1 result, 0 failures.

Region unload cleanup, semantic interior registration, register/unregister cleanup, and closest-walkable lookup:

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_chunk_unload_cleans_region -ReportPath artifacts\npc\reports\phase1-chunk-unload-day.json
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_semantic_interior_descriptor_registered -ReportPath artifacts\npc\reports\phase1-semantic-interior-day.json
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_service_register_unregister_descriptor -ReportPath artifacts\npc\reports\phase1-register-unregister-day.json
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_closest_walkable_descriptor_point -ReportPath artifacts\npc\reports\phase1-closest-walkable-day.json
```

Result: all pass, 0 failures.

Autonomy integration and cleanup:

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Day -Case npc_navmesh_autonomy_semantic_backend_registers -ReportPath artifacts\npc\reports\phase1-autonomy-semantic-after-cleanup-day.json
```

Result: pass, 1 result, 0 failures.

Full nav-world suite:

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase1-nav-world-both.json
```

Result: pass, 62 results, 0 failures.

Contract suite:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase1-contract-both.json
```

Result: pass, 40 runs, 0 failures.

Real tutorial isolation after RID cleanup:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\real-tutorial-phase1-predelete-fix-both.json
```

Result: pass, `exitCode=0`, `failureCount=0`, `scriptScan=passed`.

NPC aggregate:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase1-all-npc-both-after-cleanup.json
```

Result: pass, 13 suite results, 0 failures, including `real_tutorial_playthrough`.

Static audit:

```powershell
.\tools\npc\audit-npc-navmesh-backend.ps1
```

Result: detect-mode baseline remains at 10 legacy runtime pattern hits. This is expected before Phase 6 live legacy removal.

Diff hygiene:

```powershell
git diff --check
```

Result: pass, with only Git CRLF warnings.

## Branch Gate

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure -ReportPath artifacts\test-runners\all-test-runners-phase1-branch.json
```

Result: pass, 23 runner results, 0 failures, `stoppedEarly=false`.

Notable branch-gate evidence:

- `world_signature`: pass, baseline matched `artifacts\baselines\world-signature\atlas-1492.json`.
- `visual_manifest`: pass, 26 generated visual assets valid.
- `npc_navigation_integration`: pass.
- `npc_real_tutorial_playthrough`: pass, `exitCode=0`, `scriptScan=passed`.
- `visual_captures`: pass.
- `playtest`: pass, 181 results, 0 failed results, `failed=false` in `playtest-progress.txt`.

## Acceptance Notes

Phase 1 fulfills the navmesh world-service slice of the mature nav plan: generated descriptors can now be converted into deterministic NavigationServer regions, installed regions are observable and cleaned up, chunk unload releases region RIDs, semantic interiors are registered for the navmesh backend, and the custom backend no longer allocates an unused NavigationServer map during normal play.

This phase deliberately stops short of live route-query parity. Phase 2 should add `NavmeshRoutePlanner` and route homes, jobs, guard posts, forage targets, and scripted tutorial goals through `NavigationServer3D.query_path` under `npc_nav_backend=navmesh`, with the legacy backend retained only as a comparison oracle.
