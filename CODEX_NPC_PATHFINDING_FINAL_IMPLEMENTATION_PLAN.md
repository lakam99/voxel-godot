# Authoritative Codex Implementation Specification: Final NPC Autonomy, Traversal, and Pathfinding Replacement

**Project:** Godot Procedural Voxel Game  
**Engine target:** Godot 4.6.x, Forward+  
**Controlling branch:** `master`  
**Document status:** Mandatory implementation specification  
**Supersedes:** `CODEX_NPC_PATHFINDING_COMPLETION_PLAN.md` and all earlier NPC-pathing plans  
**Execution model:** One phase per branch; focused tests during development; every test runner before merge; phase report; merge to `master`; rerun every test runner on `master`; then begin the next phase from the updated `master`  

---

## 0. Directive to Codex

Read this entire document before changing code. Re-read the current phase, the global invariants, the test protocol, and the prohibited-shortcuts section at the beginning of every phase.

This is not a request for another patch over the present grid mover. It is a controlled replacement of the NPC movement and autonomy stack. Implement the design below as written. Do not substitute a smaller design because it is quicker. Do not declare a phase complete because an NPC happened to reach a target once. Completion requires the stated invariants, deterministic tests, day/night behavior, full-suite continuity, a phase report, and a green merge on `master`.

The words **must**, **shall**, **required**, **forbidden**, and **gate** are binding. A phase with a failed gate is incomplete and shall not be merged.

The implementation is allowed to be a large refactor. It is not allowed to destabilize unrelated systems, world generation, saves, story state, visuals, or the player controller.

### 0.1 Required operating behavior

For every phase:

1. Begin from the current, green `master`.
2. Inspect `git status --short`; preserve all user work.
3. Create exactly the phase branch named in this document.
4. Implement only that phase plus the minimum compatibility work required to keep the game functional.
5. Run the phase's focused runner repeatedly while iterating.
6. Run every NPC-focused runner required up to and including that phase.
7. Run the repository-wide all-runner gate.
8. Write the required in-depth phase report.
9. Self-audit the phase against this document and record every gate as pass/fail with evidence.
10. Commit the implementation and report with behavior-oriented commit messages.
11. Merge the phase branch into `master` with a non-fast-forward merge.
12. Rerun the repository-wide all-runner gate on `master`.
13. If anything fails on `master`, create a phase repair branch, fix it, rerun all gates, report the repair, and merge it. Do not proceed to the next phase while `master` is red.
14. Create the next phase branch from the updated, green `master`.

Do not force-push, reset, clean, discard, or rewrite user work. Do not weaken tests. Do not change a deterministic baseline merely to make a failure disappear. Investigate and document any intentional baseline change before accepting it.

### 0.2 Completion claim

Do not use the words “complete,” “done,” “final,” “robust,” or “working” in a phase report unless every required gate for that scope passed. The overall replacement is complete only after Phase 13 is merged and the final acceptance matrix in this document is green.

---

## 1. Required Outcome

The finished game shall contain NPCs that move with physically valid, world-aware purpose rather than a destination-only grid approximation.

An NPC shall be able to:

- select a meaningful goal from role, schedule, needs, threats, orders, and world state;
- form a bounded, inspectable action plan to satisfy that goal;
- select a route that accounts for actual body dimensions, terrain, structures, interiors, doors, hazards, congestion, permissions, and traversal capabilities;
- traverse using a `CharacterBody3D` motor rather than writing its transform as locomotion;
- open, wait for, cross, hold, and safely close single or double doors through the same authoritative interaction system available to the player;
- avoid walls, windows, fences, props, doors, the player, hostiles, and other NPCs without clipping, perpetual bumping, or oscillation;
- coordinate at doors, bridges, stairs, and other bottlenecks without head-on swaps, starvation, or permanent deadlock;
- respond to blocks placed or removed, resources harvested, doors locked or destroyed, chunks loaded or unloaded, and routes invalidated while moving;
- reach an explicit terminal result when a request is impossible rather than wandering forever;
- work during the day according to role and reachable world resources;
- return through a real entrance into a real home interior at dusk/night when not assigned night guard duty;
- perform night guard duty outside at a valid guard post or patrol route when assigned that duty;
- use the same collision and interaction truth as the player for equivalent capabilities;
- expose enough structured state to explain what it is doing, why it is waiting, and why a request failed;
- remain deterministic under fixed world seed, simulation seed, fixed timestep, and identical input.

The target is not omniscience. Low-level navigation may use authoritative collision geometry so NPCs do not walk into known physical objects. High-level decisions must use the NPC's legitimate knowledge, perception, role, and memory, so NPCs do not react to hidden information they should not possess.

---

## 2. Current Repository Reality and Why It Must Be Replaced

The existing work is useful as regression scaffolding, not as the final architecture.

The current repository contains:

- `scripts/NpcPathing.gd`, a `RefCounted` compatibility façade;
- `scripts/npc_nav/NpcNavigationWorld.gd`;
- `scripts/npc_nav/NpcRoutePlanner.gd`;
- `scripts/npc_nav/NpcLocomotionController.gd`;
- `scripts/npc_nav/NpcGoalPlanner.gd`;
- `scripts/NpcSystem.gd`;
- `scripts/NpcNavigationTestRunner.gd`;
- `scenes/NpcNavigationTest.tscn`;
- `tools/run-npc-navigation-tests.ps1`;
- a current focused report with eleven narrow passing cases;
- broad playtest coverage that must remain green throughout the replacement.

The architectural defects are concrete:

1. `NpcSystem.spawn_town_npc()` currently creates `StaticBody3D` NPCs with collision mask `0`.
2. The current locomotion controller commits normal movement by assigning `body.global_position` after ad hoc validation.
3. The navigation world reduces the world to one XZ grid cell and one sampled terrain height. It cannot correctly represent multiple walkable surfaces, raised interiors, bridges, tunnels, stacked construction, or profile-specific headroom.
4. Static revision detection hashes/scans scene and block state instead of receiving authoritative change events.
5. The global route search deliberately omits dynamic occupants and uses a small bounded A* search with partial fallbacks.
6. Local avoidance is a fixed list of sidestep vectors, not prediction-aware reciprocal avoidance.
7. Reservations are short frame-TTL claims, not time-aware node and edge reservations.
8. A door is treated as a cell that can trigger a blind toggle. There is no logical portal, approach slot, threshold ownership, swing-volume safety, access policy, opening confirmation, queue, or double-door coordination.
9. Door closure may currently time out past player clearance. No timeout is permitted to override occupancy safety in the replacement.
10. `homeCell` and `porchCell` are insufficient to prove that a civilian is inside. A porch fallback is not a successful night-home result.
11. High-level behavior selects destinations and phases; it does not plan environment interactions as precondition/effect actions.
12. `canFight` is conflated with guard duty. In the replacement, only an explicit night-duty assignment keeps a guard outside; every other NPC must seek an interior at night unless a separately modeled emergency or script overrides the schedule.

Do not preserve any of these defects for compatibility. Use compatibility adapters only long enough to keep each phase mergeable. Remove the adapters and legacy stack in Phase 13.

---

## 3. Non-Negotiable Reliability Contract

The following statements are implementation invariants, not aspirations.

### 3.1 Physical movement invariants

- Normal NPC locomotion shall never assign `position`, `global_position`, or `transform` to advance along a route.
- Normal NPC locomotion shall advance only through a shared `CharacterBody3D` motor and Godot collision movement (`move_and_slide()` and/or `move_and_collide()`).
- Direct placement is permitted only for initial spawn, load restoration, active/abstract simulation promotion, and explicit administrator/debug teleport. Every such placement must use a named safe-placement API, validate the capsule, emit telemetry, and never masquerade as route progress.
- Every active NPC must own a physical capsule or equivalent body shape whose dimensions come from its traversal profile.
- Physics is the final authority. A planner or avoidance system may propose a velocity; it may not force a body through a rejected collision.
- A failed movement tick may produce zero movement, waiting, recovery, or replanning. It may not produce penetration.
- Movement, route progression, and arrival shall use the actual post-physics body position, never an assumed candidate position.

### 3.2 Route-result invariants

Every route request shall eventually be in one of these explicit states:

- `PENDING`
- `COMPLETE`
- `PARTIAL`
- `UNREACHABLE`
- `INVALIDATED`
- `CANCELLED`
- `FAILED_INTERNAL`

`PARTIAL` is allowed only when the request explicitly permits it. A partial route shall never be silently interpreted as arrival. Home, guard, work, interaction, and scripted actions must decide explicitly whether their goal can accept a partial result.

A route failure must carry a machine-readable reason, relevant object/span/portal identifiers, topology revisions, and a human-readable diagnostic. No request may remain in an unbounded “trying” state.

### 3.3 Door invariants

- NPC code shall never call a blind door toggle.
- Door commands shall be idempotent state requests: open, hold, release, close, lock, unlock, or cancel.
- A door shall never begin closing while its threshold volume, leaf sweep volume, or required capsule-clearance volume is occupied.
- A closing door that becomes obstructed shall stop and reopen or return to a safe open state.
- No timeout may override occupancy, an active crossing reservation, or an imminent queued actor that has inherited the opening.
- A route may treat a closed but openable door as traversable only by attaching an explicit door traversal action and expected interaction cost.
- A locked, jammed, unauthorized, destroyed, or missing door shall alter route/action feasibility immediately and deterministically.
- A double door is one logical portal with coordinated leaves, not two unrelated toggles.

### 3.4 Multi-agent invariants

- Two actors shall never reserve conflicting occupancy of the same narrow span during overlapping intervals.
- Opposing traversal of the same narrow directed edge shall never occur during overlapping intervals.
- Two actors shall not swap adjacent cells through one another in a single tick.
- Waiting shall age priority; no normal-priority actor may starve indefinitely.
- Wait-for cycles shall be detected and resolved deterministically.
- Open-space reciprocal avoidance is not a substitute for bottleneck reservations, and bottleneck reservations are not a substitute for physical collision.

### 3.5 Day/night invariants

- Canonical fixed daytime for tests is `time_of_day = 0.25`, corresponding to noon after the existing display offset.
- Canonical fixed nighttime for tests is `time_of_day = 0.75`, corresponding to midnight after the existing display offset.
- At dusk, non-duty NPCs must select and execute a return-home plan early enough to be indoors by full night under normal generated-world conditions.
- At night, an NPC with an explicit active guard-duty assignment must be at or traveling toward a reachable guard post, patrol segment, or threat intercept appropriate to that duty.
- At night, every other NPC must be inside its assigned interior or an explicit emergency shelter. `canFight` alone does not exempt an NPC.
- A porch, doorway threshold, exterior wall edge, or roof is not “inside.”
- Exceptions for active threats, rescues, scripted sequences, evacuation, or a physically unreachable/blocked home must be represented as explicit goals and reasons and tested separately. Exceptions may not be silent schedule failures.

### 3.6 Determinism and boundedness invariants

- Route tie-breaking, goal tie-breaking, reservation priority, action selection, and fallback selection must be stable under identical inputs.
- NPC randomness must use per-NPC deterministic streams seeded from stable world seed, NPC ID, day/phase context, and decision domain. It must not consume or reorder world-generation RNG.
- Every queue, trace, cache, reservation table, and failure history must have a defined bound or eviction policy.
- No planner may block a frame with an unbounded search. Large searches must be time-sliced and remain `PENDING` until complete.
- A time budget expiration is not an unreachable result. It pauses work and resumes later.

---

## 4. Research-Derived Engineering Principles

The implementation shall apply these principles, not merely cite them.

1. **Physics-controlled characters:** Godot's physics guidance says controlled character bodies should move through collision methods rather than direct position assignment. The shared motor therefore owns physical motion.
2. **Separation of global planning and local control:** Mature robotics navigation stacks separate goal/task logic, global planning, local control, recoveries, and execution. No single A* function shall own all behavior.
3. **Hierarchical planning for large worlds:** HPA* reduces large-map search by abstracting local clusters and cached entrances. This project shall use chunk/region/portal abstraction and local refinement.
4. **Incremental repair:** D* Lite/LPA* reuse prior search work when edge costs or traversability change. The replacement shall repair affected route segments instead of restarting every request after every voxel change.
5. **Predictive local avoidance:** ORCA/RVO reasons about velocity conflicts. Godot's avoidance output may be used for active grounded actors, but only as a desired safe velocity layer.
6. **Space-time coordination at bottlenecks:** SIPP and cooperative pathfinding show that waiting for a safe interval can be superior to treating a moving actor as a permanent obstacle. Doors, stairs, bridges, and one-body corridors shall use time-aware reservations.
7. **Action planning for world interaction:** Goal-oriented planning represents actions through preconditions and effects. Opening a door, reserving a workstation, harvesting, depositing, and returning home are actions, not magic side effects of reaching a coordinate.
8. **Reactive execution:** A plan executor must monitor changing reality and repair or replace a plan when a target disappears, a door locks, a threat appears, or progress stops.
9. **Layered truth:** Low-level collision/navigation can know authoritative geometry; high-level cognition uses role, perception, memory, and explicit world facts.
10. **Selective expense:** Godot notes that avoidance has meaningful cost with many agents. Enable expensive local avoidance only for active actors that require it; use abstract simulation for distant NPCs.

The research references are listed at the end of this document.

---

## 5. Target Architecture

Implement the following composed stack. Do not add another script to the deep `Main*.gd` inheritance chain.

```text
World time, needs, role, perception, orders, threats, settlement state
                                  |
                                  v
                         NpcGoalSelector
                                  |
                                  v
                         NpcTaskPlanner
                                  |
                                  v
                         NpcPlanExecutor
                                  |
                  +---------------+----------------+
                  |                                |
                  v                                v
          NavigationCoordinator             SmartObjectService
                  |                                |
                  v                                v
       HierarchicalRoutePlanner              DoorPortalService
                  |
                  v
       IncrementalRouteRepair
                  |
                  v
        TrafficReservationService
                  |
                  v
          NpcCorridorFollower
                  |
                  v
        ReciprocalAvoidanceAdapter
                  |
                  v
           CharacterMotor3D
                  |
                  v
             CharacterBody3D
```

Supporting services:

- `NavigationWorldService`: event-driven multi-surface topology and semantics;
- `NavigationChangeBus`: authoritative dirty events;
- `NpcBrainScheduler`: staggered bounded high-level updates without skipping physics;
- `NpcPerceptionService`: legitimate high-level world knowledge;
- `NpcScheduleService`: day/dusk/night/dawn duties;
- `NpcTrafficService`: reservations, queues, deadlock detection, priority inheritance;
- `NpcSimulationLodService`: full active simulation versus abstract distant simulation;
- `NpcTelemetryService`: structured traces and performance counters;
- `NpcSafePlacementService`: spawn/load/promotion validation only;
- `NpcAutonomySystem`: composition root owned by/delegated from `NpcSystem`.

### 5.1 Ownership rules

- `NpcSystem.gd` remains the public integration point for existing game systems during migration, but shall cease to own route algorithms, door timers, and job-state movement.
- `NpcAutonomySystem.gd` shall be a composed child/service, not a new `Main` base class.
- Every active NPC shall be represented by `NpcAgent.gd` on a `CharacterBody3D` scene.
- The NPC's blackboard/context shall be a typed object, not an ever-growing untyped dictionary.
- Save snapshots remain dictionaries at the persistence boundary, but runtime systems use typed contracts.
- The navigation graph stores data, not scene nodes. Scene-node references may exist only in registration/controller layers with validity checks.
- The planner must not scan the scene tree or query physics during graph search. Topology builders perform main-thread/physics validation and publish immutable graph data.
- `NavigationAgent3D`/`NavigationServer3D` may provide avoidance; they are not the authoritative voxel-world route planner.

---

## 6. Required File and Directory Layout

Create this layout progressively. Exact class names are binding unless an engine naming conflict is discovered and documented in the phase report.

```text
scripts/npc_ai/
  NpcAutonomySystem.gd
  NpcAgent.gd
  NpcAgentFactory.gd
  NpcAgentContext.gd
  NpcBlackboard.gd
  NpcBrainScheduler.gd
  NpcConstants.gd
  NpcEnums.gd

  contracts/
    TraversalProfile.gd
    CharacterMotorCommand.gd
    CharacterMotorState.gd
    NavSpanKey.gd
    NavSpanData.gd
    NavEdgeData.gd
    NavTileData.gd
    RouteRequest.gd
    RouteResult.gd
    RouteCorridor.gd
    RouteStep.gd
    TraversalAction.gd
    TrafficReservation.gd
    InteractionRequest.gd
    InteractionResult.gd
    NpcGoal.gd
    NpcActionDefinition.gd
    NpcActionInstance.gd
    NpcPlan.gd
    WorldTimeSnapshot.gd

  movement/
    CharacterMotor3D.gd
    CharacterMotorProfile.gd
    NpcMotionController.gd
    NpcCorridorFollower.gd
    ReciprocalAvoidanceAdapter.gd
    NpcSafePlacementService.gd

  navigation/
    NavigationChangeBus.gd
    NavigationWorldService.gd
    NavigationTileBuilder.gd
    NavigationBuildQueue.gd
    NavigationSemanticService.gd
    NavGraphQuery.gd
    HierarchicalRoutePlanner.gd
    LocalAStarPlanner.gd
    RouteCorridorBuilder.gd
    IncrementalRouteRepair.gd
    RouteRequestQueue.gd
    RouteCostModel.gd
    TraversalCapabilityService.gd

  traffic/
    TrafficReservationService.gd
    SafeIntervalPlanner.gd
    WaitForGraph.gd
    TrafficPriorityPolicy.gd
    BottleneckClassifier.gd

  interactions/
    SmartObjectService.gd
    SmartObjectRegistration.gd
    DoorController.gd
    DoorPortal.gd
    DoorPortalService.gd
    DoorAccessPolicy.gd
    DoorTraversalExecutor.gd

  planning/
    NpcGoalSelector.gd
    NpcTaskPlanner.gd
    NpcPlanExecutor.gd
    NpcRecoveryPolicy.gd
    NpcScheduleService.gd
    GuardRosterService.gd
    NpcPerceptionService.gd
    NpcActionLibrary.gd

  simulation/
    NpcSimulationLodService.gd
    AbstractNpcTransit.gd

  debug/
    NpcTelemetryService.gd
    NpcDebugOverlay.gd
    NpcTraceEvent.gd

scenes/npc/
  NpcAgent.tscn

scripts/testing/npc/
  NpcAutonomyTestRunner.gd
  NpcScenarioHarness.gd
  NpcSyntheticWorld.gd
  NpcTestClock.gd
  NpcTestAssertions.gd
  NpcObservationRunner.gd

scenes/testing/npc/
  NpcAutonomyTest.tscn
  NpcObservationTest.tscn

resources/npc/
  traversal/
  roles/
  behavior/

tools/npc/
  run-npc-suite.ps1
  run-npc-contract-tests.ps1
  run-npc-motor-tests.ps1
  run-npc-nav-world-tests.ps1
  run-npc-route-tests.ps1
  run-npc-repair-tests.ps1
  run-npc-door-tests.ps1
  run-npc-avoidance-tests.ps1
  run-npc-traffic-tests.ps1
  run-npc-behavior-tests.ps1
  run-npc-interaction-tests.ps1
  run-npc-streaming-save-tests.ps1
  run-npc-soak-tests.ps1
  run-npc-observation-tests.ps1
  run-all-npc-tests.ps1

tools/run-all-test-runners.ps1

docs/npc_pathfinding/
  BASELINE_AUDIT.md
  ARCHITECTURE.md
  TEST_CATALOG.md
  DEBUGGING.md
  PHASE_00_REPORT.md
  ...
  PHASE_13_REPORT.md
  FINAL_ACCEPTANCE_REPORT.md
```

