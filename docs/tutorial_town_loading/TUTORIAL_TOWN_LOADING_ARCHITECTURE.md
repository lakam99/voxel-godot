# Tutorial Town Loading Architecture

This document describes the production ownership left by `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` after Phase 8. Historical phase reports explain how the system migrated; this file is the current contract.

## Published World Contract

`StructureSystem` owns generated structures, town home records, door records, town-manifest publication, and generic private-interior records. The tutorial starter shelter publishes its validated interior bounds through `register_private_interior()`. Generic navigation consumes these structure records; it does not query `TutorialSystem`, scan nearby tutorial blocks, or guess fallback bounds.

`TutorialSystem.prepare_tutorial_world_staged()` remains inside the loading gate until all of the following are ready:

1. semantic scenario requirements;
2. drained structure operations and a validated town manifest;
3. required door blocks and portal registrations;
4. manifest-derived actor profiles and ordinary NPC registration;
5. the generic town-population ownership claim;
6. accepted initial generic orders;
7. authoritative terrain collision, navigation changes, navigation tiles/map, and the physics gate owned by `MainCore`.

Any missing required record returns a structured failed readiness result. Gameplay is not enabled and dialogue does not repair or regenerate town data.

## Scenario And NPC Boundary

`TutorialSceneBuilder` owns actor identity, presentation, scenario home assignment, and initial spawn placement. It creates ordinary `npc` bodies and registers them once through `NpcSystem.register_npc()` with exact manifest-owned home, porch, door, landing, strict-interior, and route records.

The story-only `story_actor_scope=tutorial` body metadata lets `TutorialDialogueSystem` recognize scenario actors. It is not present in the NPC profile and no generic NPC system interprets it.

`NpcSystem` exposes only generic movement commands: wait, go to, go home, resume schedule, and cancel. Tutorial orchestration selects an actor and submits one of those commands. Normal order replacement, route authority, collision-backed proof, motor execution, door traversal, traffic reservations, arrival, and recovery own everything after submission.

Later rescue choreography follows the same rule: the forager travels to the encounter via `order_go_to`, returns through `order_go_home`, and the guard travels to the configured guard post through `order_go_to`. Production tutorial code does not teleport an already registered NPC to complete choreography or recovery.

## Strict Home Semantics

Only `HomeInteriorService` strict-interior truth can set `insideHome`. Porch, threshold, door-clearance, exterior wall edge, fallback cell, or a terminal route outside the interior cannot complete home arrival. A terminal home route outside the strict interior records `home_route_terminal_outside` and remains a recoverable blocked state.

## Population And Privacy

Scenario-controlled town population uses `NpcSystem.claim_town_population(town_key, owner_id)`. This is a generic, explicit startup ownership claim; `NpcSystem` has no tutorial-town lookup or named-town exception.

Private interiors use stable structure-owned records with normalized bounds and optional owner IDs. Navigation blocks actors from other private interiors while allowing an owning actor to use its own record. The player starter shelter uses owner `player`; generated NPC homes continue to come from published town home records.

## Release Audits And Telemetry

`TutorialGenericOrderContractRunner` recursively scans `NpcSystem.gd` and `scripts/npc_ai/` to prevent tutorial identity branches, named actor branches, tutorial-only actions, guessed starter geometry, combined intro/home APIs, and obsolete porch fallback paths. `StartupLoadingReadinessContractRunner` verifies loading completion remains ordered after manifest, door, registration, initial-order, navigation, and physics readiness.

Permanent NPC stall traces remain generic and bounded. Terrain payload retirement is also bounded: at most four completed payload graphs may await a single low-priority cleanup worker, and meshing applies backpressure at that limit. The backend summary exposes backlog, limit, cleanup activity/count, and start failures for release diagnostics.

Contract and synthetic reports support these invariants but do not replace headed acceptance. Release claims still require the real Main Menu to New Game path, visible interaction, prompt generic go-home acceptance, physical departure, generated-home door traversal, strict interior arrival, and door closure.
