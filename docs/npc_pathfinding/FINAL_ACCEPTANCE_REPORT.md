# NPC Pathfinding Final Acceptance Report

Date: 2026-06-27

Branch: `npc-pathfinding/phase-13-finalize`

Base commit: `56119cef054cd444f6e9b87886b66054936785d0`

Status: focused NPC suites, broad playtest, static audit, and world signature pass on the phase branch. Branch all-runner, merge commit, merged `master` all-runner, and final report hash rows are pending until those commands are run.

## Evidence Index

Focused reports:

- `artifacts/npc/reports/phase13-contract-both-post-event.json`: 40 results, 0 failures.
- `artifacts/npc/reports/phase13-motor-both-post-event.json`: 36 results, 0 failures.
- `artifacts/npc/reports/phase13-nav-world-both-post-event.json`: 38 results, 0 failures.
- `artifacts/npc/reports/phase13-route-both-post-event.json`: 38 results, 0 failures.
- `artifacts/npc/reports/phase13-repair-both-post-event.json`: 32 results, 0 failures.
- `artifacts/npc/reports/phase13-door-both-post-event.json`: 42 results, 0 failures.
- `artifacts/npc/reports/phase13-avoidance-both-post-event.json`: 30 results, 0 failures.
- `artifacts/npc/reports/phase13-traffic-both-post-event.json`: 38 results, 0 failures.
- `artifacts/npc/reports/phase13-behavior-both-post-event.json`: 22 results, 0 failures.
- `artifacts/npc/reports/phase13-behavior-transition-post-event.json`: 2 results, 0 failures.
- `artifacts/npc/reports/phase13-interaction-both-post-event.json`: 20 results, 0 failures.
- `artifacts/npc/reports/phase13-streaming-save-both-post-event.json`: 38 results, 0 failures.
- `artifacts/npc/reports/phase13-soak-both-post-event.json`: 26 results, 0 failures.
- `artifacts/npc/reports/phase13-soak-transition-post-event.json`: 2 results, 0 failures.
- `artifacts/npc/reports/phase13-observation-both-post-event.json`: 7 results, 0 failures.
- `artifacts/npc/reports/phase13-npc-navigation-post-event.json`: 11 results, 0 failures.
- `artifacts/npc/reports/phase13-playtest-after-event-flush.json`: 181 results, 0 failures.

Static audit and world signature:

- Production legacy/preload/static shortcut searches are recorded in `docs/npc_pathfinding/PHASE_13_REPORT.md`.
- `.\tools\run-world-signature.ps1` reports the generated latest signature matches `artifacts/baselines/world-signature/atlas-1492.json`.
- Baseline and latest hash: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.

Pending evidence:

- Branch all-runner report: `artifacts/test-runners/phase13-branch-all-test-runners-report.json`
- Merged `master` all-runner report: `artifacts/test-runners/phase13-master-all-test-runners-report.json`
- Branch implementation/report commit: pending
- Merge commit: pending

## 23.1 Architecture and ownership

- [x] NPCs are `CharacterBody3D` agents. Evidence: contract/motor suites and `NpcSystem.safe_place_npc()` require `CharacterBody3D`; `phase13-contract-both-post-event.json`, `phase13-motor-both-post-event.json`.
- [x] Shared motor is used by player and NPCs for physical rules. Evidence: `CharacterMotor3D.gd`; motor and contract reports pass.
- [x] `NpcSystem` is no longer a pathfinding/door/job movement monolith. Evidence: direct job execution moved to `NpcPlanExecutor.gd`; routing/movement/doors/traffic live under `scripts/npc_ai/`; production legacy search has zero matches.
- [x] No extra `Main*.gd` inheritance layer was added. Evidence: changed files add no new `Main*.gd` layer.
- [x] Runtime contracts are typed; save dictionaries exist only at persistence boundaries. Evidence: `NpcAgentContext`, traversal/route contracts, streaming/save suite, and save filtering.
- [x] One navigation topology service, one route coordinator, one traffic service, and one door authority exist. Evidence: `GeneratedWorldNavigationAdapter`, `NpcRouteCoordinatorAdapter`, `TrafficReservationService`, `DoorPortalService`/`DoorTraversalExecutor`; door/traffic/route suites pass.

## 23.2 Physical correctness