Do not create all files as empty scaffolding. Create each module in the phase that implements and tests it.

---

## 7. Core Runtime Contracts

Use typed `RefCounted` classes or resources for these contracts. Avoid passing free-form dictionaries among runtime layers.

### 7.1 `TraversalProfile`

Required fields:

- stable profile ID;
- body radius;
- body standing height;
- crouched height if supported;
- step-up height;
- safe step/drop height;
- maximum floor angle;
- maximum walk speed;
- acceleration/deceleration;
- turning response;
- door minimum width;
- headroom margin;
- personal-space margin;
- abilities: walk, sprint, jump, crouch, swim, climb, open doors, use locked doors, break doors, carry bulky item;
- terrain capability tags;
- hazard tolerances;
- traversal-cost modifiers.

The default adult NPC profile shall be derived from the real NPC capsule and tested against the shared motor. The player profile shall preserve current player feel and constants unless an explicit, tested correction is required.

### 7.2 `NavSpanKey`

A key must identify a specific walkable surface, not only XZ. It shall include:

- tile/chunk coordinate;
- local XZ sample coordinate;
- vertical layer/index or quantized surface key;
- topology generation/revision compatibility as needed for stale-key detection.

Two surfaces above one another at the same XZ must have distinct keys.

### 7.3 `NavSpanData`

Required fields:

- key;
- exact world standing position;
- floor normal;
- floor/terrain material tag;
- available headroom;
- lateral clearance estimate;
- semantic region and tags;
- hazard/exposure/light values;
- narrowness/bottleneck classification;
- immutable local adjacency indices;
- topology revision.

### 7.4 `NavEdgeData`

Required fields:

- source and destination span keys;
- traversal kind: walk, step, drop, jump, door, climb, special;
- geometric length;
- vertical delta and slope;
- minimum clearance;
- profile capability requirements;
- base travel cost;
- dynamic state provider ID where applicable;
- one-way/bidirectional flag;
- bottleneck/resource ID where applicable.

An edge is feasible only if the requesting profile satisfies all requirements.

### 7.5 `RouteRequest`

Required fields:

- request ID;
- owner NPC ID;
- start position/span;
- goal specification, which may be a point, span set, semantic region, smart-object slot, or portal side;
- traversal profile ID;
- purpose/goal kind;
- priority class;
- allow-partial flag;
- maximum acceptable goal distance;
- semantic preferences and avoidances;
- current topology and dynamic revision expectations;
- cancellation token/generation;
- request timestamp/simulation tick.

### 7.6 `RouteResult` and `RouteCorridor`

`RouteResult` includes status, reason, cost, computation metrics, relevant revisions, and a corridor when successful.

`RouteCorridor` includes:

- ordered spans/portals;
- smoothed physical steering points;
- explicit traversal actions at their exact route positions;
- tile/edge dependencies;
- expected duration and cost breakdown;
- bottleneck reservation requirements;
- a monotonic route generation;
- arrival contract;
- no hidden partial semantics.

### 7.7 `NpcAgentContext` and `NpcBlackboard`

Separate durable identity from transient execution state.

Durable/context fields include:

- stable NPC ID;
- body and component references;
- role and schedule profile;
- traversal profile;
- home/interior assignment;
- job assignment;
- inventory/needs adapters;
- settlement and faction IDs;
- deterministic RNG streams.

Transient blackboard fields include:

- selected goal and utility breakdown;
- current symbolic plan;
- current action and substate;
- route request/result/corridor generation;
- current target and arrival contract;
- traffic reservations;
- door request/token;
- blocker and wait-for owner;
- progress timestamp and distance history;
- recovery count and reason;
- perception snapshot;
- schedule state;
- explicit terminal status.

### 7.8 Enumerated reasons

Define central enums/StringNames for at least:

- route status;
- route failure reason;
- action status;
- action failure reason;
- interaction status;
- door state;
- reservation status;
- recovery reason;
- schedule state;
- goal kind;
- traversal kind;
- dynamic change kind.

Do not spread ad hoc reason strings throughout the code. Telemetry may render readable labels from the central enums.

---

## 8. Shared Physics-Authoritative Character Motor

### 8.1 Required design

Extract the movement physics that should be shared by the player and NPCs into `CharacterMotor3D.gd`, driven by a `CharacterMotorCommand` and a profile/configuration object.

The player remains a `CharacterBody3D` and continues to own input, camera, survival sprint checks, head bob, and presentation. The NPC owns AI-generated movement commands. Both feed the same tested physical motor for:

- acceleration and deceleration;
- horizontal velocity;
- gravity;
- floor detection;
- floor snapping;
- slope classification;
- step/drop handling;
- jump requests where supported;
- collision movement;
- actual displacement and collision result reporting.

The extraction must preserve existing player behavior through characterization tests. Do not casually retune the player to make NPC tests easier.

### 8.2 NPC body

`NpcAgent.tscn` shall use `CharacterBody3D` and contain:

- collision shape derived from traversal profile;
- visual root;
- animation/presentation hooks;
- `NavigationAgent3D` or server RID only for avoidance;
- interaction/perception areas only where required;
- `NpcAgent.gd`;
- no route algorithm embedded in the scene script.

Centralize collision layer/mask definitions. Audit existing layer use before assigning bits. The final matrix must ensure:

- world terrain and blocking construction stop the body;
- closed doors stop the body;
- open doors do not leave a phantom blocker;
- NPCs cannot physically pass through the player or another solid actor;
- nonblocking interaction areas do not stop movement;
- decorative paths/torches remain nonblocking as intended;
- combat/projectile masks remain correct.

### 8.3 Motor output

Every motor tick returns a structured result containing:

- requested velocity;
- avoidance velocity;
- applied velocity;
- actual displacement;
- floor/wall/ceiling contacts;
- collision owners;
- grounded state;
- whether forward progress occurred;
- whether motion was blocked and by what category;
- current safe standing position.

The route follower advances only from this result and the actual body transform after physics.

### 8.4 Forbidden motor behavior

- no route-position assignment;
- no “unstick” teleport;
- no hidden floor-height snap that bypasses blocking geometry;
- no disabling the NPC collider to get through a door;
- no treating a collision query as permission to skip actual collision movement;
- no brain-update throttling that skips physics for some active NPCs.

High-level brains may update at lower rates. Every active NPC motor must update every physics tick.

---

## 9. Event-Driven Navigation World

### 9.1 Source of truth

Replace scene scans and hash-based revision checks with `NavigationChangeBus` and monotonically increasing revisions.

The systems that mutate the world must emit events at the mutation point. Hook all relevant creation, removal, state, and streaming paths, including:

- chunk creation;
- chunk unload;
- terrain/height edits;
- block creation;
- block removal/destruction/collapse;
- structural placement changes;
- prop creation/removal/harvest;
- movable blocker state if introduced;
- door registration and state/access/destruction changes;
- structure/home/interior metadata creation;
- semantic hazard/light/settlement changes that affect route cost.

Each event includes a stable object ID, affected world bounds, affected tile keys, change kind, and source revision. Coalesce multiple changes to the same tile during one frame.

### 9.2 Tile construction

Build navigation tiles lazily for areas required by active NPCs, assigned settlements, route requests, and promotion boundaries. Do not eagerly build the entire infinite world.

A tile builder shall:

1. receive an immutable snapshot of authoritative world data for the tile plus a border sufficient for edge construction;
2. enumerate all candidate walkable surfaces, including terrain and valid tops/interiors represented by construction data;
3. retain multiple vertical surface spans at one XZ location;
4. reject surfaces whose normal exceeds the profile-independent maximum floor limit;
5. compute headroom and body clearance using conservative geometry/physics validation;
6. build profile-annotated edges between neighboring spans;
7. verify step, drop, slope, and corner clearance;
8. add explicit special/door edges rather than pretending the portal is ordinary empty floor;
9. tag semantic regions and bottlenecks;
10. publish an immutable tile with a new topology revision.

The default horizontal sampling resolution shall remain aligned to the voxel world's `CELL` grid for stable structure/door alignment. Smooth motion is produced by corridor smoothing and capsule sweeps, not by pretending a cell-center polyline is the final trajectory. Where a semantic interior or portal requires finer placement, use explicit approach/interaction/staging anchors rather than globally doubling graph density.

### 9.3 Multi-surface requirement

A single `height_for_cell()` result is forbidden as the topology representation. A column may contain zero, one, or multiple spans. Tests must include:

- terrain beneath a raised walkable surface;
- a bridge with terrain/water below;
- an overhead obstruction with insufficient headroom;
- two vertically separated walkable levels that do not connect without a real edge;
- a tunnel/covered passage;
- a doorway whose frame leaves sufficient or insufficient capsule clearance by profile.

### 9.4 Topology versus dynamic state versus semantics

Maintain three logically separate layers:

1. **Topology:** persistent walkable spans and possible edges.
2. **Dynamic state:** current doors, temporary blockers, reservations, actors, hazards, destruction, and streamed availability.
3. **Semantics:** roads, buildings, rooms, homes, guard posts, work areas, resources, public/private entrances, shelter, danger, lighting, and settlement bounds.

A changing actor shall not force a topology rebuild. A destroyed wall or placed block may. A door state usually changes dynamic edge feasibility/cost, while door destruction may also alter topology.

### 9.5 Rebuild scheduling

Use `NavigationBuildQueue` with a per-frame budget and priority:

1. tiles under/adjacent to an active moving NPC;
2. tiles intersecting an active corridor;
3. tiles containing a requested goal;
4. nearby settlement tiles;
5. prefetch tiles for likely next route segments;
6. background tiles.

No full scene-tree scan per frame is permitted. No tile may remain silently stale after an acknowledged change. If a required tile is rebuilding, route status is `PENDING` with reason `WAITING_FOR_TOPOLOGY`.

---

## 10. Hierarchical Route Planning

### 10.1 Two-level minimum hierarchy

Implement at least two levels:

- **abstract/global graph:** navigation tiles/chunks, contiguous border entrances, semantic region portals, building entrances, door portals, and special traversal links;
- **local graph:** actual surface spans and edges within the selected abstract corridor.

The abstract graph shall cache entrance-to-entrance costs per tile, traversal-profile class, and tile revision. Invalidate only affected cache entries.

### 10.2 Search behavior

- Use deterministic A* for global and local searches.
- Use Euclidean travel-time lower bounds as admissible heuristics for the pure shortest-time component.
- Keep all route costs nonnegative.
- Break ties deterministically by `(f, h, stable span/portal ID)` or another documented stable order.
- Do not use a small hard expansion cap that converts a solvable request into a fake partial route.
- Time-slice searches according to a configurable microsecond/expansion budget; retain open/closed/search state between frames.
- Cancellation is generation-based and safe.
- Start/goal snapping shall consider capsule profile, connectivity, vertical layer, and line-of-access. It may not snap through a wall or from one floor to another merely because the points are close in 3D.

### 10.3 Route cost model

Implement one centralized `RouteCostModel` whose output includes a cost breakdown. Suggested normalized form:

```text
cost = travel_time
     + terrain_effort
     + slope_effort
     + hazard_penalty
     + exposure_or_light_preference
     + congestion_expected_wait
     + door_expected_wait
     + access/restriction_penalty
     + role_and_goal_semantic_penalty
     + uncertainty_penalty
```

Rules:

- impossible capability/access conditions are infeasible, not merely expensive;
- roads should generally be preferred over equally long rough terrain for civilians/workers;
- guards may prefer patrol/visibility semantics appropriate to duty;
- fleeing civilians prioritize safety and shelter over route length;
- a closed openable door adds opening and queue cost;
- a locked unauthorized door removes that edge;
- dynamic actors contribute predicted wait/congestion, not permanent static walls in the global graph;
- all weights live in named configuration resources and are covered by route-choice tests.

### 10.4 Corridor construction and smoothing

The route result shall be a corridor with explicit actions, not an arbitrary capped list of waypoints.

Post-process local span paths by:

- preserving mandatory portal/action points;
- applying deterministic line-of-sight/string-pulling only when a full-profile capsule sweep proves the shortcut valid;
- preserving safe distance from corners and door frames;
- creating approach, staging, interaction, threshold-entry, threshold-exit, and release points around smart portals;
- attaching tile/edge revision dependencies;
- computing a valid arrival region rather than requiring exact floating-point position equality.

Smoothing may remove redundant walk points. It may never remove a door action, jump link, reservation boundary, or required semantic checkpoint.

---

## 11. Incremental Route Repair

Implement genuine incremental repair for an active local/global corridor rather than naming a full replan “repair.”

### 11.1 D* Lite/LPA* requirements

`IncrementalRouteRepair.gd` shall maintain, for the repair graph:

- `g` values;
- `rhs` values;
- a deterministic priority queue;
- `km` or the equivalent moving-start heuristic adjustment;
- predecessor/successor access;
- changed-edge update propagation;
- a correctness oracle test against a fresh A* result.

Use the standard D* Lite relationship:

```text
rhs(goal) = 0
key(s) = [min(g(s), rhs(s)) + h(start, s) + km,
          min(g(s), rhs(s))]
```

When the start moves, update `km`. When local edge costs/traversability change, update affected vertices and continue `ComputeShortestPath()` under the route budget. When a topology change invalidates the abstraction itself, repair/recompute the affected abstract segment, not the entire world.

### 11.2 Dependency-driven invalidation

Each corridor records relevant tile, edge, door, and semantic revisions. A world event that does not intersect those dependencies shall not force a replan.

Examples:

- a block placed behind the NPC and outside its corridor: no route repair;
- a block placed on the next corridor segment: immediate invalidation/repair;
- a door closing before the NPC reaches it: update dynamic action/edge state;
- a locked door on the route: repair to another entrance or explicit failure;
- a harvested resource that is the goal: cancel the action, choose another target, and replan;
- a chunk unloading across the route: suspend/abstract or repair according to simulation LOD; never continue through absent physical topology.

### 11.3 Repair outcomes

Repair must produce one of:

- repaired corridor;
- safe wait while a temporary dynamic condition clears;
- alternate global corridor;
- partial result only if allowed;
- explicit unreachable/failure;
- action-plan revision because the spatial premise no longer holds.

No infinite replan loop is permitted. Track repeated failures by cause and apply recovery escalation.

---

## 12. Smart Doors and Environment Interaction

### 12.1 Shared interaction authority

Implement `SmartObjectService` as the authoritative way both player and NPC actors request environment actions. The player may keep its ray/interact UX, but the final command must enter the same object controller used by NPCs.

A smart object advertises actions with:

- stable object/action ID;
- required actor capabilities;
- access policy;
- approach/interaction slots;
- preconditions;
- duration/state transition;
- occupancy/capacity;
- result and failure reasons;
- effects/events.

NPC planners reason about these actions. They do not directly mutate object metadata.

### 12.2 Logical `DoorPortal`

Every doorway shall register one logical portal. The portal owns or references:

- stable portal ID;
- one or more physical leaves;
- portal axis and both sides;
- approach pose(s) on each side;
- interaction pose(s);
- staging/pull-out positions;
- threshold occupancy volume;
- leaf sweep/slide volume;
- capsule clearance volume;
- effective width/capacity;
- access policy;
- current state and progress;
- reservation/queue state;
- auto-close/hold-open policy;
- connected navigation spans/regions;
- topology/dynamic revision.

Modify structure generation so adjacent leaves of a double door receive one stable `door_group_id` and leaf indices. Do not rely solely on runtime proximity guessing. Player-placed single doors form their own portal. Existing worlds/saves without new metadata must migrate deterministically.

### 12.3 Door states

Required state machine:

```text
CLOSED
OPENING
OPEN
HELD_OPEN
CLOSING
LOCKED
JAMMED
DESTROYED
```

A separate access flag/policy may coexist where appropriate, but observable transitions must remain explicit.

### 12.4 Idempotent requests

Required command semantics:

