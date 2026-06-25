# Phase 03 Report - Multi-Surface Navigation World and Authoritative Invalidation

## 1. Phase Identification

- Phase: 03 - Multi-Surface Navigation World and Authoritative Invalidation
- Branch: `npc-pathfinding/phase-03-navigation-world`
- Base commit before Phase 03 branch changes: `c5143af91695b02323ccaf4af2f2a2171d8a6a14`
- Branch implementation commit: `e18eb8ceaa2b56688d540051ac44bcfc71eb886d`
- Merge commit: `1607ff9d90a7a07387ea83dad50e7e83103e52e1`
- Date: 2026-06-25
- Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
- Scope status: branch implementation gates passed; merged `master` gate passed after the non-fast-forward merge.

## 2. Objective

Phase 03 replaces the one-height XZ navigation snapshot with an event-driven, profile-aware navigation-world service. The new stack must expose lazy, multi-surface topology, exact dirty-tile invalidation, span and edge contracts, semantic regions for generated town facts, stale/unloaded tile states, and bounded build work while keeping existing route behavior green through the migration adapter.

## 3. Pre-Phase State

- `git status --short` before Phase 03 edits showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact remained outside the Phase 03 staged scope.
- Phase 02 had moved active NPC route displacement through the shared `CharacterBody3D` motor, but the legacy route planner still used compatibility topology and remained present by design.
- The old navigation model still lacked a queryable multi-surface tile topology for the new replacement stack.

## 4. Implementation Summary

Phase 03 adds a composed navigation-world layer under `scripts/npc_ai/` without adding a new `Main*.gd` inheritance layer.

`NavigationWorldService` owns the new topology cache, dirty-tile set, tile states, monotonic topology/dynamic/semantic revisions, a build queue, a tile builder, and a semantic registry. It consumes `NavigationChangeBus` events and marks only affected tiles dirty or unloaded. Required tiles return `pending` with the `waiting_for_topology` reason until the build queue publishes tile data.

`NavigationTileBuilder` builds immutable `NavTileData` from supplied tile snapshots. It supports multiple spans per XZ column, filters walkability by traversal profile, builds walk/step/drop edges, rejects diagonal corner cutting unless both adjacent side columns are passable, and registers door traversal placeholders as explicit door edges carrying portal/action metadata.

`NavigationBuildQueue` stores tile build requests by tile key, priority, source revision, and sequence. Processing is bounded by job count and a hard microsecond budget; unfinished work remains pending and increments yield telemetry.

`NavGraphQuery` provides the read facade for tile summaries, column spans, edge lookups, and tile traversability. `NavigationSemanticService` registers stable semantic regions for homes/interiors, roads, guard posts, work anchors, staging areas, settlement bounds, and other current world-generation facts.

Production invalidation is event-driven through `NavigationChangeBus`. Phase 03 wires block creation/removal, terrain edits, prop removal, chunk load/unload, door registration/state, structure metadata, and semantic changes into `NpcAutonomySystem` and `NpcSystem` wrappers. The new stack does not use a scene-tree scan or whole-world hash for normal invalidation.

Generated NPC profile data now publishes semantic regions once per stable semantic ID: home interiors with inside metadata and entrance hints, guard posts, porch staging areas, settlement bounds, two road axes, and central work anchors. These semantics are currently used by the Phase 03 topology tests and will be consumed by later route and behavior phases.

## 5. Files Added, Changed, And Removed

Added navigation contracts:

- `scripts/npc_ai/contracts/NavSpanKey.gd`
- `scripts/npc_ai/contracts/NavSpanData.gd`
- `scripts/npc_ai/contracts/NavEdgeData.gd`
- `scripts/npc_ai/contracts/NavTileData.gd`

Added navigation services:

- `scripts/npc_ai/navigation/NavigationWorldService.gd`
- `scripts/npc_ai/navigation/NavigationTileBuilder.gd`
- `scripts/npc_ai/navigation/NavigationBuildQueue.gd`
- `scripts/npc_ai/navigation/NavGraphQuery.gd`
- `scripts/npc_ai/navigation/NavigationSemanticService.gd`

Changed integration and invalidation:

- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_ai/NpcEnums.gd`
- `scripts/npc_ai/navigation/NavigationChangeBus.gd`
- `scripts/NpcSystem.gd`
- `scripts/MainChunkTerrain.gd`
- `scripts/MainPropFactory.gd`
- `scripts/MainSaveState.gd`

Changed tests and runner registration:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

Added focused runner:

- `tools/npc/run-npc-nav-world-tests.ps1`

Removed files: none.

## 6. Data And API Contracts

`NavSpanKey` defines stable span IDs as `tile:x,y,z:index` and can reconstruct the tile key, cell, and span index from the string form.

`NavSpanData` stores the immutable physical surface record: cell, world position, floor normal and angle, headroom, lateral clearance, blocker kind, semantic IDs, traversal tags, and profile feasibility. `supports_profile()` checks standing height plus margin, radius plus personal-space margin, and maximum floor angle.

`NavEdgeData` stores directed edge data: source span, target span, traversal kind, cost, portal ID, action ID, required capabilities, and metadata. Door placeholders use `TRAVERSAL_KIND_DOOR` and require `open_doors`.

`NavTileData` stores immutable tile output: topology/source/dynamic/semantic revisions, unloaded/stale state, spans indexed by key and column, edges indexed by source span, semantic regions, door portals, build metrics, and a deterministic stable signature.

`NavigationWorldService` exposes `process_change_bus()`, `request_tile()`, `build_next_tiles()`, `build_tile_now()`, `query()`, `register_semantic_region()`, `debug_export()`, and `stats()`.

`NavigationChangeBus` now derives tile keys from event bounds when callers do not supply explicit keys. Production callers still pass explicit keys where they know the edited cell or chunk.

New change kinds in `NpcEnums.gd` cover terrain edits, prop creation/removal, door registration, structure metadata, and semantic changes. `NpcConstants.gd` now records `ARCHITECTURE_VERSION = "phase03_navigation_world"` and build-budget constants.

## 7. Migration And Compatibility Behavior

The legacy route planner remains available through the existing compatibility layer during Phase 03. It is not the source of truth for the new nav-world tests; those tests build/query the new `NavigationWorldService` data directly.

Existing NPC contract, motor, legacy navigation, playtest, story, visual, and world-signature gates remain green on the phase branch. No new `Main*.gd` layer was added.

Runtime save data remains unchanged. Phase 03 adds event notifications during save restoration for restored height edits, removed props, and block clearing so the nav-world service can invalidate affected tiles when those changes replay.

## 8. Focused Test Evidence

Focused and compatibility gates run on branch `npc-pathfinding/phase-03-navigation-world`:

| Command | Result | Evidence |
| --- | --- | --- |
| `.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\nav_world-both.json`; 38 results, 0 failures, 70 assertions, 0.042s |
| `.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\contract-both.json`; 40 results, 0 failures, 110 assertions, 0.075s |
| `.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\motor-both.json`; 36 results, 0 failures, 88 assertions, 0.040s |
| `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both` | Pass | `artifacts\npc\reports\all-npc-both.json`; 3 suites, 0 failures, 3.074s |
| `.\tools\run-npc-navigation-tests.ps1` | Pass | `artifacts\test-runners\npc-navigation-report.json`; 11 results, 0 failures |

Legacy NPC navigation cases passed:

- `npc_nav_capsule_collision_gate`
- `npc_nav_two_npc_door_crossing`
- `npc_nav_home_return_fallback_semantics`
- `npc_nav_reachability_goal_selection`
- `npc_nav_generic_town_npc_homes`
- `npc_nav_generic_job_outings`
- `npc_nav_forager_goal_inventory_hunger`
- `npc_nav_door_open_close_cycle`
- `npc_equipment_and_pathing`
- `npc_route_invalidates_player_block`
- `npc_unreachable_goal_diagnostics`

An earlier repository-wide branch gate failed only `held_torch_terrain_material_flickers`. A direct playtest rerun passed 181/181, and the latest branch all-runner passed all seven runners. The earlier failure is recorded here as an observed visual timing flake, not as waived evidence.

## 9. Day And Night Evidence

`nav_world-both.json` ran every required Phase 03 nav-world case once at canonical day and once at canonical night:

- Day snapshot: `time_of_day = 0.25`, display hour `12:00`.
- Night snapshot: `time_of_day = 0.75`, display hour `00:00`.
- Total nav-world matrix: 19 case IDs x 2 time modes = 38 results, 0 failures.

Required IDs covered in both time modes:

- `npc_navworld_event_block_add_dirty_exact_tiles`
- `npc_navworld_event_block_remove_dirty_exact_tiles`
- `npc_navworld_event_prop_remove_dirty_exact_tiles`
- `npc_navworld_event_terrain_edit_dirty_exact_tiles`
- `npc_navworld_event_chunk_load_unload`
- `npc_navworld_no_scene_scan_revision`
- `npc_navworld_multisurface_bridge`
- `npc_navworld_tunnel_headroom`
- `npc_navworld_stacked_surfaces_disconnected`
- `npc_navworld_profile_clearance_small_large`
- `npc_navworld_slope_step_drop_edges`
- `npc_navworld_corner_cut_rejected`
- `npc_navworld_door_portal_edge_registered`
- `npc_navworld_semantic_home_interior`
- `npc_navworld_semantic_guard_post`
- `npc_navworld_semantic_road_and_work_anchor`
- `npc_navworld_unloaded_tile_not_traversable`
- `npc_navworld_build_budget_yields_and_resumes`
- `npc_navworld_deterministic_tile_output`

Representative nav-world evidence:

- Multi-surface bridge: day tile had 2 surfaces and 2 walkable spans; night tile had 2 surfaces and 2 walkable spans.
- Build budget: day first slice built 1 of 3 pending tiles and yielded; after all slices 3 jobs were built, 0 pending. Night showed the same bounded yield/resume behavior.
- Home interior semantics: day and night returned `home_interior` metadata with `inside = true`, building ID, anchors, and entrance metadata.
- Road/work semantics: day and night returned `road` and `work_anchor` kinds with semantic revision 2.
- Deterministic tile output: day and night compared identical stable signatures across repeated builds.

Visual capture cases from the latest branch all-runner also covered day and dark presentation continuity:

- `town_noon` at 12:00
- `town_sunset` at 18:42
- `forest_midnight` at 00:00
- `forest_midnight_held_light_forward` at 23:48
- `forest_midnight_lights` at 23:48
- `forest_rain` at 16:30
- `mountain_day` at 09:00
- `water_clear` at 12:00
- `water_sunset` at 18:42
- `water_overcast` at 14:30
- `hud_gameplay` at 12:00

## 10. Full All-Runner Evidence On Phase Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 457.701s, finished `2026-06-25T19:22:05.9344669Z`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 3.384s | yes |
| `npc_navigation_legacy` | 0 | Pass | 114.928s | yes |
| `playtest` | 0 | Pass | 211.395s | yes |
| `story_playtest` | 0 | Pass | 61.961s | yes |
| `world_signature` | 0 | Pass | 14.747s | yes |
| `visual_captures` | 0 | Pass | 51.130s | yes |
| `visual_manifest` | 0 | Pass | 0.102s | yes |

Broad report counts:

- `artifacts\test-runners\playtest-report.json`: 181 results, 0 failures.
- `artifacts\test-runners\story-playtest-report.json`: 49 results, 0 failures.
- `artifacts\test-runners\npc-navigation-report.json`: 11 results, 0 failures.

## 11. Full All-Runner Evidence On Merged Master

Merge commit: `1607ff9d90a7a07387ea83dad50e7e83103e52e1`

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Report: `artifacts\test-runners\all-test-runners-report.json`

Result: pass, 7 runners, 0 failures, 473.669s, finished `2026-06-25T19:36:48.6734641Z`.

| Runner | Exit | Result | Duration | Fresh report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | Pass | 3.412s | yes |
| `npc_navigation_legacy` | 0 | Pass | 103.821s | yes |
| `playtest` | 0 | Pass | 235.830s | yes |
| `story_playtest` | 0 | Pass | 63.239s | yes |
| `world_signature` | 0 | Pass | 14.737s | yes |
| `visual_captures` | 0 | Pass | 52.482s | yes |
| `visual_manifest` | 0 | Pass | 0.097s | yes |

The merged-master `nav_world-both.json` report was produced on branch `master` at commit `1607ff9d90a7a07387ea83dad50e7e83103e52e1`; it had 38 results, 0 failures, 70 assertions, and 0.041s duration.

## 12. Performance And Boundedness Metrics

`NavigationBuildQueue` is bounded by `NAV_BUILD_MAX_JOBS_PER_TICK` and `NAV_BUILD_HARD_SLICE_USEC`. Phase 03 tests directly exercised the yield/resume path:

| Time mode | First slice | After remaining slices |
| --- | --- | --- |
| Day | 1 built, 2 pending, 1 yield, last slice 59 usec | 3 built, 0 pending, 2 yields, last slice 38 usec |
| Night | 1 built, 2 pending, 1 yield, last slice 53 usec | 3 built, 0 pending, 2 yields, last slice 32 usec |

Focused nav-world suite duration was 0.042s for 38 day/night results. The all-NPC focused wrapper ran contract, motor, and nav-world suites in 3.074s. The repository-wide branch gate ran in 457.701s.

No queue/cache unbounded growth was observed in the Phase 03 scope. Long-run crowd and route-planner load are assigned to later phases in the controlling specification.

## 13. Determinism And World Signature Evidence

World generation signature was unchanged by Phase 03.

Command path inside all-runner:

```powershell
.\tools\run-world-signature.ps1 -OutputPath artifacts\test-runners\world-signature-atlas-1492.json
```

Evidence:

- Runner result: pass.
- Output: `World signature matches baseline: artifacts\baselines\world-signature\atlas-1492.json`.
- Duration: 14.747s.
- The pre-existing dirty tracked baseline artifact `artifacts/baselines/world-signature/atlas-1492.json` was not part of the Phase 03 staged scope.

`npc_navworld_deterministic_tile_output` also verified identical stable tile signatures across repeated builds under both day and night snapshots.

## 14. Invariant Checklist

| Phase 03 gate | Status | Evidence |
| --- | --- | --- |
| New navigation topology supports multiple vertical surfaces | Pass | `npc_navworld_multisurface_bridge`, `npc_navworld_stacked_surfaces_disconnected`; `NavTileData.spans_by_column` stores multiple span keys per XZ column |
| Exact dirty tiles update from events; unrelated tiles retain revision/cache | Pass | block add/remove, prop remove, terrain edit, and chunk load/unload dirty-tile tests |
| No scene-tree scan or whole-world hash is required for normal invalidation | Pass | static audit returned zero matches in new nav stack for scene/hash invalidation patterns |
| Generated homes have interior anchors and entrance metadata | Pass | `publish_navigation_profile_semantics()` and `npc_navworld_semantic_home_interior` |
| Every span/edge can be checked against a traversal profile | Pass | `NavSpanData.supports_profile()`, `NavEdgeData.required_capabilities`, `npc_navworld_profile_clearance_small_large` |
| Build jobs yield under budget and resume deterministically | Pass | `npc_navworld_build_budget_yields_and_resumes`; 3 jobs built over bounded slices |
| New nav-world tests pass day/night | Pass | `nav_world-both.json`; 38 results, 0 failures |
| Existing behavior continues through compatibility layer | Pass | contract, motor, legacy NPC navigation, playtest, and story reports green |
| World signature remains unchanged | Pass | `world_signature` runner matched baseline |
| Full all-runner gate passes on branch | Pass | `all-test-runners-report.json`; 7 runners, 0 failures |
| Full all-runner gate passes on merged `master` | Pass | `all-test-runners-report.json`; 7 runners, 0 failures at merge commit `1607ff9d90a7a07387ea83dad50e7e83103e52e1` |

## 15. Deviation Register

None.

## 16. Known Issues And Debt

- The route planner and behavior stack still use migration compatibility paths. This is expected Phase 03 debt and is scheduled for later phases.
- Phase 03 door support is a topology placeholder edge with portal/action metadata. Full authoritative door traversal is scheduled for the door phases.
- The earlier all-runner visual flicker failure is recorded in Section 8. The direct playtest rerun and latest branch all-runner passed.
- `git diff --check` reported only line-ending normalization warnings for modified tracked files; no whitespace errors were reported.

No known issue listed here is a Phase 03 gate failure.

## 17. Static Audit Results

### New Navigation Stack Scene Scan And Hash Invalidation

Command:

```powershell
rg -n "get_tree\(|find_children|find_child|hash\(|get_children\(" scripts\npc_ai\navigation scripts\npc_ai\contracts scripts\npc_ai\NpcAutonomySystem.gd
```

Result: zero matches.

### Single-Height Topology Shortcut

Command:

```powershell
rg -n "height_for_cell|terrain_height_cell|height_map|Dictionary\[Vector2i|Vector2i.*height|single.*height" scripts\npc_ai\navigation scripts\npc_ai\contracts scripts\testing\npc\NpcAutonomyTestRunner.gd
```

Result: zero matches.

### Normal-Movement Transform Assignment In New Nav Stack

Command:

```powershell
rg -n "global_position\s*=|position\s*=|transform\s*=|global_transform\s*=" scripts\npc_ai\navigation scripts\npc_ai\contracts scripts\npc_ai\NpcAutonomySystem.gd
```

Result:

- `scripts\npc_ai\contracts\NavSpanData.gd:26`: assigns `span.world_position` while constructing immutable span data from a snapshot. Classification: data population, not node movement or locomotion.

### Prohibited Shortcut Terms In New Nav Stack

Command:

```powershell
rg -n "toggle_door|StaticBody3D|canFight|teleport|height_for_cell|terrain_height_cell|height_map" scripts\npc_ai\navigation scripts\npc_ai\contracts scripts\npc_ai\NpcAutonomySystem.gd
```

Result:

- `scripts\npc_ai\NpcAutonomySystem.gd:69`: `"canFight": context.can_fight` in registration telemetry. Classification: diagnostic context only; not a guard-duty predicate.

### `Main*.gd` Layer Audit

Command:

```powershell
Get-ChildItem -LiteralPath scripts -Filter 'Main*.gd' | Select-Object -ExpandProperty Name
```

Result: only the existing allowed chain was present:

- `Main.gd`
- `MainCharacterState.gd`
- `MainChunkTerrain.gd`
- `MainCore.gd`
- `MainDiscoveryFlow.gd`
- `MainGameLoop.gd`
- `MainHudFlow.gd`
- `MainInteractionFlow.gd`
- `MainInterface.gd`
- `MainPlaytestTools.gd`
- `MainPropFactory.gd`
- `MainRuntimeTools.gd`
- `MainSaveState.gd`
- `MainSetupScene.gd`
- `MainWorldEntities.gd`

### Production Mutation Hook Audit

Command:

```powershell
rg -n "notify_navigation_|emit_change|CHANGE_KIND_|register_semantic_region|publish_navigation_profile_semantics|tile_keys_for_bounds" scripts\MainChunkTerrain.gd scripts\MainPropFactory.gd scripts\MainSaveState.gd scripts\NpcSystem.gd scripts\npc_ai\NpcAutonomySystem.gd scripts\npc_ai\NpcEnums.gd scripts\npc_ai\navigation\NavigationChangeBus.gd
```

Evidence:

- `MainChunkTerrain.gd`: block create, block remove, and door registration notifications.
- `MainPropFactory.gd`: terrain edit, block remove, and prop remove notifications.
- `MainSaveState.gd`: restored height edits, restored removed props, and block clearing notifications.
- `NpcSystem.gd`: public notification wrappers and semantic publishing from NPC profile/town metadata.
- `NpcAutonomySystem.gd`: all notification wrappers emit through `NavigationChangeBus`.
- `NavigationChangeBus.gd`: bounds-derived tile keys and per-tile event records.
- `NpcEnums.gd`: all Phase 03 change kinds present.

## 18. Risk Assessment For Phase 04

Phase 04 will begin using this topology for route planning. The main risks are:

- tile snapshots currently come from tests and event integration surfaces; the Phase 04 planner must define authoritative runtime snapshot inputs before path search depends on them;
- door links are placeholders, so the route planner must preserve explicit traversal actions rather than smoothing them away;
- semantic regions are registered from current NPC/town metadata and may need richer structure IDs as later generation facts become available;
- route repair and hierarchical caching must preserve the event-locality and revision semantics introduced here.

The Phase 03 service exposes query, debug export, revisions, dirty/stale/unloaded state, and deterministic signatures specifically to reduce Phase 04 ambiguity.

## 19. Verdict

Phase 03 passed on its branch and on merged `master`.

Phase 04 may begin only from this updated, green `master`.