- [x] No normal NPC route movement writes transforms. Evidence: transform audit lists only safe placement and query transforms; motor suite passes.
- [x] No teleport recovery. Evidence: `NpcRecoveryPolicy` reports `teleportUsed: false`; static audit has no route recovery teleport path.
- [x] No penetration in deterministic geometry suites. Evidence: motor, route, door, traffic, and dedicated navigation reports pass.
- [x] No penetration in required fuzz/soak seeds. Evidence: soak both/transition reports pass.
- [x] Closed doors, walls, fences, windows, props, player, hostiles, and NPC bodies are respected. Evidence: navigation, route, door, traffic, interaction, and broad playtest reports pass.
- [x] Open doors clear only when controller says physically traversable. Evidence: door suite and door traversal executor active crossing/clearance logic.
- [x] Actual post-physics movement drives progress and arrival. Evidence: `NpcRouteMovementController` uses post-physics body state and `CharacterMotor3D`; motor/route reports pass.

## 23.3 Navigation-world correctness

- [x] Multiple walkable surfaces per XZ are represented. Evidence: nav-world suite.
- [x] Headroom, clearance, slope, step, drop, and capability are profile-aware. Evidence: nav-world and route suites; `TraversalProfile.gd`.
- [x] Door/special traversal is explicit. Evidence: route action and door reports.
- [x] Dirty events update exact affected tiles. Evidence: navigation change bus and repair/nav-world reports.
- [x] No full scene scan/hash per navigation frame. Evidence: revision hash/static search has zero matches; remaining scans are snapshot rebuild or bounded resource discovery, documented in the phase report.
- [x] Unloaded/stale topology is explicit. Evidence: nav-world, repair, streaming/save reports.
- [x] Semantic interiors, roads, guard posts, work/resource approaches, and staging points exist. Evidence: behavior, observation, navigation runner, and broad playtest reports.

## 23.4 Route correctness

- [x] Hierarchical global/local route planning is implemented. Evidence: `HierarchicalRoutePlanner.gd`; route report.
- [x] Searches are deterministic and time-sliced. Evidence: route/repair/soak reports and deterministic RNG/static audit.
- [x] No false failure from a small hard iteration cap. Evidence: production `MAX_ITERATIONS` search has zero matches; route test asserts old cap removal.
- [x] Start/goal snapping cannot cross walls or vertical layers. Evidence: route/nav-world reports.
- [x] Corridor smoothing is capsule-safe. Evidence: route/motor/navigation reports.
- [x] Mandatory traversal actions survive smoothing. Evidence: door route/action reports.
- [x] Partial routes are explicit only. Evidence: route and repair reports.
- [x] Unreachable requests terminate with reasons. Evidence: dedicated navigation runner and route report.
- [x] Route cost choices are inspectable. Evidence: route diagnostics and focused route report.

## 23.5 Dynamic repair

- [x] Relevant changes repair affected route segments. Evidence: repair suite and dedicated navigation invalidation case.
- [x] Unrelated changes do not force route rebuild/replan. Evidence: repair suite.
- [x] Repair reuses search state. Evidence: repair suite.
- [x] Repair matches fresh A* feasibility/cost in oracle tests. Evidence: repair suite.
- [x] Repeated failure cannot loop forever. Evidence: repair/soak reports.
- [x] Target/resource/door premise failures reach the action planner. Evidence: interaction, behavior, door, and broad playtest reports.

## 23.6 Door safety and intelligence

- [x] Every doorway has one logical portal/controller. Evidence: door suite.
- [x] Double doors coordinate as one portal. Evidence: door suite.
- [x] NPCs never call blind toggle. Evidence: `rg -n "toggle_door|request_door_toggle" scripts scenes tools AGENTS.md docs/npc_pathfinding/ARCHITECTURE.md` has no matches.
- [x] Player and NPC share authoritative door actions. Evidence: interaction and observation reports; player uses `request_player_door_use()`.
- [x] Open/close requests are idempotent. Evidence: door suite.
- [x] Door crossing has approach, open, confirmation, reservation, cross, clear, release, and close steps. Evidence: door/traffic reports and `DoorTraversalExecutor.gd`.
- [x] Occupancy/reservation always prevents close. Evidence: door/traffic reports.
- [x] Obstructed closing reverses safely. Evidence: door report.
- [x] Locked/jammed/destroyed/missing states alter plans/routes correctly. Evidence: door and route reports.
- [x] Door timeout cannot override safety. Evidence: timeout search has no unsafe close match; door suite passes.

## 23.7 Multi-agent movement

- [x] Predictive reciprocal avoidance handles open-space encounters. Evidence: avoidance suite.
- [x] Avoidance cannot leave corridor or bypass static geometry. Evidence: avoidance/route/motor reports.
- [x] Narrow resources use space-time node and edge reservations. Evidence: traffic suite.
- [x] No adjacent actor swaps. Evidence: traffic suite.
- [x] Active crossing cannot be preempted. Evidence: traffic/door reports after active crossing key fix.
- [x] Wait aging prevents starvation. Evidence: traffic suite.
- [x] Wait-for cycles are detected and resolved. Evidence: traffic suite.
- [x] Retreat/yield uses physical movement. Evidence: avoidance/motor reports.
- [x] Reservations/holds clean up on all lifecycle paths. Evidence: traffic, door, streaming/save, and soak reports.