- `request_open(actor_id, request_id)`
- `request_hold_open(actor_id, request_id)`
- `release_hold(actor_id, request_id)`
- `request_close(actor_id, request_id)`
- access/lock commands as needed
- cancellation on actor/action invalidation

Repeated open requests leave an opening/open door open. They never close it. Repeated close requests do not bypass safety.

The existing `toggle_door()` may remain as a temporary player compatibility adapter, translating desired state based on the controller. NPCs shall never use it. All callers must be migrated and the blind implementation removed in Phase 13.

### 12.5 Door traversal action sequence

An NPC route using a door shall execute this sequence:

1. Validate that the portal still connects the intended route sides.
2. Validate capability and access.
3. Acquire an approach slot and directional crossing window.
4. Move to the approach pose through normal physics.
5. Face the interaction pose within tolerance.
6. Submit `request_open` through the shared interaction service.
7. Wait for authoritative `TRAVERSABLE_OPEN` confirmation; animation intent alone is insufficient.
8. Acquire/confirm threshold node and edge reservations.
9. Move through the threshold with portal-mode corridor constraints.
10. Confirm the full capsule has cleared threshold and sweep volumes on the exit side.
11. Release the crossing reservation.
12. Transfer the open hold to the next queued compatible actor when its predicted arrival is within the configured inheritance window.
13. Otherwise request close only if portal policy permits it.
14. Continue the route only after the crossing action reports success.

### 12.6 Safe closing

Before accepting/continuing close, prove:

- threshold volume empty;
- leaf sweep/slide volume empty;
- capsule clearance volume empty;
- no crossing reservation active;
- no actor physically entering from either side;
- no queued actor has inherited the opening;
- player clear;
- no carried bulky item intersects;
- object/controller state allows close.

If an actor enters during closing, stop/reopen. A timer may trigger a close *request*; it cannot grant unsafe closure.

### 12.7 Door failure planning

The action planner shall handle:

- locked and authorized: unlock/use key, then open;
- locked and unauthorized: alternate entrance, ask authorized actor if supported, fail with access reason, or explicit break action if role/game rules allow;
- jammed: retry within bounded policy, repair, alternate route, break if allowed, or fail;
- blocked leaf: wait, reposition, move blocker if a legal action exists, or alternate route;
- destroyed: update topology and cross only if the physical opening is valid;
- missing/unloaded: suspend/replan;
- another actor opens it: consume the new state and skip redundant open work;
- opposing traffic: join deterministic directional queue.

---

## 13. Local Steering, Reciprocal Avoidance, and Corridor Following

### 13.1 Division of responsibility

- The route planner chooses a feasible corridor.
- The traffic service schedules contested bottlenecks.
- Reciprocal avoidance adjusts velocity around moving actors in open space.
- The corridor follower prevents drift outside the route's safe region.
- The motor performs physical movement and collision response.

No layer may assume another layer guarantees everything.

### 13.2 Godot avoidance adapter

Use `NavigationAgent3D`/`NavigationServer3D` avoidance only for active actors that need it.

Required behavior:

- update agent position/current velocity every physics tick;
- provide a target even when using avoidance only, because Godot may otherwise return zero safe velocity;
- use grounded 2D-style avoidance where appropriate so vertically separated actors do not interfere;
- set radius/height from the traversal profile, with a small named safety margin;
- bound neighbor distance and neighbor count;
- map game/traffic priority to avoidance priority carefully;
- consume `velocity_computed` as a candidate safe velocity, not as a transform;
- project/clamp the candidate to corridor and portal constraints;
- disable or reduce lateral avoidance inside a granted narrow portal where reservation order is authoritative;
- disable avoidance for abstract/distant NPCs and inactive agents;
- measure registration count and cost.

### 13.3 Corridor follower

The follower shall:

- select a look-ahead point based on speed and corridor curvature;
- slow before sharp turns, interaction poses, doors, and occupied bottlenecks;
- maintain heading without frame-to-frame left/right oscillation;
- use actual displacement to update progress;
- distinguish a wall collision, dynamic actor, reservation wait, door wait, and route invalidation;
- stop within the action/arrival tolerance without orbiting;
- request repair if body drift exceeds corridor tolerance;
- never skip mandatory route actions.

### 13.4 Progress watchdog

Track progress over a sliding window using distance along corridor, not only straight-line distance to the final target.

Escalation sequence:

1. continue/slow for a short transient;
2. classify blocker;
3. wait if an owned temporary condition has a bounded expected release;
4. negotiate/yield/reserve;
5. request local corridor repair;
6. request global alternate route;
7. revise action plan;
8. return explicit failure.

Never teleport as recovery.

---

## 14. Traffic Reservations and Deadlock Resolution

### 14.1 Where reservations are required

Use explicit space-time reservations for:

- door thresholds;
- one-body corridors;
- narrow bridges;
- narrow stairs/ramps;
- interaction approach slots;
- workstation/resource slots;
- any edge classified as too narrow for safe reciprocal passing.

Open plazas and roads normally use reciprocal avoidance and physical collision without reserving every cell.

### 14.2 Reservation contents

A reservation includes:

- stable reservation ID;
- owner actor/action/route IDs;
- resource ID (span, directed edge, portal, slot);
- entry and exit simulation time;
- direction;
- footprint/profile class;
- priority class and inherited priority;
- generation/revision;
- state: requested, granted, active, released, expired, cancelled;
- reason/queue position.

Reserve both node occupancy and directed-edge occupancy. Opposite-direction edge intervals conflict. Same-direction capacity depends on resource definition.

### 14.3 Safe intervals

`SafeIntervalPlanner` shall derive available intervals from current reservations over a rolling horizon and choose a feasible entry time. An actor may wait at a staging span rather than detour or collide.

The rolling horizon and safety buffers must be named configuration values. Reservation expiry is based on simulation time and action state, not a one-frame TTL.

### 14.4 Priority policy

Use deterministic priority classes in this order unless a specific game rule overrides them:

1. immediate life-safety/emergency evacuation;
2. active guard/combat threat response;
3. scripted critical movement;
4. night return-home duty;
5. essential job/resource action;
6. ordinary travel/social action;
7. wander/idle relocation.

Within class:

1. inherited priority;
2. wait age;
3. active reservation continuity;
4. stable NPC ID.

An actor already crossing a resource cannot be preempted mid-crossing.

### 14.5 Deadlock detection

Maintain a wait-for graph: actor A waits for a resource owned by actor B. Detect cycles whenever dependencies change or at a bounded cadence.

Cycle resolution:

1. choose a winner deterministically using effective priority, wait age, and stable ID;
2. apply priority inheritance along the blocking chain;
3. choose a loser with a valid reachable pull-out/staging span;
4. reserve the retreat path/resource;
5. make the loser back out through normal physics;
6. release obsolete claims;
7. resume the winner;
8. clear inheritance when resolved.

If no pull-out exists, impose a deterministic directional batch policy at the bottleneck and hold the opposite side. Report unresolved structural deadlock explicitly rather than jittering forever.

---

## 15. Purpose: Goals, Actions, Schedules, and Reactive Execution

### 15.1 Three-layer intelligence

Implement:

1. `NpcGoalSelector`: utility-based selection of the next meaningful objective;
2. `NpcTaskPlanner`: bounded symbolic planning over a compact action library;
3. `NpcPlanExecutor`: reactive execution and repair of the chosen plan.

Do not encode all intelligence in a giant state machine or a random target chooser.

### 15.2 Utility goal selection

Score candidate goals from:

- threat/safety;
- explicit player/scripted orders;
- schedule obligations;
- guard roster/duty;
- hunger, fatigue, comfort, health;
- role/job assignment;
- settlement needs;
- available known resources and smart-object slots;
- distance, route feasibility, expected duration, risk, and congestion;
- current commitment/hysteresis to avoid thrashing.

The selector must log a utility breakdown. Use hysteresis/minimum commitment where safe so two nearly equal goals do not alternate every update.

Required goal kinds include:

- survive/flee/seek shelter;
- respond to threat;
- report to guard duty;
- patrol/guard/intercept;
- return home;
- sleep/idle inside;
- obtain food/eat;
- perform assigned job;
- harvest/gather;
- deliver/deposit;
- use workstation;
- follow scripted target/order;
- social/idle relocation at semantic anchors;
- recover/replan.

### 15.3 Symbolic task planning

Use a compact GOAP/STRIPS-like action planner or an equivalently explicit bounded planner. Every action definition has:

- preconditions;
- effects;
- base and context cost;
- target/slot binding rules;
- interruptibility;
- timeout/progress policy;
- execution component;
- failure mappings.

Keep the action library small and composable. Search is deterministic and bounded; exhaustion yields an explicit plan failure, not a random movement fallback.

Required action instances include:

- navigate to semantic region/point/slot;
- reserve smart object;
- approach door side;
- open door;
- cross door;
- release/close door;
- approach resource;
- harvest;
- carry/deliver/deposit;
- use workstation;
- equip/use tool where required;
- approach guard post;
- patrol segment;
- intercept reachable position;
- enter home;
- remain/sleep inside;
- wait until safe interval;
- request alternate route;
- recover from blocked state.

Example day work plan:

```text
Select known reachable berry source
Reserve berry interaction slot
Navigate to source
Harvest berries
Select reachable storage/home destination
Navigate to door approach
Open door
Cross door
Close/release door according to policy
Navigate to storage slot
Deposit berries
```

Example night civilian plan:

```text
Select assigned home interior
Navigate to home portal exterior approach
Open door if required
Cross into interior
Release/close door safely
Navigate to interior anchor
Remain inside until schedule/emergency changes
```

### 15.4 Reactive execution

The executor re-evaluates or repairs when:

- route invalidated;
- target/resource removed;
- reservation denied or deadlocked;
- door state/access changes;
- threat appears/disappears;
- player dialogue or script holds the NPC;
- another actor completes the needed action;
- schedule phase changes;
- progress watchdog fires;
- chunk/active simulation state changes;
- actor capability/equipment changes.

Interruption must release owned reservations/holds safely. Do not leak a door hold or workstation slot when a plan changes.

### 15.5 Schedule semantics

Use the existing clock constants and a typed `WorldTimeSnapshot`.

- Dawn begins at existing `DAWN_START_CLOCK`.
- Full day begins at existing `DAY_FULL_CLOCK`.
- Dusk begins at existing `DUSK_START_CLOCK`.
- Full night begins at existing `NIGHT_FULL_CLOCK`.

At dusk:

- civilians and non-duty workers finish or safely interrupt current work and return home;
- off-duty guards return indoors;
- active night guards report to posts/patrol routes;
- exterior/private doors follow night policy after traffic clears.

At full night under normal conditions:

- active duty guards are outside at duty locations or traversing duty routes;
- all other NPCs are in a registered interior or emergency shelter;
- no worker continues an ordinary daytime gathering trip;
- a combat-capable non-guard is still indoors unless an explicit threat/emergency goal is active.

At dawn/day:

- workers leave through doors and travel to reachable semantic work targets;
- guards transition according to roster;
- idle movement uses semantic anchors, not arbitrary raw points;
- goal selection respects needs and world state.

### 15.6 Home/interior truth

Extend structure/home records with:

- stable building/home ID;
- interior room/region ID;
- one or more validated interior anchors;
- owning door portal IDs;
- exterior porch/approach anchor;
- emergency shelter fallback where applicable;
- occupancy capacity and residents.

An NPC is indoors only if its capsule center and required footprint are inside the registered interior volume/region on the correct surface span. The threshold does not count. Porch fallback remains a failure/fallback state and must never satisfy `RETURN_HOME`.

### 15.7 Guard duty truth

Create explicit guard roster/duty assignments. `canFight` means combat capability only. It must not automatically imply night duty.

A duty assignment contains:

- guard NPC ID;
- shift time;
- post/patrol region;
- route/visibility constraints;
- replacement/relief policy;
- threat override policy.

Night tests shall include:

- an assigned guard outside on duty;
- an off-duty guard indoors;
- a fighter without guard role indoors;
- a civilian indoors;
- threat response with explicit reason;
- return to schedule after threat clears.

---

## 16. Semantic World Awareness and Environment Interaction Parity

### 16.1 Semantic anchors

Register stable semantic anchors/regions for:

- roads and paths;
- building interiors;
- entrances;
- homes;
- beds/rest positions;
- guard posts and patrol segments;
- fields;
- trees/log sources;
- rock/ore sources;
- berry sources;
- storage/deposit positions;
- workbenches/anvils/furnaces/trader stalls;
- public gathering areas;
- shelter;
- danger/hazard zones;
- pull-outs/staging points near bottlenecks.

Goal selection chooses among known semantic candidates and asks the route planner to score reachability/cost. It does not sample raw random world coordinates.

### 16.2 Player/NPC interaction parity

For an actor with equivalent capability and access:

- the same door state and collision apply;
- the same resource availability applies;
- the same interaction controller accepts/rejects actions;
- the same lock/key/access facts apply;
- the same workstation capacity applies;
- the same block/terrain edits affect traversability;
- the same hazard geometry applies.

Input UX may differ. World truth may not.

### 16.3 Knowledge boundaries

- Navigation topology may know actual colliders.
- A job planner may know assigned settlement resources or perceived/memorized resources.
- A civilian shall not select an unseen newly spawned resource across the world without an information source.
- A guard may know reported threats through settlement/guard systems.
- Debug/test injection must be explicit and absent from normal play.

---

## 17. Active and Abstract Simulation, Streaming, and Saves

### 17.1 Simulation levels

At minimum support:

- **active physical:** full body, physics, local avoidance, detailed corridor/action execution;
- **nearby reduced brain:** full physics, lower high-level decision cadence;
- **abstract distant:** semantic region/portal transit with bounded event simulation, no physical body movement through unloaded geometry.

The motor remains every physics tick for every active body. Brain cadence may be staggered by state, for example faster during combat/door traffic and slower while safely idling indoors.

### 17.2 Promotion/demotion

When promoting an abstract NPC:

1. identify its semantic route position/region;
2. ensure required chunks/topology are loaded;
3. select a valid unoccupied surface span consistent with its abstract state;
4. reserve the spawn footprint;
5. place through `NpcSafePlacementService`;
6. instantiate/enable physical components;
7. resume the action plan from a consistent checkpoint.

When demoting:

- do not demote inside a door threshold, active collision, combat, or contested bottleneck;
- release local avoidance and physical reservations safely;
- preserve high-level action/route region state, not transient waypoints.

### 17.3 Save policy

Persist durable facts only:

- NPC identity, role, home, job, roster assignment;
- needs, inventory, equipment;
- durable high-level goal/commitment where useful;
- abstract region/transit state;
- door durable state such as lock/destroyed state where already part of world save;
- schema version.

Do not persist:

- RVO state;
- local steering velocity;
- detailed route nodes/corridor;
- reservations/queues;
- wait-for graph;
- transient door request tokens;
- planner open/closed sets;
- debug traces.

On load, reconstruct transient state and validate placement/topology. Save changes must be additive with deterministic defaults for old saves and explicit migration tests.

---

## 18. Telemetry, Debugging, and Performance Contracts

### 18.1 Per-NPC debug state

Expose, behind a debug switch:

- NPC ID/name/role/duty;
- schedule state;
- current goal and utility score;
- current plan/action/substate;
- route status/reason/generation;
- next corridor point/action/portal;
- topology revisions;
- current blocker;
- reservations and queue position;
- wait-for dependencies/effective priority;
- progress timer;
- recovery count/reason;
- last terminal failure;
- motor contacts and actual speed.

Do not put this clutter in the normal HUD.

### 18.2 Structured trace

Maintain bounded ring buffers per NPC and global counters. Events shall include simulation tick/time, actor, category, state transition, related IDs, reason, and metrics. Default ring capacity should be named and bounded; 256 events per active NPC is a reasonable starting value.

On a focused test failure, write the relevant trace and deterministic replay parameters to the report artifact.

### 18.3 Required metrics

Instrument:

- route requests/completions/failures/cancellations;
- expansion counts and route latency;
- cache hits/misses;
- tile builds/rebuilds and time;
- repair versus full replan counts;
- motor blocked ticks and contacts;
- avoidance-active agent count and compute callbacks;
- reservation waits/denials;
- deadlock cycles/resolutions;
- door opens/holds/closes/obstruction reversals;
- action plan generation and repair;
- schedule compliance counts;
- active/abstract promotions;
- memory/cache sizes.

### 18.4 Frame budgets

Use configurable budgets and measure them. Initial production targets:

- navigation build work: target average under 2 ms per frame, hard slice under 4 ms;
- route/repair work: target average under 2 ms per frame, hard slice under 4 ms;
- high-level brain work: target average under 1.5 ms per frame, hard slice under 3 ms;
- no single search/build job may monopolize a frame; it must yield and resume;
- same-town route request: p95 completion within 100 ms of simulation time once required tiles are ready;
- multi-chunk route request: p95 completion within 250 ms once required tiles are ready;
- 32 active NPC acceptance scenario: p95 total NPC autonomy CPU under 6 ms and no sustained missed 60 Hz physics deadline on the reference machine;
- 64 active NPC stress scenario: no crash, leak, unbounded queue, or deadlock; report measured cost even if it is not a shipping density.

If the reference hardware cannot meet a numeric target, do not silently relax it. Profile, optimize, report the measured result and bottleneck, and obtain explicit approval for a revised target.


---

## 19. Test Architecture and Efficient Runner Protocol

### 19.1 Testing principles

The existing broad playtest is a continuity gate, not the iteration loop for this redesign. Build focused suites that start only the minimum fixture required for their domain.

Use three fixture levels:

1. **Pure contract/algorithm fixture:** no `Main.tscn`; tests typed contracts, queues, planners, priorities, state machines, and deterministic tie-breaking.
2. **Synthetic physical fixture:** a small deterministic `NpcSyntheticWorld` with real Godot physics, doors, spans, agents, and controllable obstacles; avoids full procedural-world startup for motor/navigation/traffic iteration.
3. **Real-world integration fixture:** instantiates `Main.tscn`, generated town/chunks, real structures, player, saves, jobs, day/night visuals, and streaming.

