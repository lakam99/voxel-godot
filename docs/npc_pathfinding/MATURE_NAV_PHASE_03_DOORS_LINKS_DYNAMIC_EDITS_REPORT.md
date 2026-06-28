# Mature Nav Phase 3: Doors, Links, And Dynamic Edits

Date: 2026-06-28
Branch: `codex/mature-navmesh-phase3-doors-dynamic-edits`

## Scope

Phase 3 implements the door/link and dirty-region slice from `CODEX_MATURE_NAV_PLAN.md`:

- `NavigationBakeDescriptor` now preserves deterministic `doorLinks` alongside `doorPortals`.
- `NavmeshWorldService` owns NavigationServer link RIDs, door-link debug state, link enable/disable policy, and cleanup on region unload/replacement.
- Closed openable doors remain route candidates and emit smart-object door actions; locked, jammed, destroyed, unloaded, disabled, or non-openable closed doors disable their links.
- Terrain/block/prop/door-registration/semantic edits mark navmesh descriptor regions dirty and queue bounded background rebakes.
- `NpcAutonomySystem` publishes door portal summaries into the navmesh service only when the navmesh backend is active, preserving project-owned door policy and CharacterBody movement ownership.

## Focused Verification

- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_descriptor_keeps_door_links -ReportPath artifacts\npc\reports\phase3-navmesh-descriptor-door-links-both.json`
  - Passed: 2 results, 0 failures.
- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_door_portal_installs_nav_link -ReportPath artifacts\npc\reports\phase3-navmesh-door-link-install-both-rerun.json`
  - Passed: 2 results, 0 failures.
- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_route_through_door_link_emits_action -ReportPath artifacts\npc\reports\phase3-navmesh-door-link-route-action-both.json`
  - Passed: 2 results, 0 failures.
- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_door_state_toggles_nav_link -ReportPath artifacts\npc\reports\phase3-navmesh-door-state-toggle-both.json`
  - Passed: 2 results, 0 failures.
- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_dirty_region_rebuild_after_world_edit -ReportPath artifacts\npc\reports\phase3-navmesh-dirty-region-rebuild-both.json`
  - Passed: 2 results, 0 failures.
- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_chunk_unload_cleans_door_links -ReportPath artifacts\npc\reports\phase3-navmesh-door-link-unload-cleanup-both.json`
  - Passed: 2 results, 0 failures.
- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -Case npc_navmesh_tile_snapshot_descriptor_deterministic -ReportPath artifacts\npc\reports\phase3-navmesh-tile-snapshot-door-links-both.json`
  - Passed: 2 results, 0 failures.

## Suite Verification

- `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase3-nav-world-both-rerun.json`
  - Passed: 74 results, 0 failures.
- `.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase3-route-both.json`
  - Passed: 44 results, 0 failures.
- `.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase3-door-both.json`
  - Passed: 42 results, 0 failures.
- `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase3-all-npc-both.json`
  - Passed: 13 child runners, `failureCount=0`.
  - Real tutorial child report: 7 results, 0 failures.
- `.\tools\run-npc-navigation-tests.ps1`
  - Passed: `npc-navigation-report.json`, 11 results, 0 failures.
- `.\tools\run-world-signature.ps1`
  - Passed: latest `atlas-1492` signature hash matched tracked baseline hash `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.
- `.\tools\npc\audit-npc-navmesh-backend.ps1`
  - Detect-mode baseline unchanged: 10 legacy hits, expected before Phase 6 removal.
- `git diff --check`
  - Passed with CRLF warnings only.

## Branch Gate

- `.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure -ReportPath artifacts\test-runners\all-test-runners-phase3-branch.json`
  - Passed: 23 runners, 0 failures, `stoppedEarly=false`.
  - Duration: 522.042 seconds.
  - Broad playtest: 181 results, `failed=false`.
  - NPC navigation integration: passed.
  - Real tutorial wrapper: `failureCount=0`, script scan passed.
  - World signature, visual manifest, visual captures, story playtest, and broad playtest all passed inside the gate.

## Notes

- A first isolated run of `npc_navmesh_door_portal_installs_nav_link` exposed an Object `get()` misuse in `NavmeshWorldService`; that case was isolated, fixed, and rerun before suite escalation.
- The route query test proves NavigationServer link paths produce door actions with `requiresSmartObject=true`, so navmesh owns reachability/route geometry while door policy and traversal execution remain project-owned.
