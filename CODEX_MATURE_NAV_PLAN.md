\# Mature NPC Navigation And Automation Plan



\## Summary



Migrate live NPC routing from the custom voxel A\* stack to Godot `NavigationServer3D`/navmesh-backed path queries, delivered through phased green-master gates. Keep the existing NPC behavior, smart-object, door, traffic, and motor concepts, but make navmesh data the authoritative traversal layer.



Chosen defaults:

\- Routing strategy: full navmesh migration.

\- Delivery: phased gates, one clean merge per phase.

\- Primary success bar: behavioral reliability first, then scale/tooling.



Godot basis: runtime navmesh baking/querying and performance constraints follow the official docs for \[navigation meshes](https://docs.godotengine.org/en/latest/tutorials/navigation/navigation\_using\_navigationmeshes.html), \[NavigationServer3D](https://docs.godotengine.org/en/stable/classes/class\_navigationserver3d.html), \[NavigationAgent3D](https://docs.godotengine.org/en/stable/classes/class\_navigationagent3d.html), and \[navigation performance](https://docs.godotengine.org/en/latest/tutorials/navigation/navigation\_optimizing\_performance.html).



\## Key Changes



\- Add `NavmeshWorldService` as the sole live pathfinding authority.

&#x20; - Own one NavigationServer map for NPCs.

&#x20; - Own chunk/structure navmesh region RIDs, door/link RIDs, dynamic obstacle state, bake queues, and debug snapshots.

&#x20; - Expose: `register\_chunk\_descriptor`, `unregister\_chunk`, `set\_door\_portal\_state`, `query\_route`, `closest\_walkable`, `actor\_path\_status`, `debug\_snapshot`, `stats`.



\- Replace inferred cell navigation with generated nav descriptors.

&#x20; - World/town/building/prop generation emits deterministic `NavigationBakeDescriptor` data at generation time.

&#x20; - Descriptors include walkable surfaces, blockers, interior volumes, porch/threshold markers, door portals, work slots, forage slots, guard posts, and semantic anchors.

&#x20; - Navmesh bake geometry is built from simple CPU-side boxes/polygons, not rendered meshes, to avoid GPU/RenderingServer stalls.



\- Cut live NPC movement over to navmesh routes.

&#x20; - `NpcPathing.gd` remains the facade for compatibility, but delegates live route queries to `NavmeshWorldService`.

&#x20; - `HierarchicalRoutePlanner`, `LocalAStarPlanner`, and custom runtime graph search are removed from live movement after parity gates pass.

&#x20; - `NpcRouteMovementController` keeps CharacterBody3D motor control, but follows NavigationServer path points and link metadata instead of custom corridor cells.



\- Make doors, bottlenecks, and smart objects semantic first-class route features.

&#x20; - Doors become nav links plus smart-object actions: route to link entrance, reserve/open/hold, traverse, release/close.

&#x20; - Closed locked doors disable their link; openable doors remain route candidates but require the door action before crossing.

&#x20; - Forage/work/home/bed/stall/guard locations become reserved approach slots tied to navmesh-reachable points.



\- Replace defensive recovery with prevention budgets.

&#x20; - Route requests are throttled by target-change and navmesh-revision rules, never per-frame spam.

&#x20; - Dynamic blockers use NavigationObstacle3D/avoidance where possible and targeted requery only when an actor leaves its path corridor.

&#x20; - Recovery remains as a fallback, but acceptance requires sharply lower `blockedMoves`, `routeReplans`, and `stuckRecoveries`.



\- Add designer-facing behavior resources.

&#x20; - Move hardcoded action definitions from `NpcActionLibrary.gd` into resource-backed action/task definitions.

&#x20; - Jobs, schedules, smart-object needs, and scripted tutorial orders use the same task schema.

&#x20; - Every task declares target kind, reservation requirement, route requirement, timeout, failure policy, and success effect.



\- Add a live NPC navigation debug view.

&#x20; - Per NPC: current goal, task, route target, path age, next nav link/door, smart-object reservation, avoidance state, stuck/recovery reason.

&#x20; - World overlay: navmesh regions, links, disabled doors, dirty chunks, bake queue, path query counts, failed route targets.

&#x20; - Export the same data to test artifacts.



\## Phased Implementation



\- Phase 0: Baseline and feature flag.

&#x20; - Add `npc\_nav\_backend = custom|navmesh` runtime setting, default `custom`.

&#x20; - Record current master metrics from all existing NPC/playtest runners.

&#x20; - Add static audit that can detect live calls into legacy custom route search.



\- Phase 1: Navmesh world service.

&#x20; - Build deterministic per-chunk/per-structure nav descriptors.

&#x20; - Bake and register navmesh regions for loaded chunks and starter town interiors.

&#x20; - Add tests for deterministic bake output, chunk load/unload region cleanup, and closest-walkable queries.



\- Phase 2: Route query parity.

&#x20; - Implement `NavmeshRoutePlanner` using `NavigationServer3D.query\_path`.

&#x20; - Route homes, guard posts, jobs, forage targets, and scripted tutorial targets through navmesh with `npc\_nav\_backend=navmesh`.

&#x20; - Keep legacy backend only as a comparison oracle, not as fallback for passing behavior.



\- Phase 3: Doors, links, and dynamic edits.

&#x20; - Convert door portals to nav links with smart-object traversal.

&#x20; - Convert terrain/block/prop edits into dirty descriptor regions and background rebakes.

&#x20; - Add strict cleanup for unloaded chunks, removed props, closed doors, and cancelled active crossings.



\- Phase 4: Behavior authoring maturity.

&#x20; - Resource-back the action/task library.

&#x20; - Convert forage, trader stall, guard post, home return, bed rest, and tutorial scripted actions to shared task definitions.

&#x20; - Add validation that every active NPC goal resolves to a semantic target with a reachable navmesh point.



\- Phase 5: Tooling and scenario sandbox.

&#x20; - Add in-game debug overlay and artifact export for route/task/door/slot state.

&#x20; - Add deterministic scenario scenes for crowded doors, market workday, night shelter, terrain edit, prop removal, and tutorial automation.

&#x20; - Add fast targeted runners so failures do not require waiting on the full aggregate.



\- Phase 6: Legacy removal and acceptance hardening.

&#x20; - Remove legacy custom route search from live code paths.

&#x20; - Keep old route tests only if they test contracts still relevant to navmesh behavior.

&#x20; - Tighten performance/recovery budgets and require full aggregate green on branch and merged `master`.



\## Test Plan



\- Required existing gates remain mandatory:

&#x20; - `.\\tools\\npc\\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492`

&#x20; - `.\\tools\\npc\\run-real-tutorial-playthrough.ps1 -Seed atlas-1492`

&#x20; - `.\\tools\\run-npc-navigation-tests.ps1`

&#x20; - `.\\tools\\run-world-signature.ps1`

&#x20; - `.\\tools\\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure`



\- Add new navmesh-specific gates:

&#x20; - deterministic descriptor/bake signatures for `atlas-1492`;

&#x20; - chunk stream load/unload region leak test;

&#x20; - navmesh route parity for home, work, forage, guard, tutorial scripted orders;

&#x20; - door-link traversal with player/NPC shared authority;

&#x20; - dirty-region rebake after placed/removed blocks;

&#x20; - no live call into legacy `LocalAStarPlanner`/`HierarchicalRoutePlanner` when backend is `navmesh`.



\- Final acceptance thresholds:

&#x20; - all 23 current aggregate runners pass;

&#x20; - real tutorial has `failureCount=0`, script scans pass, and no NPC teleport/speed hack;

&#x20; - broad playtest has `181+` results, `0` failures;

&#x20; - no custom route-search fallback used in live NPC movement;

&#x20; - in broad playtest NPC stats: `stuckRecoveries <= 50`, `blockedMoves <= 250`, `routeReplans <= 250`;

&#x20; - navmesh bake/update main-thread install stays under `4ms` p95; path query p95 stays under `1ms` for current town NPC count.



\## Assumptions



\- Full navmesh migration means live route search moves to Godot navigation; NPC behavior, smart-object authority, door policy, save data, and CharacterBody motor remain project-owned.

\- World RNG order must not change. Navigation descriptors derive from already-generated world facts.

\- Runtime navmesh baking uses simple generated collision/source geometry and background bake jobs where possible; visual meshes are never parsed for live runtime baking.

\- Each phase ends with a report, commit, branch gate, merge to `master`, and merged-master verification.