Every asynchronous test must use bounded simulation steps, explicit state/event conditions, and a failure trace. Avoid “wait N seconds and hope.” Timeouts are backstops, not the primary assertion.

All physics movement tests shall use fixed 60 Hz physics. High-level simulations may advance controlled clock snapshots faster than real time while keeping physics ticks fixed.

### 19.2 Common focused runner

Implement `NpcAutonomyTestRunner.gd` with suite and case filtering:

- `VOXEL_NPC_TEST_SUITE`
- `VOXEL_NPC_TEST_CASE`
- `VOXEL_NPC_TIME_MODE=day|night|both|transition`
- `VOXEL_NPC_TEST_SEED`
- `VOXEL_NPC_TEST_REPORT`
- `VOXEL_NPC_TEST_PROGRESS`
- `VOXEL_NPC_TEST_TRACE_DIR`
- `VOXEL_NPC_TEST_SCREENSHOT_DIR`
- `VOXEL_NPC_TEST_VISIBLE=0|1`

`tools/npc/run-npc-suite.ps1` is the common wrapper. Domain scripts provide a default suite and forward optional case/time/seed/visible parameters.

The wrapper must:

- resolve the same bundled Godot executable convention as existing scripts;
- delete stale report/progress files before launch;
- use `--fixed-fps 60`;
- default to headless except observation runs;
- print the fresh JSON report;
- return nonzero if Godot exits nonzero, the fresh report is missing, any test failed, or the runner watchdog expires;
- record wall duration;
- never accept a stale report as success.

### 19.3 JSON report schema

Every focused report shall include:

```text
schemaVersion
suite
caseFilter
timeMode
seed
branch
gitCommit
engineVersion
startedUtc
finishedUtc
durationSeconds
resultCount
failureCount
results[]
metrics
artifacts
```

Each result includes ID, time mode, seed, pass/fail, duration, assertions, key state, and trace/replay artifact on failure.

### 19.4 Canonical clock helpers

`NpcTestClock` shall expose:

- `set_hour(hour)` using `fposmod(hour / 24.0 - CLOCK_DISPLAY_OFFSET, 1.0)`;
- `set_canonical_day()` using `time_of_day = 0.25`;
- `set_canonical_night()` using `time_of_day = 0.75`;
- `freeze()`;
- `advance_hours()` for transition tests;
- typed `WorldTimeSnapshot` generation.

When using real `Main.tscn`, call/update sky and schedule consumers after changing time. Freeze or reapply the test time so a long test cannot drift across a schedule boundary unintentionally.

### 19.5 Day/night matrix

Every suite that instantiates an NPC, route purpose, interaction, or physical traversal shall run in both canonical day and canonical night unless the test explicitly targets a transition.

Clock-independent algorithm tests may assert identical topology/search behavior under both snapshots in one test. Behavior tests must assert different role/schedule outcomes.

Minimum role matrix at night:

- assigned guard: outside at reachable duty post/patrol or explicit threat intercept;
- off-duty guard: inside assigned home/shelter;
- combat-capable non-guard: inside assigned home/shelter;
- worker/forager/trader/civilian: inside assigned home/shelter;
- scripted/emergency actor: exception only with explicit override reason.

Minimum day matrix:

- workers travel to reachable job semantics and perform actions;
- foragers acquire and use real resources;
- guards perform day role/patrol as configured;
- idle civilians choose semantic anchors;
- doors and traffic remain safe.

### 19.6 Geometry assertions

Create reusable assertions for:

- capsule overlap/penetration against blocking layers;
- swept segment intersection;
- actual body inside semantic interior volume;
- body entirely clear of door threshold/sweep volume;
- distinct actor footprints;
- edge-swap detection;
- corridor adherence;
- no movement transform write counters;
- no-progress duration;
- terminal result within a bounded window;
- route cost/choice;
- deterministic replay equality.

A test that only checks final distance is insufficient for collision, door, or traffic correctness.

### 19.7 Observation runner

`NpcObservationRunner.gd` and `run-npc-observation-tests.ps1` shall create reviewable evidence for:

- noon work traffic;
- dusk return-home wave;
- midnight civilian interiors and guard duty;
- dawn shift transition;
- two-way door traffic;
- crowded road/plaza avoidance;
- dynamic block/route repair;
- player and NPC sharing a door.

Capture:

- screenshots at defined checkpoints;
- a compact state timeline/CSV or JSON;
- schedule-compliance counts;
- door/traffic events;
- final traces for selected NPCs.

Run headless captures at every applicable phase gate. Run visibly during Phase 13 final review when the environment supports it. If visible execution is impossible, record that honestly and inspect generated captures; do not claim visible observation occurred.

### 19.8 Repository-wide all-runner gate

Create `tools/run-all-test-runners.ps1`. It shall run all commands, collect every result, and return failure only after attempting all runners so the report shows the complete regression state.

The mandatory phase-boundary set is:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
.\tools\run-npc-navigation-tests.ps1
.\tools\run-playtest.ps1
.\tools\story\run-story-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
node .\tools\art\validate-visual-manifest.mjs
```

If additional repository test runners are discovered or added, register them in this all-runner script. A phase report must list the exact runner registry used.

`run-all-npc-tests.ps1` shall run every NPC suite implemented up to that point. It shall not silently skip a suite because the phase did not modify it.

At phase end, run the all-runner gate on the phase branch and again on merged `master`.

---

## 20. Test Catalog Naming and Minimum Cases

Use stable IDs in the form:

```text
npc_<domain>_<behavior>_<variant>_<time>
```

Do not rename IDs casually; reports should be comparable across phases.

Minimum final catalog follows. Phases below assign when each case becomes mandatory.

### 20.1 Contract and determinism

- `npc_contract_route_status_terminal`
- `npc_contract_partial_never_arrival`
- `npc_contract_stable_tie_break`
- `npc_contract_profile_capability_filter`
- `npc_contract_rng_stream_isolation`
- `npc_contract_bounded_trace_and_cache`
- `npc_contract_clock_day_snapshot`
- `npc_contract_clock_night_snapshot`
- `npc_contract_guard_duty_not_can_fight`

### 20.2 Motor and physical collision

- `npc_motor_player_characterization_flat`
- `npc_motor_player_characterization_slope`
- `npc_motor_npc_flat_acceleration`
- `npc_motor_npc_slope_limit`
- `npc_motor_npc_step_up_limit`
- `npc_motor_npc_safe_drop`
- `npc_motor_wall_slide_no_penetration`
- `npc_motor_fence_window_corner_no_penetration`
- `npc_motor_closed_door_blocks`
- `npc_motor_open_door_clears`
- `npc_motor_player_npc_solid_separation`
- `npc_motor_no_route_transform_write`
- `npc_motor_no_unstick_teleport`

Run applicable cases under day and night snapshots.

### 20.3 Navigation world

- `npc_navworld_event_block_add_dirty_exact_tiles`
- `npc_navworld_event_block_remove_dirty_exact_tiles`
- `npc_navworld_event_chunk_load_unload`
- `npc_navworld_no_scene_scan_revision`
- `npc_navworld_multisurface_bridge`
- `npc_navworld_tunnel_headroom`
- `npc_navworld_stacked_surfaces_disconnected`
- `npc_navworld_profile_clearance_small_large`
- `npc_navworld_corner_cut_rejected`
- `npc_navworld_door_portal_edge_registered`
- `npc_navworld_semantic_home_interior`
- `npc_navworld_semantic_guard_post`

### 20.4 Route planning

- `npc_route_same_tile_optimal_oracle`
- `npc_route_multi_tile_hierarchy`
- `npc_route_cross_loaded_chunks`
- `npc_route_road_preferred_equal_time`
- `npc_route_hazard_avoided_by_civilian`
- `npc_route_guard_semantic_preference`
- `npc_route_closed_openable_door_action`
- `npc_route_locked_unauthorized_alternate`
- `npc_route_start_snap_no_wall_cross`
- `npc_route_goal_snap_correct_vertical_layer`
- `npc_route_no_iteration_cap_false_failure`
- `npc_route_partial_explicit_only`
- `npc_route_deterministic_replay`

### 20.5 Incremental repair

- `npc_repair_unrelated_change_no_replan`
- `npc_repair_block_added_on_corridor`
- `npc_repair_block_removed_shortens_route`
- `npc_repair_door_locked_alternate`
- `npc_repair_resource_removed_replan_action`
- `npc_repair_chunk_unload_suspends_or_alternates`
- `npc_repair_matches_fresh_astar_cost`
- `npc_repair_bounded_no_loop`

### 20.6 Doors and shared interaction

- `npc_door_idempotent_open`
- `npc_door_idempotent_close`
- `npc_door_single_open_cross_close`
- `npc_door_double_coordinated_portal`
- `npc_door_player_npc_shared_authority`
- `npc_door_threshold_occupied_no_close`
- `npc_door_sweep_occupied_no_close`
- `npc_door_obstructed_closing_reopens`
- `npc_door_queue_inherits_opening`
- `npc_door_opposing_direction_ordered`
- `npc_door_locked_authorized`
- `npc_door_locked_unauthorized_alternate`
- `npc_door_jammed_failure_or_alternate`
- `npc_door_destroyed_topology_update`
- `npc_door_no_timeout_safety_override`

Every door crossing case runs day and night. At night include both guard-outbound and civilian-inbound variants.

### 20.7 Avoidance and corridor following

- `npc_avoidance_head_on_open_road`
- `npc_avoidance_crossing_paths`
- `npc_avoidance_overtake_slow_actor`
- `npc_avoidance_crowded_plaza_progress`
- `npc_avoidance_corridor_boundary_respected`
- `npc_avoidance_no_left_right_oscillation`
- `npc_avoidance_wall_not_treated_as_rvo_only`
- `npc_avoidance_inactive_agents_disabled`
- `npc_follow_arrival_no_orbit`
- `npc_follow_progress_watchdog_classifies_blocker`

### 20.8 Traffic and deadlock

- `npc_traffic_two_actor_one_door_swap`
- `npc_traffic_node_and_edge_conflict`
- `npc_traffic_bridge_direction_batch`
- `npc_traffic_stair_single_capacity`
- `npc_traffic_four_actor_cycle_resolved`
- `npc_traffic_priority_emergency_over_wander`
- `npc_traffic_active_crossing_not_preempted`
- `npc_traffic_wait_age_prevents_starvation`
- `npc_traffic_pullout_retreat_physical`
- `npc_traffic_no_permanent_deadlock_soak`

### 20.9 Behavior and schedule

- `npc_behavior_day_worker_reachable_job`
- `npc_behavior_day_forager_harvest_eat`
- `npc_behavior_day_guard_patrol`
- `npc_behavior_day_idle_semantic_anchor`
- `npc_behavior_dusk_civilian_returns_before_night`
- `npc_behavior_night_assigned_guard_outside`
- `npc_behavior_night_off_duty_guard_inside`
- `npc_behavior_night_fighter_non_guard_inside`
- `npc_behavior_night_worker_inside`
- `npc_behavior_night_forager_inside`
- `npc_behavior_night_trader_inside`
- `npc_behavior_night_porch_not_inside`
- `npc_behavior_night_blocked_home_explicit_failure_no_teleport`
- `npc_behavior_threat_exception_explicit`
- `npc_behavior_post_threat_schedule_restored`
- `npc_behavior_goal_hysteresis_no_thrashing`
- `npc_behavior_unreachable_goal_terminal`

### 20.10 Environment interaction

- `npc_interaction_resource_reserved_single_user`
- `npc_interaction_resource_removed_during_approach`
- `npc_interaction_workstation_capacity`
- `npc_interaction_deposit_through_real_door`
- `npc_interaction_no_harvest_through_wall`
- `npc_interaction_player_npc_same_availability`
- `npc_interaction_access_policy_shared`

### 20.11 Streaming and saves

- `npc_stream_active_to_abstract_safe`
- `npc_stream_abstract_to_active_safe_span`
- `npc_stream_no_promote_in_door_threshold`
- `npc_stream_route_across_chunk_boundary`
- `npc_stream_unloaded_goal_pending_not_teleport`
- `npc_save_old_snapshot_defaults`
- `npc_save_round_trip_durable_state`
- `npc_save_no_transient_route_or_reservation`
- `npc_save_night_schedule_reconstructs`
- `npc_save_door_durable_state_reconstructs`

### 20.12 Soak, fuzz, and observation

- `npc_soak_32_agents_day_10_seeds`
- `npc_soak_32_agents_night_10_seeds`
- `npc_soak_64_agents_stress`
- `npc_soak_dynamic_blocks_day_night`
- `npc_soak_door_traffic_day_night`
- `npc_fuzz_route_repair_matches_oracle`
- `npc_fuzz_no_penetration_random_obstacles`
- `npc_fuzz_terminal_outcomes_random_goals`
- `npc_observe_noon_work`
- `npc_observe_dusk_return_home`
- `npc_observe_midnight_guard_and_interiors`
- `npc_observe_dawn_transition`

---

## 21. Git, Commit, Merge, and Phase-Report Protocol

### 21.1 Branch lifecycle

At phase start:

```powershell
git switch master
git status --short
# Update from remote only when configured, safe, and explicitly appropriate.
git switch -c <phase-branch-name>
```

If the worktree is dirty:

- identify which changes are user work;
- do not stash/reset/clean them without authorization;
- avoid overwriting them;
- document the condition in the phase report;
- if safe isolation is impossible, stop and report the blocker.

Before phase merge:

```powershell
git status --short
.\tools\run-all-test-runners.ps1
# Write/update the phase report after the final branch run.
git add <intentional files only>
git commit -m "<behavior-focused phase commit>"
git switch master
git merge --no-ff <phase-branch-name> -m "Merge <phase>: <behavior>"
.\tools\run-all-test-runners.ps1
```

If merged `master` fails, do not start the next phase. Create `<phase-branch-name>-repair` from `master`, fix, repeat all gates and report.

Do not delete the phase branch until final acceptance unless the user requests cleanup.

### 21.2 Commit discipline

Prefer a small sequence of coherent commits within a phase when it improves review, for example:

1. contracts/infrastructure;
2. implementation;
3. tests;
4. documentation/report.

Do not commit generated transient reports that are intentionally ignored unless the specification requires a tracked baseline or report. The phase Markdown report is tracked.

### 21.3 Mandatory phase report

Each `docs/npc_pathfinding/PHASE_XX_REPORT.md` shall contain:

1. **Phase identification:** branch, base commit, final commit, merge commit, dates.
2. **Objective:** copied/summarized from this specification.
3. **Pre-phase state:** relevant baseline behavior and known risks.
4. **Implementation summary:** architecture and runtime behavior, not only file names.
5. **Files added/changed/removed:** grouped by responsibility.
6. **Data/API contracts introduced or changed.**
7. **Migration/compatibility behavior.**
8. **Focused test evidence:** exact commands, time modes, result counts, failures, durations, report paths.
9. **Day/night evidence:** exact scenarios, state counts, screenshots/traces where applicable.
10. **Full all-runner evidence on phase branch:** every runner, exit/result, duration.
11. **Full all-runner evidence on merged `master`.**
12. **Performance and boundedness metrics.**
13. **Determinism/world-signature evidence.**
14. **Invariant checklist:** every phase gate with evidence.
15. **Deviation register:** any divergence from this document, why, consequences, and approval. Expected value is “none.”
16. **Known issues/debt:** only items outside the phase contract; no gate failure may be relabeled debt.
17. **Static audit results:** forbidden pattern searches relevant to phase.
18. **Risk assessment for next phase.**
19. **Final verdict:** pass/fail and whether merge is allowed.

The report must be detailed enough for a reviewer to determine whether the implementation follows this specification without rereading every changed line.

### 21.4 Review output

At phase end, Codex shall present an in-depth summary derived from the tracked report, including failures encountered and fixed, test counts, day/night evidence, performance, deviations, merge hash, and next-phase readiness. Do not hide intermediate failures; distinguish them from the final green state.

---

## 22. Prohibited Shortcuts and Static Audit Rules

The following are forbidden in final production code and should be searched at relevant phase gates:

1. NPC spawn as `StaticBody3D`.
2. Normal locomotion assignment to `position`, `global_position`, `transform`, or `global_transform`.
3. NPC use of `toggle_door`.
4. Door close logic that accepts occupancy because a timer expired.
5. Whole scene-tree scanning to determine navigation revision.
6. A single XZ-to-height map as the complete navigation topology.
7. Arbitrary raw random world points as ordinary NPC goals.
8. Hard-coded small A* iteration caps that convert pending work into failure.
9. Silent partial routes.
10. Porch/threshold counted as indoor home arrival.
11. `canFight` used as the guard-duty predicate.
12. One-frame reservations as the bottleneck coordination model.
13. Fixed sidestep-vector lists as the primary multi-agent avoidance system.
14. Collider disabling on the NPC to pass obstacles.
15. Teleporting as stuck recovery.
16. Saving local paths, RVO state, reservations, or planner queues.
17. Test-only branches in production behavior that fake success.
18. Deleting or weakening existing tests instead of fixing behavior.
19. Adding another `Main*.gd` inheritance layer for this system.
20. Reordering world-generation RNG or accepting unexplained world-signature drift.

Static searches shall account for legitimate spawn/load placement and player/camera code. Reports must list inspected matches and explain allowed instances.


---

# PHASE IMPLEMENTATION PLAN

## Phase 00 — Baseline Freeze, Focused Harness, and Controlling Documentation

**Branch:** `npc-pathfinding/phase-00-baseline-harness`  
**Primary focused runner:** `tools/npc/run-npc-contract-tests.ps1`  
**Purpose:** Create reliable, fast, deterministic infrastructure and freeze evidence before runtime behavior changes.

### Required implementation

1. Copy this specification into the repository root as `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md` if it is not already there.
2. Update `AGENTS.md` to identify this file as the controlling NPC implementation specification.
3. Add a clear superseded notice at the top of `CODEX_NPC_PATHFINDING_COMPLETION_PLAN.md`; do not delete it yet because it documents the prior attempt.
4. Write `docs/npc_pathfinding/BASELINE_AUDIT.md` with exact current architecture, current test counts, known defects, and file/line evidence.
5. Preserve copies or summaries of the latest valid focused NPC report, broad playtest report, world signature, and relevant visual/story state. Do not commit large transient artifacts unless already tracked; record hashes/counts/paths in the audit.
6. Create the common focused runner infrastructure from Section 19:
   - common scene and runner;
   - suite/case/time/seed filters;
   - fresh report/progress handling;
   - deterministic watchdog;
   - JSON schema;
   - PowerShell wrapper;
   - common assertions and test clock.
7. Create `tools/run-all-test-runners.ps1` and a machine-readable runner registry. It must execute every runner and aggregate failures without accepting stale artifacts.
8. Add contract/characterization tests that pass on the current code and protect migration:
   - canonical day and night clock snapshots;
   - deterministic ID/tie-break helper behavior introduced in this phase;
   - current player flat/slope movement characterization metrics;
   - existing save version/default-load characterization;
   - current focused NPC runner remains callable;
   - all-runner script reports each underlying runner.
9. Introduce no new NPC movement behavior in this phase.
10. Record baseline static searches for direct NPC transform movement, `StaticBody3D` NPC creation, door toggles, scene scans, and current home semantics. These are baseline findings, not failures of Phase 00.

### Focused tests during implementation

Run:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
```