## 23.8 Purpose and schedules

- [x] Goals use utility from role, schedule, needs, threats, orders, and world facts. Evidence: behavior/observation reports and `NpcSemanticGoalPlanner.gd`.
- [x] Task plans use explicit action preconditions/effects. Evidence: behavior/interaction reports and `NpcPlanExecutor.gd`.
- [x] Plan execution reacts to changing reality. Evidence: behavior, repair, interaction, and broad playtest reports.
- [x] Ordinary movement targets semantic anchors, not raw random coordinates. Evidence: static random audit and behavior report.
- [x] Every generated town NPC has a home interior. Evidence: dedicated navigation runner and behavior reports.
- [x] Dusk return-home begins early enough under normal conditions. Evidence: behavior transition and observation reports.
- [x] At settled night, assigned guards are outside on duty. Evidence: observation and behavior reports.
- [x] At settled night, every non-duty NPC is inside home/shelter. Evidence: observation and behavior reports.
- [x] Porch/threshold never counts as inside. Evidence: perception/plan executor reasons and dedicated navigation runner.
- [x] `canFight` is not guard duty. Evidence: static audit; guard roster uses explicit duty, `canFight` remains combat capability.
- [x] Threat/script exceptions are explicit and recover to schedule. Evidence: behavior/observation reports.

## 23.9 Environment interaction

- [x] Jobs execute real shared smart-object actions. Evidence: interaction and broad playtest reports.
- [x] NPC cannot interact through walls/wrong floors/out of reach. Evidence: interaction/nav-world reports.
- [x] Player/NPC object availability is consistent. Evidence: interaction report.
- [x] Capacity/reservations prevent duplicate use/rewards. Evidence: interaction and traffic reports.
- [x] Resource removal/depletion triggers bounded replanning. Evidence: interaction, repair, and broad playtest reports.
- [x] Guard intercept positions are reachable and role/weapon aware. Evidence: behavior/observation reports.

## 23.10 Streaming and saves

- [x] Active/abstract transitions are safe and hysteretic. Evidence: streaming/save report.
- [x] No promotion in doors/geometry/occupied footprint. Evidence: streaming/save report and safe-placement audit.
- [x] Abstract travel respects semantic connectivity/access. Evidence: streaming/save report.
- [x] Old saves load deterministically. Evidence: streaming/save and contract reports.
- [x] New saves round-trip durable state. Evidence: streaming/save report.
- [x] No transient path/reservation/RVO/queue state is saved. Evidence: save filtering audit and streaming/save report.
- [x] Night/day intent reconstructs after load. Evidence: streaming/save and behavior reports.
- [x] Actor removal leaves no ownership leak. Evidence: streaming/save, traffic, and soak reports.

## 23.11 Performance, tests, and continuity

- [x] Focused runner infrastructure rejects stale reports. Evidence: focused runner reports include generated timestamps, branch, commit, result counts, and failure counts.
- [x] Every final focused suite passes required day/night/transition matrices. Evidence: focused evidence index.
- [x] Required fuzz/soak seeds pass. Evidence: soak both/transition reports.
- [x] 32-agent performance target passes or has explicit approved revision. Evidence: soak/observation reports inherited from Phase 12 coverage and still passing under Phase 13.
- [x] 64-agent stress has no correctness/liveness/leak failure. Evidence: soak/observation reports inherited from Phase 12 coverage and still passing under Phase 13.
- [x] All queues/caches/traces are bounded. Evidence: contract, traffic, streaming/save, and soak reports.
- [x] Existing dedicated NPC navigation runner passes. Evidence: `phase13-npc-navigation-post-event.json`, 11 results, 0 failures.
- [x] Broad playtest passes. Evidence: `phase13-playtest-after-event-flush.json`, 181 results, 0 failures.
- [ ] Story playtest passes. Evidence pending branch all-runner report.
- [x] World signature passes with understood baseline. Evidence: `.\tools\run-world-signature.ps1`, matching baseline/latest hash `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.
- [ ] Visual captures and manifest validation pass. Evidence pending branch all-runner report.
- [ ] Phase branch and merged `master` both pass the all-runner gate. Evidence pending branch and master all-runner reports.
- [x] Final observation artifacts were inspected and documented. Evidence: `phase13-observation-both-post-event.json` and Phase 13 report Section 9.

A single unchecked mandatory box means the replacement is not complete.
