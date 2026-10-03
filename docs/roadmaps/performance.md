\# Codex Plan: Fix Post-Pathfinding Gameplay Lag Spikes



Branch: perf/fix-post-pathfinding-spikes



Goal:

Eliminate recurring gameplay hitches caused by synchronous autosave, static navigation snapshot rebuilds, synchronous route planning, and repeated scene-tree resource scans. Preserve all NPC correctness behavior.



Do not rewrite pathfinding again. This is a scheduling/caching/performance pass.



\## Phase 1 — Add spike instrumentation first



Implement a lightweight runtime frame spike logger.



Add counters/timers for:

\- total frame time

\- `update\_npcs`

\- `NpcAutonomySystem`

\- door policy update

\- traffic update

\- route planning

\- runtime graph build

\- navigation snapshot rebuild

\- prop/block scan count

\- job/forage target scan

\- autosave snapshot

\- autosave binary read/decode

\- autosave binary encode/write



Expose:

\- `perf\_npc\_ms`

\- `perf\_route\_plan\_ms`

\- `perf\_nav\_snapshot\_ms`

\- `perf\_job\_scan\_ms`

\- `perf\_autosave\_ms`

\- p50/p95/p99/max frame time over rolling 10s window

\- last spike reason with top 5 timed sections



Acceptance:

\- Manual performance HUD can identify the exact subsystem causing a spike.

\- Add a runtime observation report that runs day, dusk, and night for 60s and records max frame time plus top spike contributors.

\- No gameplay logic changes yet.



\## Phase 2 — Fix autosave main-thread spike



Problem:

`MainSetupScene.gd` autosaves every 5s. Save slots use Godot binary Variant data; snapshot capture and synchronous file I/O still run on the main thread.



Required changes:

\- Increase default autosave interval from 5s to at least 60s.

\- Save only when world/player data is dirty.

\- Never call full read/parse/write during gameplay frame.

\- Write the active binary slot directly for autosave.

\- Write to temp file, then atomic rename.

\- Move binary encode/file write to a background `Thread` where safe.

\- Main thread may create snapshot, but snapshot creation must be time-budgeted or deferred across frames if large.

\- If threaded writing is unavailable, autosave must occur only during safe low-load windows and with a visible budget gate.



Acceptance:

\- With autosave enabled, no autosave frame section exceeds 2ms main-thread time.

\- Disabling autosave no longer materially changes p99 frame time.

\- Save/load tests still pass.



\## Phase 3 — Split static and dynamic navigation invalidation



Problem:

`GeneratedWorldNavigationAdapter` can rebuild static blocked cells after dynamic changes. Door state, traffic, actor, and smart-object premise changes must not trigger full block/prop scans.



Required changes:

\- Add separate revision keys:

&#x20; - `static\_snapshot\_revision`

&#x20; - `dynamic\_revision`

&#x20; - `semantic\_revision`

&#x20; - `door\_state\_revision`

\- Static cache rebuild only for:

&#x20; - block create/remove

&#x20; - terrain edit

&#x20; - prop create/remove

&#x20; - chunk load/unload

&#x20; - structure/door registration, not door open/close

\- Door open/close updates door traversal/dynamic state only.

\- Remove `CHANGE\_KIND\_DOOR\_STATE` from static snapshot invalidation.

\- Add counter `nav\_static\_rebuild\_count`.

\- Add counter `nav\_dynamic\_update\_count`.



Acceptance:

\- Opening/closing a door 100 times causes 0 static snapshot rebuilds.

\- Adding/removing a block causes exactly affected static rebuilds.

\- Existing door, route, repair, and traffic suites still pass.



\## Phase 4 — Budget live route planning



Problem:

Runtime route planning can build a fresh graph and search with a huge synchronous expansion allowance.



Required changes:

\- Replace immediate runtime `planner.plan\_route(...)` calls with queued route jobs.

\- Allow at most 1 expensive route job per frame by default.

\- Cap live gameplay expansions per frame.

\- Long route requests return `pending` and resume next frame.

\- NPCs with existing safe route continue or wait safely while replanning.

\- Coalesce repeated `routeForceReplan` requests per actor/generation.

\- Add graph/cache reuse keyed by:

&#x20; - profile

&#x20; - static snapshot revision

&#x20; - start tile

&#x20; - goal tile

&#x20; - route intent kind

&#x20; - route margin

\- Do not rebuild the local runtime graph if only dynamic traffic changed.



Acceptance:

\- No route planning frame exceeds 2ms under 32 active NPCs.

\- Dusk/night home-return wave does not schedule more than the configured route jobs per frame.

\- Route correctness tests still pass.



\## Phase 5 — Replace job/resource scene-tree scans with indexed smart-object lookup



Problem:

Job/forage target selection recursively scans `prop\_root` and `chunk\_root` every few seconds.



Required changes:

\- `SmartObjectService` must maintain indexed resource registries:

&#x20; - forage

&#x20; - wood

&#x20; - stone

&#x20; - trader stalls

&#x20; - storage/deposit

&#x20; - beds/rest

&#x20; - guard posts

\- Index by:

&#x20; - kind

&#x20; - tile/chunk

&#x20; - town/region

&#x20; - depleted/available

&#x20; - vertical layer

\- Prop create/remove/depletion updates the index incrementally.

\- Replace `collect\_\*\_targets\_in\_tree(...)` runtime scans with indexed queries.

\- Keep a debug-only fallback scan behind an explicit test/dev flag, never normal gameplay.

\- Cache route-scored candidates briefly and invalidate on relevant resource/nav revisions.



Acceptance:

\- Job/forage target search does not call recursive `get\_children()` in normal gameplay.

\- Worker/forager/trader/guard interaction tests still pass.

\- 32 NPC day work soak has stable p99 frame time.



\## Phase 6 — Final performance gate



Add a new runner:

`tools/run-runtime-performance-observation.ps1`



Scenarios:

\- day work town, 32 NPCs

\- dusk return-home wave, 32 NPCs

\- midnight guards/civilians, 32 NPCs

\- crowded door traffic

\- autosave enabled

\- autosave disabled comparison



Required report:

\- p50/p95/p99/max frame time

\- max `update\_npcs`

\- max route planning

\- max nav rebuild

\- max job scan

\- max autosave

\- static rebuild count

\- route jobs completed/pending

\- autosave jobs completed/pending



Acceptance thresholds:

\- p99 frame time <= 16.7ms target, <= 22ms tolerated on dev hardware.

\- max frame time <= 33ms during normal 32-NPC gameplay.

\- no repeated spike pattern every 2–7 seconds.

\- no synchronous autosave write over 2ms main-thread time.

\- no static nav rebuild from door open/close.

\- all NPC focused suites pass.

\- `run-npc-navigation-tests.ps1` passes.

\- broad playtest passes.

\- world signature remains unchanged unless intentionally justified.