Minimum Phase 00 IDs:

- `npc_contract_clock_day_snapshot`
- `npc_contract_clock_night_snapshot`
- `npc_contract_runner_filters`
- `npc_contract_report_freshness`
- `npc_contract_report_schema`
- `npc_contract_rng_stream_isolation_baseline`
- `npc_contract_player_motor_characterization_baseline`
- `npc_contract_existing_save_defaults_baseline`

The player characterization test shall record, not casually redefine, acceleration, top speed, jump, slope, floor snap, and collision behavior used by later parity tests.

### Phase 00 gates

- Focused harness can run one suite, one case, day, night, and both.
- A deliberately injected test failure causes a nonzero runner result and cannot be masked by an old JSON file; remove the injection before completion.
- The all-runner script attempts and records every registered runner.
- Existing focused NPC navigation tests pass unchanged.
- Broad playtest, story playtest, world signature, visual captures, and visual-manifest validation pass or any pre-existing failure is proven and resolved before proceeding.
- No gameplay behavior changed.
- `PHASE_00_REPORT.md` contains full baseline evidence and the final branch/master all-runner results.

### Phase 00 report review questions

- Can every later phase iterate without running the broad playtest for each edit?
- Can a reviewer replay a single failed scenario by suite, case, time mode, and seed?
- Is stale-report success impossible?
- Is the starting behavior and debt documented accurately rather than described as already solved?
- Is the all-runner gate complete?

### Merge and continuity

After all gates pass, merge the branch into `master`, rerun `tools/run-all-test-runners.ps1`, record the merge hash and master results, then begin Phase 01 from that green `master`.

---

## Phase 01 — Typed Contracts, Composition Root, Change Bus, and Telemetry Skeleton

**Branch:** `npc-pathfinding/phase-01-contracts-observability`  
**Primary focused runner:** `tools/npc/run-npc-contract-tests.ps1`  
**Purpose:** Establish the interfaces and ownership boundaries required for a safe strangler migration without changing locomotion yet.

### Required implementation

1. Create the central enums and typed contracts listed in Sections 6 and 7 as needed for this and immediately following phases.
2. Implement `NpcAgentContext`, `NpcBlackboard`, and stable runtime IDs.
3. Implement `NpcAutonomySystem` as a composed child/service owned through `NpcSystem`; do not add a new `Main` inheritance layer.
4. Implement `NpcBrainScheduler` with bounded, deterministic, staggered high-level update slots. It may be inactive/adapter-backed until behavior migration.
5. Implement `NpcTelemetryService` with bounded ring buffers, global counters, structured events, and no normal-HUD output.
6. Implement `NavigationChangeBus` and event contract, including event coalescing and monotonic revisions. In this phase, wire at least block create/remove, chunk load/unload, and door state adapter events while leaving the legacy nav consumer intact.
7. Create central collision-layer and NPC constants definitions after auditing existing layers. Do not renumber existing layers blindly.
8. Implement route/action/interaction terminal-state helpers and cancellation generations.
9. Implement deterministic priority/tie-break helpers and independent per-NPC RNG streams. Verify no world-generation RNG is consumed.
10. Add a temporary `architecture_version`/migration switch only if required to keep each phase mergeable. It must be runtime-only, default to the currently safe path for production, produce telemetry, and be removed in Phase 13. Never run both locomotion stacks on one actor.
11. Adapt `NpcSystem.register_npc()` to create/associate a typed context while preserving current public behavior and save compatibility.
12. Document ownership and data flow in `docs/npc_pathfinding/ARCHITECTURE.md`.

### Required contract semantics

- All result objects have explicit terminal states.
- Cancellation of stale route/action generations cannot mutate current state.
- Runtime queues and traces are bounded.
- Stable ID ordering does not depend on instance IDs or dictionary iteration order.
- Guard duty is represented separately from `canFight`, even though legacy behavior will not be migrated until Phase 09.
- Change-bus events identify exact bounds/tile keys and do not require consumers to rescan the scene.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
```

Minimum new IDs:

- `npc_contract_route_status_terminal`
- `npc_contract_partial_never_arrival`
- `npc_contract_stable_tie_break`
- `npc_contract_profile_capability_filter`
- `npc_contract_rng_stream_isolation`
- `npc_contract_bounded_trace_and_cache`
- `npc_contract_cancellation_generation`
- `npc_contract_change_bus_coalesces_tiles`
- `npc_contract_change_bus_monotonic_revision`
- `npc_contract_guard_duty_not_can_fight`
- `npc_contract_autonomy_composition_no_main_layer`

### Phase 01 gates

- Existing NPC behavior remains functionally unchanged.
- Every new queue/ring/cache has a tested bound.
- Change events fire exactly once/coalesce as specified for tested mutations.
- No new scene-tree revision scan is introduced.
- Typed contracts are used across the new architecture boundary; do not create duplicate dictionary versions of the same runtime contract.
- Save snapshots remain compatible and contain no transient new state.
- Focused contract suite passes day and night.
- Every existing runner passes on branch and merged `master`.
- Phase report includes a diagram of ownership, event flow, queue bounds, and migration switch state.

### Phase 01 report review questions

- Is there one clear owner for each type of state?
- Can stale asynchronous results be rejected deterministically?
- Is the new stack composition-based?
- Are telemetry and events bounded and testable?
- Has behavior remained stable before physical migration?

---

## Phase 02 — Shared Character Motor and `CharacterBody3D` NPC Migration

**Branch:** `npc-pathfinding/phase-02-physics-motor`  
**Primary focused runner:** `tools/npc/run-npc-motor-tests.ps1`  
**Purpose:** End transform-driven NPC locomotion and establish player/NPC physical parity.

### Required implementation

1. Implement `CharacterMotorProfile`, `CharacterMotorCommand`, `CharacterMotorState`, and `CharacterMotor3D`.
2. Extract shared physical movement logic from `PlayerController.gd` without changing camera, input, survival, or visual feel responsibilities.
3. Convert `PlayerController.gd` to create commands and invoke the shared motor. Preserve current player constants/behavior through characterization tests.
4. Create `scenes/npc/NpcAgent.tscn` and `NpcAgent.gd` using `CharacterBody3D`.
5. Update `NpcVisualFactory.gd` so it can build visuals/colliders for the new agent without assuming `StaticBody3D`.
6. Update generic and tutorial NPC spawn paths to instantiate the new scene/agent. Search all NPC construction in tests/tutorial/story and migrate it.
7. Implement `NpcMotionController` as the adapter between the still-legacy route intent and the new motor. The legacy planner may supply a next steering target temporarily; it may no longer assign the body transform.
8. Refactor or replace the movement part of `NpcLocomotionController.gd` so no gameplay movement assigns `global_position`. If the legacy file remains, it must only produce route/steering intent and report deprecation.
9. Centralize and test collision layers/masks for NPC, player, world, block, door, path, prop, hostile, and interaction areas.
10. Implement `NpcSafePlacementService` for spawn/load only. It validates profile capsule, floor, headroom, and occupancy and reports failure rather than placing inside geometry.
11. Ensure active NPC physics executes every physics tick independent of staggered brain updates.
12. Make animation/visual facing consume actual motor velocity. Do not rotate to an unreachable desired direction while stationary against a wall.
13. Add telemetry counters for requested/applied velocity, blocked contact category, displacement, and safe placement.
14. Preserve existing high-level behavior and route facade during this phase through a one-way adapter. Never operate old and new motors on the same NPC.

### Motor implementation details

- The motor owns gravity, floor snap, slope classification, and collision movement.
- If the existing procedural terrain requires a custom grounding assist, it must remain collision-safe and use motion/collision APIs; it cannot move horizontally through a blocker or snap onto a surface without capsule clearance.
- Actual post-move displacement is authoritative.
- The body stops or slides naturally on collision; it does not use a transform rollback/teleport as normal collision response.
- Closed door collision remains active; open door collision state comes from the door controller/legacy adapter until Phase 06.
- NPC speed may be lower than player speed via profile, but physical rules are shared.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_motor_player_characterization_flat`
- `npc_motor_player_characterization_slope`
- `npc_motor_player_characterization_jump`
- `npc_motor_npc_flat_acceleration`
- `npc_motor_npc_slope_limit`
- `npc_motor_npc_step_up_limit`
- `npc_motor_npc_safe_drop`
- `npc_motor_wall_slide_no_penetration`
- `npc_motor_fence_window_corner_no_penetration`
- `npc_motor_closed_door_blocks`
- `npc_motor_open_door_clears`
- `npc_motor_player_npc_solid_separation`
- `npc_motor_no_route_transform_write`
- `npc_motor_no_unstick_teleport`
- `npc_motor_spawn_safe_placement`
- `npc_motor_spawn_rejects_occupied_capsule`
- `npc_motor_every_active_actor_physics_tick`

Run the obstacle cases at day and night. Time should not change physical truth.

### Static audit

Search all NPC-related production files for assignments to movement transforms. Classify every match. Allowed final Phase 02 matches are initial spawn/load/debug safe placement only. The report must include file/line evidence.

Search all NPC spawn paths for `StaticBody3D`. No NPC body may remain `StaticBody3D` after this phase. Non-NPC props/blocks may.

### Phase 02 gates

- All active NPC bodies are `CharacterBody3D`.
- Normal NPC route motion uses the shared motor and collision movement.
- No test observes penetration through wall, fence, window-equivalent, prop, closed door, player, or another NPC.
- No stuck recovery teleports.
- Player characterization remains within documented tolerances; any intentional correction is separately justified and fully tested.
- Existing NPC focused and broad behavior tests remain green through the compatibility route adapter.
- Day/night motor matrix passes.
- Full all-runner gate passes on branch and merged `master`.

### Phase 02 report review questions

- Is physics now the final authority for NPC displacement?
- Are all NPC spawn paths migrated, including tutorial and tests?
- Did player feel remain stable?
- Are collision masks centralized and explained?
- Can any normal route path still write an NPC transform?

---

## Phase 03 — Multi-Surface Navigation World and Authoritative Invalidation

**Branch:** `npc-pathfinding/phase-03-navigation-world`  
**Primary focused runner:** `tools/npc/run-npc-nav-world-tests.ps1`  
**Purpose:** Replace the one-height XZ snapshot with event-driven, profile-aware walkable surface topology.

### Required implementation

1. Implement `NavigationWorldService`, `NavigationTileBuilder`, `NavigationBuildQueue`, `NavGraphQuery`, and required tile/span/edge contracts.
2. Make `NavigationChangeBus` the only production invalidation path for the new service.
3. Wire every relevant world mutation site listed in Section 9. Audit all block removal/destruction, terrain edit, prop harvest/removal, structure creation, chunk create/unload, and door registration paths.
4. Build lazy tiles from immutable world snapshots plus border data.
5. Represent multiple vertical spans per XZ column.
6. Validate floor normal, headroom, lateral clearance, and profile feasibility conservatively.
7. Build walk/step/drop edges and explicit door/special link placeholders.
8. Prevent diagonal corner cutting when the physical profile cannot pass both adjacent blockers.
9. Extend structure records with stable building ID, interior semantic region, interior anchors, entrance/door group metadata, porch/exterior anchor, and guard-post semantics.
10. Implement `NavigationSemanticService` registration for roads, paths, interiors, homes, guard posts, work/resource approaches, settlement bounds, hazards, and staging areas available from current world generation.
11. Keep the legacy route planner temporarily behind an adapter if needed, but make new topology queryable and test-complete. Do not let the legacy planner become the source of truth for new tests.
12. Use monotonic per-tile topology revisions and global dynamic/semantic revisions. Remove the new stack's dependence on count/hash scene scans.
13. Implement stale-key detection when a tile is rebuilt/unloaded.
14. Add build prioritization and time slicing. Required tiles return `PENDING/WAITING_FOR_TOPOLOGY` until built.
15. Add debug rendering/data export for spans, edges, semantic regions, and dirty tiles behind a debug switch.

### World-data implementation rules

- Terrain and block/structure data should be read from authoritative generation/state, not inferred by traversing arbitrary visual nodes.
- Physics queries used to validate clearance run on the main/physics thread during tile build, not inside planner search.
- The graph must distinguish blocking construction from decorative/nonblocking objects.
- Open/closed door state is dynamic; the existence and geometry of the portal is topology/registration.
- An actor moving through a tile is dynamic state, not a tile rebuild.
- Unloaded tile state is explicit, never treated as open space.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both
```

Minimum IDs:

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

Run topology cases under day/night snapshots to prove clock does not corrupt physical topology; semantic light/hazard values may differ only through explicit semantic state.

### Phase 03 gates

- New navigation topology supports multiple vertical surfaces.
- Exact dirty tiles update from events; unrelated tiles retain revision/cache.
- No scene-tree scan or whole-world hash is required for normal invalidation.
- Generated homes have validated interior anchors and real entrance metadata.
- Every span/edge can be checked against a traversal profile.
- Build jobs yield under budget and resume deterministically.
- New nav-world tests pass day/night.
- Existing behavior continues through the route compatibility layer.
- World signature remains unchanged unless metadata-only changes are intentionally excluded; any generated-world change must be understood and approved.
- Full all-runner gate passes on branch and `master`.

### Phase 03 report review questions

- Can the graph represent two surfaces at one XZ?
- Are interiors and entrances real semantic entities?
- Does every world mutation have an event hook?
- Is tile rebuilding localized and bounded?
- Is unloaded/stale topology explicit?

---

## Phase 04 — Hierarchical Route Planner, Semantic Costs, and Corridor Generation

**Branch:** `npc-pathfinding/phase-04-hierarchical-routing`  
**Primary focused runner:** `tools/npc/run-npc-route-tests.ps1`  
**Purpose:** Replace the bounded flat-grid route search with deterministic hierarchical, profile-aware route planning and explicit traversal corridors.

### Required implementation

1. Implement `RouteRequestQueue`, `HierarchicalRoutePlanner`, `LocalAStarPlanner`, `RouteCostModel`, `RouteCorridorBuilder`, and `TraversalCapabilityService`.
2. Build abstract tile/cluster entrances from contiguous cross-tile transitions, semantic portals, building entrances, door portals, and special links.
3. Cache entrance-to-entrance local costs by tile revision and profile class.
4. Implement time-sliced deterministic A* at abstract and local levels.
5. Remove the old `MAX_ITERATIONS` style false-failure behavior from all routes using the new planner.
6. Implement start and goal span resolution that cannot snap through walls or between unrelated vertical levels.
7. Implement goal types for exact span, point region, semantic region, smart-object slot set, and portal side.
8. Implement centralized route costs with named configuration resources and a cost breakdown.
9. Build route corridors with mandatory actions and deterministic capsule-sweep smoothing.
10. Mark bottlenecks and reservation requirements in the corridor even though full traffic scheduling arrives later.
11. Integrate the new planner as the default route source for active NPC movement while preserving high-level legacy goals temporarily.
12. Retain `NpcPathing.gd` only as a compatibility façade delegating route requests to the new coordinator. It must not own movement or topology.
13. Make route status/reason visible on typed blackboard and legacy metadata only if existing diagnostics require an adapter.
14. Ensure the route follower/motion adapter can consume a corridor safely through the Phase 02 motor.
15. Treat doors as explicit placeholder traversal actions, with detailed execution still using the legacy door adapter until Phase 06. Closed but openable door route feasibility must already be represented correctly.
16. Add deterministic cancellation and route replacement when the high-level legacy target changes.

### Search correctness rules

- No dictionary iteration order may influence result.
- The heuristic must not overestimate the base shortest-time component.
- Semantic penalties remain nonnegative.
- A pending budget-sliced search stays pending.
- A route to an unreachable target ends `UNREACHABLE`, not an endless pending state.
- `PARTIAL` requires `allow_partial=true` and explicit closest-reachable semantics.
- A corridor cannot skip a mandatory door/action edge during smoothing.
- A route result records every tile/edge/portal dependency used.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_route_same_tile_optimal_oracle`
- `npc_route_multi_tile_hierarchy`
- `npc_route_cross_loaded_chunks`
- `npc_route_road_preferred_equal_time`
- `npc_route_hazard_avoided_by_civilian`
- `npc_route_guard_semantic_preference`
- `npc_route_profile_large_rejects_narrow_small_accepts`
- `npc_route_closed_openable_door_action`
- `npc_route_locked_unauthorized_alternate`
- `npc_route_start_snap_no_wall_cross`
- `npc_route_goal_snap_correct_vertical_layer`
- `npc_route_corner_smoothing_capsule_safe`
- `npc_route_mandatory_action_not_smoothed_out`
- `npc_route_no_iteration_cap_false_failure`
- `npc_route_pending_budget_resumes`
- `npc_route_partial_explicit_only`
- `npc_route_unreachable_terminal_reason`
- `npc_route_deterministic_replay`
- `npc_route_legacy_goal_adapter_uses_new_corridor`

For day/night variants, use identical geometry but role-specific cost profiles where appropriate. The night guard route may prefer guard-post semantics; a civilian night request must target home/interior once behavior migration occurs, but planner tests may issue direct semantic requests now.

### Phase 04 gates

- All production NPC routes use the new hierarchical planner/corridor path, even though high-level goal selection remains legacy.
- Long solvable routes no longer fail from a small iteration cap.
- Profile capability and vertical surface identity affect route feasibility.
- Route smoothing is capsule-valid and preserves actions.
- Semantic cost choices are deterministic and explainable.
- Route statuses and terminal reasons satisfy the contract.
- Existing focused NPC scenarios and broad playtest remain green.
- Full all-runner gate passes on branch and `master`.

### Phase 04 report review questions

- Is the global/local hierarchy real, with cached entrances, or merely renamed A*?
- Are searches resumable under frame budgets?
- Is route choice explainable through cost breakdown?
- Can snapping/smoothing cross geometry incorrectly?
- Does every active NPC movement route now originate from the new planner?


---

## Phase 05 — Incremental Route Repair and Dynamic World Response

**Branch:** `npc-pathfinding/phase-05-incremental-repair`  
**Primary focused runner:** `tools/npc/run-npc-repair-tests.ps1`  
**Purpose:** Make active routes react efficiently and correctly to voxel/world changes without full blind replanning or infinite retry loops.

### Required implementation

1. Implement `IncrementalRouteRepair.gd` using D* Lite/LPA* semantics from Section 11.
2. Add route dependency indexing from tile/edge/portal/object IDs to active routes.
3. Subscribe the navigation coordinator to change-bus events and classify each event as:
   - irrelevant to corridor;
   - cost-only dynamic update;
   - local edge update repairable in place;
   - abstract graph/portal update requiring segment repair;
   - target/action premise invalidation requiring task-plan revision;
   - streamed topology unavailable requiring pending/abstract handling.
4. Maintain `g`, `rhs`, priority queue, moving-start adjustment, and changed-vertex updates under the route budget.
5. Build a fresh A* oracle used only in tests to compare route existence and final cost after repairs.
6. Repair only affected route segments and preserve valid completed/current segments where safe.
7. If the NPC has already passed a changed segment, do not replan unless the change affects current/future safety.
8. Implement bounded repeated-failure tracking by reason/object/revision.
9. Implement recovery escalation from local repair to global alternate to action-plan revision to terminal failure.
10. Integrate dynamic player block placement/removal, terrain edits, prop harvest/removal, door access changes, and chunk load/unload.
11. Cancel/rebind a smart-object/resource action when its target is removed or becomes unavailable.
12. Ensure all stale repair results are rejected by route generation/cancellation token.
13. Instrument repair time, changed vertices, reused search state, and full replan count.
14. Remove any remaining behavior that force-replans every fixed interval without a reason.

### Specific dynamic scenarios

- Player places a wall on the next route segment: NPC stops before collision, route invalidates, local repair selects another valid path or returns unreachable.
- Player removes the wall: a future route can shorten; an active route may repair when policy says the gain is meaningful, without thrashing.
- Resource disappears before arrival: navigation action fails `TARGET_GONE`; task planner/legacy adapter selects a new resource or terminal result.
- Door locks: route repairs to another entrance if one exists; no collision bump loop.
- Door unlocks: edge becomes feasible; waiting actor may resume/replan.
- Chunk unload intersects future corridor: active physical actor does not enter missing topology. It waits, requests load, switches to abstract simulation, or chooses another route according to LOD policy.
- Unrelated block changes elsewhere: active route generation remains unchanged.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_repair_unrelated_change_no_replan`
- `npc_repair_block_added_on_corridor`
- `npc_repair_block_removed_shortens_route`
- `npc_repair_terrain_edit_on_corridor`
- `npc_repair_door_locked_alternate`
- `npc_repair_door_unlocked_resumes`
- `npc_repair_resource_removed_replan_action`
- `npc_repair_chunk_unload_suspends_or_alternates`
- `npc_repair_stale_generation_rejected`
- `npc_repair_matches_fresh_astar_cost`
- `npc_repair_reuses_search_state`
- `npc_repair_bounded_no_loop`
- `npc_repair_physical_stop_before_new_blocker`
- `npc_repair_day_worker_dynamic_block`
- `npc_repair_night_guard_dynamic_block`
- `npc_repair_night_civilian_home_dynamic_block`

### Phase 05 gates

- An unrelated world change does not rebuild or replan unaffected routes.
- A relevant change stops unsafe movement before contact/penetration and produces bounded repair.
- Repaired route cost/existence matches fresh A* within deterministic tolerance.
- Repair demonstrably reuses state in at least the required tests.
- Repeated impossible repairs terminate with a reason; no infinite loop.
- Resource/door premise changes reach the action-planning boundary correctly.
- Day/night dynamic cases pass.
- All prior focused suites and every repository runner pass on branch and merged `master`.

### Phase 05 report review questions

- Is this actual incremental search state reuse?
- Are changes dependency-scoped?
- Does physical movement stop safely while repair is pending?
- Are action premise failures distinguished from route failures?
- Are repair loops bounded and visible in telemetry?

---

## Phase 06 — Authoritative Smart Doors and Shared Player/NPC Interaction

**Branch:** `npc-pathfinding/phase-06-smart-doors`  
**Primary focused runner:** `tools/npc/run-npc-door-tests.ps1`  
**Purpose:** Replace blind toggles and delayed timers with safe logical door portals, interaction actions, and shared world authority.

### Required implementation

1. Implement `SmartObjectService`, core interaction contracts, `DoorController`, `DoorPortal`, `DoorPortalService`, `DoorAccessPolicy`, and `DoorTraversalExecutor`.
2. Modify door creation/structure generation to assign stable portal/group IDs, side orientation, leaf index, building/interior association, and access metadata.
3. Group double leaves into one logical portal with coordinated state and clearance.
4. Add approach, interaction, staging, threshold, exit, sweep, and clearance geometry to each portal. These may be data/areas/debug shapes, but occupancy checks must be authoritative.
5. Implement the required state machine and idempotent requests.
6. Move all door animation and collider control into `DoorController`.
7. Define the exact opening point at which the portal becomes physically traversable from actual clearance, not only elapsed time.
8. Implement close safety and obstruction reversal. Remove any timeout override of player/NPC occupancy.
9. Integrate door state/access revisions into navigation edge feasibility/cost and route repair.
10. Implement complete door traversal actions in corridors and the plan executor adapter:
    - reserve approach;
    - approach/facing;
    - open request;
    - wait for traversable;
    - threshold reservation;
    - physical cross;
    - full capsule clear;
    - release/hold transfer;
    - close according to policy.
11. Route player interaction through `SmartObjectService`. Keep player UX intact.
12. Convert `MainRuntimeTools.toggle_door()` into a temporary compatibility adapter that resolves the controller and requests the desired state. Mark deprecated. No NPC code may call it.
13. Replace `NpcSystem.open_door_for_npc()`, pending door-close arrays, and direct timer ownership with the door traversal/controller system.
14. Define private/public/night/automatic hold-open policies and queue inheritance window in named configuration.
15. Implement access, locked, jammed, destroyed, and missing/unloaded outcomes even if some are currently reachable only in tests/debug. These are part of the complete controller contract.
16. Migrate existing doors/saves deterministically. Durable open/lock/destroyed semantics must restore correctly; transient holds/queues do not persist.
17. Add door-specific debug overlay and traces.

### Door close policy minimums

- A private home exterior door normally closes after all traffic clears.
- A public daytime entrance may stay open according to policy.
- A queued follower approaching within the inheritance window receives the current opening.
- At night, exterior home doors close after residents/traffic are clear.
- A guard leaving for duty may close the door behind itself if no resident/follower is entering.
- An NPC carrying a bulky object can request an extended hold.
- A threat/emergency policy can hold gates open or close them, but it remains explicit.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_door_idempotent_open`
- `npc_door_idempotent_close`
- `npc_door_single_open_cross_close`
- `npc_door_double_coordinated_portal`
- `npc_door_player_npc_shared_authority`
- `npc_door_threshold_occupied_no_close`
- `npc_door_sweep_occupied_no_close`
- `npc_door_clearance_volume_occupied_no_close`
- `npc_door_obstructed_closing_reopens`
- `npc_door_queue_inherits_opening`
- `npc_door_opposing_direction_ordered`
- `npc_door_locked_authorized`
- `npc_door_locked_unauthorized_alternate`
- `npc_door_jammed_failure_or_alternate`
- `npc_door_destroyed_topology_update`
- `npc_door_no_timeout_safety_override`
- `npc_door_cancelled_actor_releases_hold`
- `npc_door_night_civilian_enters_home`
- `npc_door_night_guard_exits_for_duty`
- `npc_door_night_player_blocks_threshold_no_close`
- `npc_door_day_worker_exit_and_return`

Run at least one two-actor and one player/NPC shared-door case with real physics and real generated door geometry.

### Static audit

- Search NPC production code for `toggle_door`; expected zero calls.
- Search for legacy pending door-close arrays/timers; expected removed or inert compatibility code with no production ownership.
- Search for `timed_out` or equivalent allowing unsafe close; expected zero.
- Verify door collider changes occur only inside the controller.

### Phase 06 gates

- Every generated/player-placed door has a logical portal/controller.
- Player and NPCs use the same authoritative door actions/state.
- Single/double doors open, coordinate, cross, and close safely.
- Occupancy and active reservation always defeat close, regardless of elapsed time.
- Door failures alter action/route feasibility correctly.
- Night inbound/outbound door scenarios pass.
- Legacy door smoke tests remain green through the new controller.
- All focused suites and full repository gate pass on branch and `master`.

### Phase 06 report review questions

- Is there exactly one logical authority per doorway?
- Can a repeated request accidentally invert state?
- Can any timer close on the player/NPC?
- Are approach/threshold/sweep volumes real and tested?
- Do routes and actions observe access/state changes immediately?

---

## Phase 07 — Predictive Local Avoidance and Stable Corridor Following

**Branch:** `npc-pathfinding/phase-07-local-avoidance`  
**Primary focused runner:** `tools/npc/run-npc-avoidance-tests.ps1`  
**Purpose:** Replace hard-coded sidestep directions with predictive reciprocal avoidance while preserving corridor, door, and physical authority.

### Required implementation

1. Implement `NpcCorridorFollower` completely and remove remaining steering responsibility from the legacy locomotion controller.
2. Implement `ReciprocalAvoidanceAdapter` using Godot avoidance for active actors.
3. Configure grounded avoidance dimensions, layers, masks, priority, neighbor distance, neighbor count, time horizons, and speed from named profile/configuration values.
4. Ensure an avoidance target is supplied and `safe_velocity` is consumed correctly every physics tick.
5. Use desired route velocity as input; use returned safe velocity as a candidate; clamp/project it to corridor/portal constraints; send it to the shared motor.
6. Disable avoidance for distant/abstract actors and actors not near another relevant moving obstacle. Measure active registration count.
7. Implement portal mode:
   - reservation/door executor controls right of way;
   - lateral RVO is reduced or disabled inside the threshold;
   - no side-stepping into frames/walls;
   - physical motor remains authoritative.
8. Implement speed-aware look-ahead, corner slowing, interaction stopping, and arrival without orbiting.
9. Replace fixed local-avoidance vector lists and fixed backoff attempts as the primary open-space avoidance. A deterministic physical retreat plan for traffic deadlock remains allowed later.
10. Implement no-progress classification using corridor distance and motor contacts.
11. Distinguish static collision, dynamic actor, traffic reservation, door state, stale corridor, and invalid goal.
12. Add oscillation metrics: lateral sign changes, heading reversals, and progress.
13. Add safe fallback when avoidance callback is absent/stale: stop or use physically validated direct corridor velocity; never reuse stale unsafe velocity.
14. Preserve deterministic behavior as far as Godot's fixed-step avoidance permits; report tolerances for floating-point motion, and assert invariant outcomes rather than identical bitwise positions where inappropriate.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_avoidance_head_on_open_road`
- `npc_avoidance_crossing_paths`
- `npc_avoidance_overtake_slow_actor`
- `npc_avoidance_crowded_plaza_progress`
- `npc_avoidance_corridor_boundary_respected`
- `npc_avoidance_no_left_right_oscillation`
- `npc_avoidance_wall_not_treated_as_rvo_only`
- `npc_avoidance_closed_door_not_bypassed`
- `npc_avoidance_portal_mode_no_frame_sidestep`
- `npc_avoidance_inactive_agents_disabled`
- `npc_avoidance_stale_callback_safe_stop`
- `npc_follow_arrival_no_orbit`
- `npc_follow_progress_watchdog_classifies_blocker`
- `npc_follow_day_crowd_progress`
- `npc_follow_night_guard_passes_returning_civilian`

Use real body collision in all physical cases. Assert no penetration throughout sampled trajectories, not only at the end.

### Phase 07 gates

- Fixed sidestep lists are no longer primary avoidance.
- Open-space actors pass/cross without bump loops and make bounded progress.
- Avoidance never steers outside capsule-safe corridor or through static geometry.
- Door/portal reservations remain authoritative.
- Arrival does not orbit or oscillate.
- Avoidance cost is measured and inactive agents are deregistered/disabled.
- Day/night crowd cases pass.
- Full all-runner gate passes on branch and `master`.

### Phase 07 report review questions

- Is RVO used only for local moving-agent avoidance?
- Can RVO defeat a route, wall, or door constraint?
- Are inactive agents truly disabled?
- Is oscillation measured and bounded?
- Does actual motor progress drive route advancement?

---

## Phase 08 — Space-Time Traffic, Door Queues, Fairness, and Deadlock Recovery

**Branch:** `npc-pathfinding/phase-08-traffic-deadlock`  
**Primary focused runner:** `tools/npc/run-npc-traffic-tests.ps1`  
**Purpose:** Guarantee liveness and collision-free ordering at narrow resources where local avoidance alone cannot solve contention.

### Required implementation

1. Implement `BottleneckClassifier`, `TrafficReservationService`, `SafeIntervalPlanner`, `WaitForGraph`, and `TrafficPriorityPolicy`.
2. Classify narrow door thresholds, bridges, stairs, corridors, and interaction approaches from clearance/capacity metadata.
3. Reserve time intervals for spans, directed edges, portals, and smart-object slots over a rolling horizon.
4. Prevent opposite edge traversal and adjacent position swaps.
5. Integrate route corridor ETA with reservation requests. Recompute/extend safely when an actor is delayed.
6. Implement staging/pull-out selection on reachable, nonblocking spans. Register explicit staging positions around generated doors and semantic bottlenecks where possible.
7. Implement deterministic directional batching for one-capacity resources.
8. Implement priority classes, wait aging, active-crossing continuity, and stable-ID tie-breaks.
9. Implement priority inheritance through wait-for chains.
10. Detect wait-for cycles and execute physical retreat/pull-out or direction batching as specified.
11. Release reservations on completion, cancellation, route replacement, actor removal, demotion, death, or object destruction.
12. Prevent reservation leaks with bounded owner-generation tracking and diagnostics.
13. Integrate door opening inheritance with the traffic queue.
14. Make the corridor follower stop at a valid staging point while waiting, not in the threshold or another actor's escape path.
15. Add fairness and liveness counters: maximum wait, queue length, starvation prevention, cycles detected/resolved, unresolved reasons.
16. Add a stress test that repeatedly swaps many actors through one/two bottlenecks at day and night.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-traffic-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_traffic_two_actor_one_door_swap`
- `npc_traffic_node_and_edge_conflict`
- `npc_traffic_no_adjacent_edge_swap`
- `npc_traffic_bridge_direction_batch`
- `npc_traffic_stair_single_capacity`
- `npc_traffic_interaction_slot_capacity`
- `npc_traffic_four_actor_cycle_resolved`
- `npc_traffic_priority_emergency_over_wander`
- `npc_traffic_priority_night_home_over_idle`
- `npc_traffic_active_crossing_not_preempted`
- `npc_traffic_wait_age_prevents_starvation`
- `npc_traffic_priority_inheritance_chain`
- `npc_traffic_pullout_retreat_physical`
- `npc_traffic_cancel_releases_reservation`
- `npc_traffic_destroyed_portal_releases_reservation`
- `npc_traffic_no_permanent_deadlock_soak`
- `npc_traffic_day_work_wave`
- `npc_traffic_dusk_return_home_wave`
- `npc_traffic_night_guard_outbound_civilians_inbound`

### Liveness acceptance

For deterministic test scenarios with physically reachable goals and no permanent external obstruction:

- every actor reaches its terminal goal within the scenario bound;
- no two actors share a reserved narrow footprint interval;
- no actor starves;
- all wait-for cycles resolve;
- reservation count returns to zero after completion;
- door closes only after the final safe crossing.

### Phase 08 gates

- Traffic is time-aware, not frame-TTL cell ownership.
- Node and directed-edge conflicts are both enforced.
- Deadlock cycles are detected and resolved deterministically.
- Priority and wait aging prevent starvation.
- Retreat/yield movement uses real routes and physics, not transform displacement.
- Door queues and traffic share one authority.
- Day/dusk/night traffic waves pass.
- All focused and repository runners pass on branch and `master`.

### Phase 08 report review questions

- Can two actors swap through each other?
- What proves starvation cannot persist in tested conditions?
- Are reservation lifetimes tied to action/route generations?
- Can a cancelled/deleted actor leak a resource?
- Is deadlock recovery physical and deterministic?

---

## Phase 09 — Utility Goals, Symbolic Task Planning, and Complete Day/Night Schedules

**Branch:** `npc-pathfinding/phase-09-purpose-schedules`  
**Primary focused runner:** `tools/npc/run-npc-behavior-tests.ps1`  
**Purpose:** Replace destination/phase scripts with purpose-driven goals and action plans, including strict night guard/interior behavior.

### Required implementation

1. Implement `NpcGoalSelector`, `NpcTaskPlanner`, `NpcPlanExecutor`, `NpcRecoveryPolicy`, `NpcScheduleService`, `GuardRosterService`, `NpcPerceptionService`, and the initial `NpcActionLibrary`.
2. Define typed role/schedule resources for current NPC roles: guard, farmer, carpenter/wood worker, forager, mason/stone worker, trader, civilian/tutorial roles.
3. Separate combat capability from guard duty. Migrate current `nightGuard` data into explicit duty assignments only for actual guards.
4. Implement schedule snapshots using existing clock constants and deterministic test injection.
5. Implement dusk early-return behavior, full-night compliance, dawn/day release, and explicit emergency/script overrides.
6. Implement utility scoring with logged breakdown and hysteresis.
7. Implement bounded symbolic planning with explicit preconditions/effects/costs for the action sequences required in Section 15.
8. Integrate route, door, traffic, smart object, and motor results into reactive action execution.
9. Replace `NpcSystem.update_npc()` destination selection, job phase movement, random wander, and home-return timer behavior with the new executor for migrated NPCs.
10. Move `NpcSystem` toward registry/spawn/integration only. It may adapt statistics/public methods, but it no longer owns the decision loop.
11. Migrate scripted target movement into an explicit high-priority order goal/action, preserving tutorial/story holds and cancellation.
12. Make every generic town NPC own a valid home interior and schedule.
13. Define home-arrival success strictly from interior semantic containment.
14. Define emergency shelter behavior if home is inaccessible. In normal generated worlds this should not be needed; when dynamically blocked, report explicit state and never teleport.
15. Implement guard duty behavior:
    - report to reachable guard post before/at night;
    - patrol deterministic semantic segments;
    - choose reachable intercept positions, not hostile centers;
    - return to duty or schedule after a threat;
    - off-duty guards go indoors.
16. Implement ordinary idle relocation only among semantic anchors with route scoring.
17. Remove random raw world target selection for production NPCs.
18. Release action-owned reservations/door holds on interruption.
19. Add schedule-compliance counters and debug overlay.
20. Keep current job effects compatible until richer environment actions in Phase 10, but all movement and high-level sequence ownership must now be in the new planner/executor.

### Required goal/action examples

**Day worker:** `PERFORM_JOB -> choose known reachable target -> navigate -> interact/work -> deliver/deposit or return -> idle/repeat`.

**Night civilian:** `RETURN_HOME -> navigate exterior approach -> open/cross door -> close/release -> navigate interior anchor -> REMAIN_INSIDE`.

**Night duty guard:** `REPORT_TO_DUTY -> navigate/cross doors outbound -> reach guard post -> PATROL/GUARD -> intercept threat if needed -> resume duty`.

**Off-duty guard/fighter:** same night return-home plan as civilian unless an explicit emergency is active.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition
```

Minimum IDs:

- `npc_behavior_day_worker_reachable_job`
- `npc_behavior_day_forager_goal_plan_shape`
- `npc_behavior_day_guard_patrol`
- `npc_behavior_day_idle_semantic_anchor`
- `npc_behavior_dusk_civilian_returns_before_night`
- `npc_behavior_dusk_guard_reports_to_duty`
- `npc_behavior_night_assigned_guard_outside`
- `npc_behavior_night_off_duty_guard_inside`
- `npc_behavior_night_fighter_non_guard_inside`
- `npc_behavior_night_worker_inside`
- `npc_behavior_night_forager_inside`
- `npc_behavior_night_trader_inside`
- `npc_behavior_night_porch_not_inside`
- `npc_behavior_night_threshold_not_inside`
- `npc_behavior_night_blocked_home_explicit_failure_no_teleport`
- `npc_behavior_threat_exception_explicit`
- `npc_behavior_post_threat_schedule_restored`
- `npc_behavior_goal_hysteresis_no_thrashing`
- `npc_behavior_action_interrupt_releases_resources`
- `npc_behavior_scripted_order_priority_and_cancel`
- `npc_behavior_unreachable_goal_terminal`
- `npc_behavior_all_generated_town_npcs_have_interior_home`
- `npc_behavior_no_raw_random_world_goal`

### Day/night observation requirement

Run:

```powershell
.\tools\npc\run-npc-observation-tests.ps1 -Scenario DuskReturnHome -TimeMode Transition
.\tools\npc\run-npc-observation-tests.ps1 -Scenario MidnightTown -TimeMode Night
```

The report must include:

- number of NPCs by role;
- duty assignments;
- number indoors/outdoors/threshold/porch;
- every exception and reason;
- door crossings and final door states;
- captures/traces at dusk, full night, and settled midnight.

Under the normal generated test town after the allowed transition grace:

- all assigned guards are at valid outside duty states;
- every other NPC is inside;
- zero NPCs are counted as inside only because they are on the porch/threshold;
- no ordinary day job remains active.

### Phase 09 gates

- The new goal/task/executor stack owns all generic and tutorial NPC high-level movement decisions.
- `canFight` no longer implies night duty.
- Night role matrix passes exactly.
- Dusk return-home is a real plan through a real door into a real interior.
- Ordinary wandering uses semantic anchors only.
- Unreachable/blocked goals terminate or choose explicit alternatives without teleporting.
- Observation artifacts prove day/night behavior.
- Existing story/tutorial behavior remains green.
- All focused suites and full repository gate pass on branch and `master`.

### Phase 09 report review questions

- Is the NPC choosing goals for a reason that can be inspected?
- Are door/resource interactions explicit actions with preconditions/effects?
- Are all non-duty NPCs truly indoors at night?
- Are assigned guards truly on duty outside?
- Does interruption clean up owned state?
- Has the old update-phase decision loop ceased to be authoritative?


---

## Phase 10 — Complete Environment Interaction, Jobs, Guards, and World-Aware Purpose

**Branch:** `npc-pathfinding/phase-10-world-interaction`  
**Primary focused runner:** `tools/npc/run-npc-interaction-tests.ps1`  
**Purpose:** Finish the meaningful gameplay loops so intelligent traversal leads to real, shared environment actions rather than simulated timers.

### Required implementation

1. Expand `SmartObjectService` and `NpcActionLibrary` for current gameplay objects and resources:
   - berry/forage sources;
   - trees/log sources;
   - rocks/ore sources;
   - storage/deposit points;
   - workbench/anvil/furnace where role loops need them;
   - trader stall/public interaction slot;
   - bed/rest/interior idle slot;
   - guard posts/patrol checkpoints;
   - any tutorial repair/rescue interaction currently reached through scripted movement.
2. Give each object stable action slots, occupancy/capacity, access, approach poses, preconditions, duration, effects, and failure reasons.
3. Route player and NPC actions through the same authoritative availability/effect layer where equivalent interactions exist. Preserve player UX and inventory rules.
4. Replace timer-only work completion with real object action results. An NPC must be at the valid approach slot, own the reservation, satisfy tool/inventory/capability requirements, and complete the action before effects occur.
5. Ensure an NPC cannot harvest, deposit, use, repair, or open an object through a wall, floor, closed door, or from outside action reach.
6. Implement per-role loops:
   - forager: select known reachable berry source, reserve, travel, harvest, carry, eat/deposit as needs dictate;
   - wood worker/carpenter: select reachable tree/log source, reserve, gather, deliver/use;
   - stone worker/mason: select reachable rock/ore source, reserve, gather, deliver/use;
   - trader: occupy/use stall during day, return home at dusk;
   - guard: duty post/patrol and reachable threat intercept;
   - civilian: semantic errands/idle/social anchors without arbitrary wandering.
7. Integrate personal inventory, hunger, equipment, and job resource facts with symbolic planning.
8. Implement target scoring using legitimate NPC knowledge/perception plus route cost, danger, congestion, resource availability, and role preference.
9. Make resource/object destruction or depletion invalidate reservations and action plans safely.
10. Make guards choose reachable intercept/cover/standoff positions based on weapon/melee capability, not hostile body centers or wall-occluded points.
11. Ensure fighters/guards still obey physical collision and door/traffic systems during combat response.
12. Migrate tutorial/story NPC environment interactions to the new action interfaces without putting story authority into navigation code.
13. Keep save changes additive for durable inventory/job/assignment facts.
14. Add telemetry for selected candidates, rejection reasons, interaction ownership, and completed effects.

### Shared-authority rules

- The player and NPC cannot both harvest a single-capacity resource simultaneously.
- If the player harvests a resource first, the NPC receives `TARGET_GONE`/`RESOURCE_DEPLETED` and replans.
- If an NPC owns a short active interaction, player feedback must reflect busy/unavailable according to game design; do not duplicate rewards.
- Interaction effects are idempotent by request/action ID where repeated callbacks are possible.
- Reserving an object does not grant the effect; physical approach and action completion are required.
- A route to an object ends at a registered approach slot, not at the object's collider center.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_interaction_resource_reserved_single_user`
- `npc_interaction_resource_removed_during_approach`
- `npc_interaction_player_harvests_before_npc_replans`
- `npc_interaction_workstation_capacity`
- `npc_interaction_deposit_through_real_door`
- `npc_interaction_no_harvest_through_wall`
- `npc_interaction_no_use_from_wrong_vertical_layer`
- `npc_interaction_player_npc_same_availability`
- `npc_interaction_access_policy_shared`
- `npc_interaction_idempotent_effect`
- `npc_interaction_forager_harvest_carry_eat`
- `npc_interaction_wood_worker_gather_deliver`
- `npc_interaction_stone_worker_gather_deliver`
- `npc_interaction_trader_day_stall_night_home`
- `npc_interaction_guard_reachable_ranged_intercept`
- `npc_interaction_guard_reachable_melee_intercept`
- `npc_interaction_guard_no_attack_through_wall`
- `npc_interaction_tutorial_scripted_action_migrated`
- `npc_interaction_cancel_releases_slot`
- `npc_interaction_day_night_object_policy`

### Real-world integration scenarios

Use at least one generated town and real generated resource field. Validate:

- workers leave homes in daytime through real doors;
- use roads/valid terrain when cost-effective;
- reach actual resource approach slots;
- perform real effects once;
- return/deliver through doors;
- transition home at dusk;
- assigned guards remain on duty at night;
- no actor clips structures or another actor during the loop.

### Phase 10 gates

- Current NPC job loops are real action plans over shared environment authority.
- No effect occurs from an invalid approach or through geometry.
- Object capacity/reservations prevent duplicate simultaneous use.
- Resource depletion/removal triggers bounded replanning.
- Guard intercepts are reachable and collision-aware.
- Day/night role loops remain correct.
- Tutorial/story integration remains green.
- Full focused and repository gates pass on branch and `master`.

### Phase 10 report review questions

- Does movement now lead to meaningful real actions rather than timer simulations?
- Do player and NPC interactions share world truth?
- Can an NPC interact through a wall or from the wrong floor?
- Are resource races and cancellation idempotent?
- Are job loops visibly purposeful and schedule-compliant?

---

## Phase 11 — Streaming, Abstract Simulation, Save Migration, and Lifecycle Safety

**Branch:** `npc-pathfinding/phase-11-streaming-save`  
**Primary focused runner:** `tools/npc/run-npc-streaming-save-tests.ps1`  
**Purpose:** Make the architecture safe across chunk streaming, distance-based simulation, save/load, actor removal, and long journeys.

### Required implementation

1. Implement `NpcSimulationLodService` and `AbstractNpcTransit`.
2. Define deterministic active/nearby/abstract thresholds and hysteresis so actors do not rapidly promote/demote near a boundary.
3. Keep full physical simulation for active actors and reduced brain cadence for nearby actors; use semantic region/portal transit for distant actors.
4. Do not abstract an actor while it is:
   - in a door threshold/sweep volume;
   - holding an active bottleneck reservation that cannot be represented abstractly;
   - in immediate combat;
   - physically blocked/penetrating;
   - executing a noninterruptible interaction;
   - observed in a required visible scripted sequence.
5. Implement safe demotion cleanup for RVO registration, local route state, reservations, door holds, and body lifecycle.
6. Implement safe promotion as specified in Section 17 using loaded topology and `NpcSafePlacementService`.
7. Represent abstract travel only across known semantic regions/portals with expected duration and access. Do not move abstract NPCs through locked/infeasible doors or unloaded unknown topology without a valid abstract edge.
8. Request/prefetch needed chunks/topology when an active route approaches streaming bounds.
9. Define behavior when a required tile unloads: hold active movement, request load, demote to valid abstract transit, or replan. Never continue physical movement into missing geometry.
10. Implement additive save schema migration for durable NPC state, duty, home/interior assignment, job, needs, inventory/equipment, and abstract transit.
11. Explicitly omit transient route, planner, avoidance, reservation, queue, and trace state from saves.
12. On load, reconstruct plans/routes from durable goals and schedule; validate doors and placement.
13. Test actor deletion/death/despawn cleanup so no reservation, door hold, smart-object slot, route request, avoidance RID, or context remains.
14. Preserve deterministic world generation and current save compatibility. Do not reorder structure/town/prop RNG.
15. Add lifecycle telemetry and leak counters.

### Save version behavior

- Old snapshots missing new fields load with deterministic defaults derived from existing role/home/job data.
- A legacy fighter is not automatically assigned night guard duty unless its role/legacy duty field clearly indicates guard assignment.
- Existing home records gain deterministic interior/portal associations from regenerated stable structure metadata.
- On load at night, non-duty NPCs reconstruct return-home/remain-inside intent; duty guards reconstruct duty intent.
- If an old saved position is invalid, safe placement selects the nearest semantically consistent valid span and logs migration; it does not silently place through a wall.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_stream_active_to_abstract_safe`
- `npc_stream_abstract_to_active_safe_span`
- `npc_stream_no_promote_in_door_threshold`
- `npc_stream_no_demote_during_crossing`
- `npc_stream_route_across_chunk_boundary`
- `npc_stream_prefetch_before_boundary`
- `npc_stream_unloaded_goal_pending_not_teleport`
- `npc_stream_abstract_respects_locked_portal`
- `npc_stream_lod_hysteresis_no_thrashing`
- `npc_stream_actor_removal_releases_all_ownership`
- `npc_save_old_snapshot_defaults`
- `npc_save_round_trip_durable_state`
- `npc_save_no_transient_route_or_reservation`
- `npc_save_invalid_position_safe_migration`
- `npc_save_night_schedule_reconstructs`
- `npc_save_guard_duty_reconstructs`
- `npc_save_door_durable_state_reconstructs`
- `npc_save_deterministic_round_trip`
- `npc_save_world_signature_unchanged`

### Phase 11 gates

- Promotion/demotion never causes penetration, door-threshold spawning, duplicate bodies, or leaked ownership.
- Distant travel is semantically feasible and does not pretend unloaded geometry is empty.
- Old saves load; new saves round-trip; transient navigation state is absent.
- Night/day schedule reconstructs correctly from durable state.
- Actor removal leaves zero reservations/holds/requests/avoidance registrations.
- World signature remains stable or any intentional metadata-only baseline change is documented and approved.
- All focused and repository gates pass on branch and `master`.

### Phase 11 report review questions

- Can an NPC disappear/reappear through a wall or door?
- What exact state is abstract versus physical?
- Are transient systems fully reconstructed rather than serialized?
- Are old saves deterministic and schedule-correct?
- Does every lifecycle path release ownership?

---

## Phase 12 — Fuzzing, Soak, Performance, Failure Recovery, and Observation Hardening

**Branch:** `npc-pathfinding/phase-12-hardening-soak`  
**Primary focused runner:** `tools/npc/run-npc-soak-tests.ps1`  
**Purpose:** Find emergent failures that narrow deterministic cases miss, prove bounded performance/liveness, and tune without weakening correctness.

### Required implementation

1. Complete all telemetry/performance instrumentation from Section 18.
2. Implement deterministic scenario generators for:
   - obstacle fields;
   - multi-surface layouts;
   - door networks;
   - resource placements;
   - actor start/goal sets;
   - timed block/door/resource changes;
   - day/night/transition schedules.
3. Implement property/fuzz tests with recorded seeds and automatic minimal replay data.
4. Compare incremental repair against a fresh A* oracle over many randomized updates.
5. Run no-penetration sweeps over randomized physical scenarios.
6. Run terminal-outcome tests over reachable and unreachable goals.
7. Run 32-active-NPC day, night, dusk, and door-traffic soaks over at least ten deterministic seeds each.
8. Run a 64-active-NPC stress profile and report performance/liveness separately from shipping acceptance.
9. Exercise repeated actor spawn/remove, chunk load/unload, save/load, door destroy/rebuild, resource depletion, and player block edits.
10. Tune route/build/brain budgets, avoidance activation, cache sizes, and traffic horizon using measured data. Keep all values named/configured.
11. Investigate every watchdog, deadlock, penetration, unbounded queue, route loop, door safety event, or schedule violation. Do not suppress or raise timeouts without root cause.
12. Add targeted regression tests for every failure found.
13. Run observation captures for noon, dusk, midnight, dawn, crowded doors, and dynamic repair.
14. Audit debug output and ensure normal gameplay HUD/logs remain clean.
15. Audit memory bounds after long runs.
16. Produce performance tables by suite/scenario/seed and identify worst cases.

### Focused tests during implementation

```powershell
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Transition
.\tools\npc\run-npc-observation-tests.ps1 -TimeMode Both
```

Minimum IDs:

- `npc_soak_32_agents_day_10_seeds`
- `npc_soak_32_agents_night_10_seeds`
- `npc_soak_32_agents_dusk_transition_10_seeds`
- `npc_soak_64_agents_stress`
- `npc_soak_dynamic_blocks_day_night`
- `npc_soak_door_traffic_day_night`
- `npc_soak_streaming_promote_demote`
- `npc_soak_save_load_cycles`
- `npc_soak_spawn_remove_ownership_cleanup`
- `npc_fuzz_route_repair_matches_oracle`
- `npc_fuzz_no_penetration_random_obstacles`
- `npc_fuzz_terminal_outcomes_random_goals`
- `npc_fuzz_door_state_machine_safety`
- `npc_fuzz_traffic_no_conflicting_intervals`
- `npc_fuzz_schedule_compliance`
- `npc_observe_noon_work`
- `npc_observe_dusk_return_home`
- `npc_observe_midnight_guard_and_interiors`
- `npc_observe_dawn_transition`
- `npc_observe_player_npc_shared_door`
- `npc_observe_dynamic_block_repair`

### Hard failure conditions

Any occurrence is a phase failure:

- geometry penetration;
- door closes on occupied threshold/sweep/clearance volume;
- actor teleports as recovery;
- active NPC remains without terminal/progress/recovery state beyond the test bound;
- unresolved wait-for cycle;
- reservation/door hold leak after scenario cleanup;
- non-duty NPC outside at settled normal midnight;
- duty guard incorrectly indoors/idle under normal duty conditions;
- route repair diverges from oracle feasibility/cost beyond documented tie-equivalent tolerance;
- unbounded memory/queue growth;
- planner/build hard slice over configured maximum without yielding;
- world-generation signature drift without understood intentional cause;
- stale report or watchdog false success.

### Performance acceptance

Record reference hardware and engine build. Minimum acceptance:

- 32-agent scenarios satisfy Section 18 target budgets or a separately approved measured revision;
- route/build jobs yield within hard slices;
- no sustained queue growth after scenario settles;
- avoidance registration falls when crowds disperse/actors abstract;
- cache memory stabilizes under configured bounds;
- 64-agent stress completes without crash, deadlock, leak, or correctness violation;
- all worst-case seeds are preserved as named regressions.

### Phase 12 gates

- Every discovered defect has a targeted regression.
- Day/night/transition soaks have zero correctness failures over required seeds.
- Performance/bounds meet accepted targets.
- Observation artifacts are reviewed and described, not merely generated.
- No normal HUD/debug pollution.
- Full all-runner gate passes on branch and `master`.

### Phase 12 report review questions

- What were the worst seeds and why?
- Were any timeouts raised, and what root cause justified it?
- Is performance measured per subsystem?
- Are queues/caches stable over time?
- Do visual observations agree with headless assertions?
- What new regressions were added from soak findings?

---

## Phase 13 — Legacy Removal, Final Static Audit, Release Gate, and Acceptance Report

**Branch:** `npc-pathfinding/phase-13-finalize`  
**Primary focused runner:** all NPC runners plus `tools/run-all-test-runners.ps1`  
**Purpose:** Remove migration debt, prove there is one authoritative stack, and produce final review evidence.

### Required implementation

1. Remove the runtime architecture feature flag and all dual-stack compatibility selection.
2. Remove or radically reduce `scripts/NpcPathing.gd` to a thin stable public façade only if external systems still require its API. It may not own topology, planning, movement, goals, or doors.
3. Delete legacy `scripts/npc_nav/NpcNavigationWorld.gd`, `NpcRoutePlanner.gd`, `NpcLocomotionController.gd`, and `NpcGoalPlanner.gd` when no longer referenced.
4. Remove legacy route dictionaries/metadata that duplicate typed blackboard state, except deliberately retained compatibility diagnostics documented in the report.
5. Remove `NpcSystem` job phase movement, random day-target movement, home timer/snap fallback, door pending-close ownership, and direct route algorithms. Leave registry/spawn/public integration/stat adapters only.
6. Remove blind `toggle_door()` implementation and migrate all remaining callers to desired-state interaction requests. If a UI compatibility method remains, it must delegate safely to `DoorController` and be explicitly named/documented; no metadata inversion logic remains.
7. Remove deprecated test adapters and migrate tests to final fixtures/contracts without deleting coverage.
8. Remove superseded runtime comments and update architecture/debug/test documentation.
9. Update `AGENTS.md` NPC guidance with final commands, architecture, invariants, and extension rules.
10. Write `docs/npc_pathfinding/FINAL_ACCEPTANCE_REPORT.md` using the final matrix below.
11. Run static audits for every prohibited shortcut in Section 22.
12. Run every focused suite separately under required time modes, preserving final reports.
13. Run the full repository all-runner gate on the phase branch.
14. Merge to `master` and rerun the full gate.
15. Run the final visible observation pass when supported:
    - noon work;
    - dusk transition;
    - midnight guard/interior behavior;
    - dawn transition;
    - crowded single/double doors;
    - player/NPC door sharing;
    - dynamic block and route repair.
16. Inspect captures/traces and record observations. Generated files alone are not review.
17. Verify clean startup/no parser warnings from deleted classes and no orphan preload/path references.
18. Verify save migration from representative old snapshots and a new round-trip.
19. Verify world signature and visual/story continuity.
20. Optionally create an annotated local tag such as `npc-pathfinding-v5-complete` only after merged `master` is fully green; do not push unless asked.

### Final static search expectations

The final report shall include commands/results for searches equivalent to:

- NPC `StaticBody3D` construction: zero production NPC bodies.
- NPC movement transform assignment: zero normal-locomotion matches.
- NPC `toggle_door` calls: zero.
- unsafe timeout close condition: zero.
- old `MAX_ITERATIONS` route cap in NPC production planner: zero.
- old scene-scan/hash navigation revision: zero.
- raw random world wander target: zero.
- porch accepted as indoor arrival: zero.
- `canFight` used as duty assignment: zero.
- old one-frame reservation model: zero.
- legacy `scripts/npc_nav` preload/reference: zero after deletion.
- saved transient route/reservation/RVO state: zero.

Allowed spawn/load/safe-placement transform assignments must be listed individually with rationale and validation path.

### Final execution commands

At minimum:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-nav-world-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-repair-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-traffic-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Transition
.\tools\npc\run-npc-observation-tests.ps1 -TimeMode Both
.\tools\run-npc-navigation-tests.ps1
.\tools\run-all-test-runners.ps1
```

The final all-runner invocation must still include broad playtest, story, world signature, visual captures, and visual-manifest validation.

### Phase 13 gates

- Exactly one authoritative NPC autonomy/navigation/movement/door stack remains.
- No prohibited legacy behavior remains.
- Every final focused case passes in its required time mode/seeds.
- All-runner gate passes on branch and merged `master`.
- Final visible/headless observation evidence matches assertions.
- Final acceptance report has no failed mandatory row and no unapproved deviation.
- Repository starts cleanly with no missing script references.
- Save, story, visual, and deterministic world continuity are green.

### Phase 13 report review questions

- Is any legacy code still capable of moving or deciding for an NPC?
- Can any NPC bypass shared doors/interactions?
- Are day/night rules proven in both tests and observation?
- Are all impossible states terminal and diagnosable?
- Is every acceptance claim tied to a command/report/capture?
- Is merged `master`, not merely the feature branch, green?

---

# 23. Final Acceptance Matrix

`FINAL_ACCEPTANCE_REPORT.md` shall reproduce this matrix and provide evidence for every row.

## 23.1 Architecture and ownership

- [ ] NPCs are `CharacterBody3D` agents.
- [ ] Shared motor is used by player and NPCs for physical rules.
- [ ] `NpcSystem` is no longer a pathfinding/door/job movement monolith.
- [ ] No extra `Main*.gd` inheritance layer was added.
- [ ] Runtime contracts are typed; save dictionaries exist only at persistence boundaries.
- [ ] One navigation topology service, one route coordinator, one traffic service, and one door authority exist.

## 23.2 Physical correctness

- [ ] No normal NPC route movement writes transforms.
- [ ] No teleport recovery.
- [ ] No penetration in deterministic geometry suites.
- [ ] No penetration in required fuzz/soak seeds.
- [ ] Closed doors, walls, fences, windows, props, player, hostiles, and NPC bodies are respected.
- [ ] Open doors clear only when controller says physically traversable.
- [ ] Actual post-physics movement drives progress and arrival.

## 23.3 Navigation-world correctness

- [ ] Multiple walkable surfaces per XZ are represented.
- [ ] Headroom, clearance, slope, step, drop, and capability are profile-aware.
- [ ] Door/special traversal is explicit.
- [ ] Dirty events update exact affected tiles.
- [ ] No full scene scan/hash per navigation frame.
- [ ] Unloaded/stale topology is explicit.
- [ ] Semantic interiors, roads, guard posts, work/resource approaches, and staging points exist.

## 23.4 Route correctness

- [ ] Hierarchical global/local route planning is implemented.
- [ ] Searches are deterministic and time-sliced.
- [ ] No false failure from a small hard iteration cap.
- [ ] Start/goal snapping cannot cross walls or vertical layers.
- [ ] Corridor smoothing is capsule-safe.
- [ ] Mandatory traversal actions survive smoothing.
- [ ] Partial routes are explicit only.
- [ ] Unreachable requests terminate with reasons.
- [ ] Route cost choices are inspectable.

## 23.5 Dynamic repair

- [ ] Relevant changes repair affected route segments.
- [ ] Unrelated changes do not force route rebuild/replan.
- [ ] Repair reuses search state.
- [ ] Repair matches fresh A* feasibility/cost in oracle tests.
- [ ] Repeated failure cannot loop forever.
- [ ] Target/resource/door premise failures reach the action planner.

## 23.6 Door safety and intelligence

- [ ] Every doorway has one logical portal/controller.
- [ ] Double doors coordinate as one portal.
- [ ] NPCs never call blind toggle.
- [ ] Player and NPC share authoritative door actions.
- [ ] Open/close requests are idempotent.
- [ ] Door crossing has approach, open, confirmation, reservation, cross, clear, release, and close steps.
- [ ] Occupancy/reservation always prevents close.
- [ ] Obstructed closing reverses safely.
- [ ] Locked/jammed/destroyed/missing states alter plans/routes correctly.
- [ ] Door timeout cannot override safety.

## 23.7 Multi-agent movement

- [ ] Predictive reciprocal avoidance handles open-space encounters.
- [ ] Avoidance cannot leave corridor or bypass static geometry.
- [ ] Narrow resources use space-time node and edge reservations.
- [ ] No adjacent actor swaps.
- [ ] Active crossing cannot be preempted.
- [ ] Wait aging prevents starvation.
- [ ] Wait-for cycles are detected and resolved.
- [ ] Retreat/yield uses physical movement.
- [ ] Reservations/holds clean up on all lifecycle paths.

## 23.8 Purpose and schedules

- [ ] Goals use utility from role, schedule, needs, threats, orders, and world facts.
- [ ] Task plans use explicit action preconditions/effects.
- [ ] Plan execution reacts to changing reality.
- [ ] Ordinary movement targets semantic anchors, not raw random coordinates.
- [ ] Every generated town NPC has a home interior.
- [ ] Dusk return-home begins early enough under normal conditions.
- [ ] At settled night, assigned guards are outside on duty.
- [ ] At settled night, every non-duty NPC is inside home/shelter.
- [ ] Porch/threshold never counts as inside.
- [ ] `canFight` is not guard duty.
- [ ] Threat/script exceptions are explicit and recover to schedule.

## 23.9 Environment interaction

- [ ] Jobs execute real shared smart-object actions.
- [ ] NPC cannot interact through walls/wrong floors/out of reach.
- [ ] Player/NPC object availability is consistent.
- [ ] Capacity/reservations prevent duplicate use/rewards.
- [ ] Resource removal/depletion triggers bounded replanning.
- [ ] Guard intercept positions are reachable and role/weapon aware.

## 23.10 Streaming and saves

- [ ] Active/abstract transitions are safe and hysteretic.
- [ ] No promotion in doors/geometry/occupied footprint.
- [ ] Abstract travel respects semantic connectivity/access.
- [ ] Old saves load deterministically.
- [ ] New saves round-trip durable state.
- [ ] No transient path/reservation/RVO/queue state is saved.
- [ ] Night/day intent reconstructs after load.
- [ ] Actor removal leaves no ownership leak.

## 23.11 Performance, tests, and continuity

- [ ] Focused runner infrastructure rejects stale reports.
- [ ] Every final focused suite passes required day/night/transition matrices.
- [ ] Required fuzz/soak seeds pass.
- [ ] 32-agent performance target passes or has explicit approved revision.
- [ ] 64-agent stress has no correctness/liveness/leak failure.
- [ ] All queues/caches/traces are bounded.
- [ ] Existing dedicated NPC navigation runner passes.
- [ ] Broad playtest passes.
- [ ] Story playtest passes.
- [ ] World signature passes with understood baseline.
- [ ] Visual captures and manifest validation pass.
- [ ] Phase branch and merged `master` both pass the all-runner gate.
- [ ] Final observation artifacts were inspected and documented.

A single unchecked mandatory box means the replacement is not complete.

---

## 24. Extension Rules After Completion

Future NPC movement features shall extend this architecture rather than bypass it.

- Ladders, jumps, swimming, climbing, mounts, boats, elevators, ziplines, and teleporters become typed traversal actions/edges with capability and executor support.
- New smart objects register actions/slots through `SmartObjectService`.
- New NPC roles define goal utility/schedule/action preferences, not custom direct movement loops.
- New hazards affect semantic/dynamic route cost and perception.
- New doors/gates register logical portals and safe volumes.
- New dynamic construction emits navigation change events.
- New crowd behaviors use local avoidance and traffic services, not bespoke sidestep arrays.
- New saves persist durable intent/facts only.
- Every extension adds focused tests in the appropriate suite plus day/night behavior where relevant.

---

## 25. Research and Primary References

These sources inform the required architecture. Use current official Godot 4.6-compatible documentation while implementing; do not copy APIs from outdated examples without verification.

1. Godot Engine, **Physics introduction** — controlled character bodies should use collision movement rather than direct position assignment:  
   <https://docs.godotengine.org/en/stable/tutorials/physics/physics_introduction.html>
2. Godot Engine, **CharacterBody3D** — floor snapping, slope classification, safe margin, and `move_and_slide()` behavior:  
   <https://docs.godotengine.org/en/stable/classes/class_characterbody3d.html>
3. Godot Engine, **NavigationAgent3D** — RVO avoidance callback, performance cost, priority, dimensions, and safe velocity:  
   <https://docs.godotengine.org/en/stable/classes/class_navigationagent3d.html>
4. Godot Engine, **Using NavigationAgents** — feeding current velocity/target and consuming `safe_velocity`:  
   <https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationagents.html>
5. Godot Engine, **NavigationLink3D** — explicit traversal links and costs; useful conceptual reference even though the voxel graph remains custom:  
   <https://docs.godotengine.org/en/stable/classes/class_navigationlink3d.html>
6. Sven Koenig and Maxim Likhachev, **D* Lite** — incremental heuristic replanning and reuse of prior search state:  
   <https://aaai.org/Papers/AAAI/2002/AAAI02-072.pdf>
7. Adi Botea, Martin Müller, and Jonathan Schaeffer, **Near Optimal Hierarchical Path-Finding** — HPA* cluster/entrance abstraction for large game maps:  
   <https://webdocs.cs.ualberta.ca/~jonathan/publications/ai_publications/jogd.pdf>
8. Mike Phillips and Maxim Likhachev, **SIPP: Safe Interval Path Planning for Dynamic Environments** — safe time intervals and waiting around dynamic obstacles/bottlenecks:  
   <https://www.cs.cmu.edu/~maxim/files/sipp_icra11.pdf>
9. Jur van den Berg et al., **Optimal Reciprocal Collision Avoidance for Multi-Agent Navigation** — predictive local velocity avoidance:  
   <https://emotion.inrialpes.fr/fraichard/safety2010/10-vandenberg-etal-icraw.pdf>
10. David Silver, **Cooperative Pathfinding** — space-time reservations, HCA*, and windowed cooperative planning for real-time games:  
    <https://ojs.aaai.org/index.php/AIIDE/article/view/18726>
11. Jeff Orkin, **Three States and a Plan: The A.I. of F.E.A.R.** — goals/actions with preconditions and effects for game AI planning:  
    <https://www.gamedevs.org/uploads/three-states-plan-ai-of-fear.pdf>
12. Michele Colledanchise and Petter Ögren, **Behavior Trees in Robotics and AI: An Introduction** — modular reactive execution and recovery:  
    <https://arxiv.org/abs/1709.00084>
13. ROS 2 Navigation / Nav2, **Navigation Concepts** — separation of planning, control, behavior-tree navigation, action feedback, and recovery:  
    <https://docs.nav2.org/concepts/index.html>

---

## 26. Final Instruction to Codex

Implement one phase at a time and do not skip ahead to attractive features while a lower layer is unproven. Keep every phase mergeable, tested, reported, and green on `master`. Treat every failed collision, unsafe door close, night-schedule violation, deadlock, unexplained route failure, transform shortcut, stale report, and deterministic drift as a real defect.

The result is accepted only when an NPC's purpose, action plan, route, reservations, interactions, physical motion, day/night duty, and failure reason all agree with the actual world—and every item in the final acceptance matrix is supported by reproducible evidence.
