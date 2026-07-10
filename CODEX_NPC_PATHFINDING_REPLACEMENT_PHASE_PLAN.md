# NPC Pathfinding Replacement Phase Plan

## Purpose

This plan replaces the current NPC route decision architecture with a single collision-backed route authority. It is sequential by design. Do not skip phases, merge phases, or mark a phase complete because a narrow screenshot improved.

The goal is not to make Mira, Niko, Rowan, or any named NPC pass in isolation. The goal is to make every production NPC route through the same mature pathfinding contract:

- behavior chooses an intent;
- the route authority resolves a physically reachable route;
- the route is collision-probed before commitment;
- the executor follows only an authority-issued route lease;
- gameplay acceptance comes from the real booted game.

## Non-Negotiable Rules

1. Live gameplay is the source of truth.
   - Acceptance must launch the real game, click New Game where relevant, and observe actual NPC behavior.
   - Synthetic, service-level, metadata-only, direct-helper, or teleport-driven tests may support development but cannot prove acceptance.

2. There is one route authority.
   - Production code must not let behavior, movement, recovery, LOD, home logic, or `NpcSystem` directly decide final route truth.
   - `routeStatus`, `routeReason`, route leases, route proof, and route failure classification must have a single production writer.

3. Collision is the contract.
   - A route is not ready until the actor's real movement footprint has been collision-probed along the route.
   - If the probe collides, the authority repairs, retries, reports `blocked_dynamic`, or reports `unreachable_static`.
   - An NPC must not be committed to an unprobed route.

4. Doors are route edges, not composed cheats.
   - Door traversal must be part of the authoritative route graph.
   - Door acceptance must prove approach, open, crossing, strict threshold clearance, and close.

5. Budgets delay work but do not define truth.
   - Frame, route, tile, probe, job, and motion budgets may defer work.
   - Budget deferral must not become permanent unreachable state or unexplained idling.
   - Starvation must be visible and bounded.

6. No named-NPC patches.
   - Do not special-case Mira, Niko, Rowan, or any other named NPC.
   - A fix must improve the shared route contract.

7. Linear is part of completion.
   - Each phase gets a Linear child issue.
   - A phase is not complete until the matching Linear item is updated with command, report path, screenshots or trace evidence, and outcome.
   - Parent pathfinding replacement work remains In Progress until every phase gate is complete.

8. Do not weaken tests to pass.
   - If a phase exposes a real gameplay bug, track it and fix the system contract.
   - Do not add flags, direct calls, doctored metadata, or alternate test-only paths.

## Sequential Execution Protocol

This document is a phase gate, not a backlog. Work must proceed in numeric order.

### Before Starting Any Phase

1. Confirm every lower-numbered phase has a report, Linear evidence, and an explicit `Next phase allowed: yes`.
2. Re-read:
   - `AGENTS.md`;
   - `manifesto.md`;
   - this phase plan;
   - the current phase section;
   - the most recent phase report.
3. Run `git status --short` and record whether the worktree is dirty.
4. Move only the current phase's Linear child issue to In Progress.
5. State the current phase goal in the work log before editing code.

### During A Phase

1. Implement only the current phase plus the minimum compatibility code needed to keep the game runnable.
2. If a blocker proves a lower phase contract is false, stop the current phase, reopen or repair the lower phase, and update Linear.
3. Do not begin code for a later phase while the current phase has failing gates.
4. Do not patch a named NPC. Fix the shared route contract that explains the named NPC symptom.
5. Keep all temporary diagnostics bounded and remove or demote them before the phase exits unless the phase explicitly requires them.

### To Exit A Phase

1. Run the phase's focused gates.
2. Run compile smoke.
3. Run any required live/headed gameplay gate for that phase.
4. Inspect screenshots, traces, and reports manually when visual behavior matters.
5. Write the phase report under `docs/npc_pathfinding/`.
6. Update the matching Linear issue with:
   - command;
   - report path;
   - screenshot or trace path when applicable;
   - pass/fail outcome;
   - known remaining failures.
7. Mark the phase Linear issue Done only after the exit gate passes.
8. Do not start the next phase unless the report says `Next phase allowed: yes`.

### Hard Stops

Any of these immediately blocks phase completion:

- acceptance based on synthetic, metadata-only, direct-helper, or teleport-driven proof;
- a gameplay-affecting test flag in a no-flags acceptance run;
- route success without collision/probe proof after Phase 5;
- door traversal through composed route offsets instead of route-edge authority;
- unexplained NPC idling during an observed work/forage/guard/home window;
- false `arrived` on porch, threshold, exterior wall edge, or roof;
- route-state writes outside the approved authority after Phase 2;
- unbounded `pending_budget`, `pending_nav_data`, or `probing` without starvation telemetry;
- a Linear phase item marked Done without matching evidence.

## Target Architecture

Production NPC movement should reduce to this pipeline:

```text
NpcBehaviorIntent
-> NpcRouteAuthorityV2
-> CollisionBackedRoutePlanner
-> RouteProbeService
-> RouteLease
-> NpcRouteExecutor
-> CharacterBody3D motor
-> execution report back to NpcRouteAuthorityV2
```

### Core Concepts

- Intent: a semantic request such as go home, forage, work, guard, flee, idle at location, or talk.
- Candidate pose: a standable actor pose for fulfilling an intent.
- Route request: an authority-owned request with actor, intent, priority, deadline, world revision, and candidate goals.
- Route lease: the only executable route artifact. Executors may follow a lease but may not invent route truth.
- Route proof: collision-probe certificate, door-edge proof, topology revision, and blocked/unreachable classification.
- Door edge: a graph edge with reservation, open, cross, clear, and close semantics.

### Authority States

Use these states consistently:

- `queued`
- `pending_nav_data`
- `pending_budget`
- `probing`
- `ready`
- `moving`
- `blocked_dynamic`
- `unreachable_static`
- `invalid_goal`
- `arrived`
- `cancelled`

## Phase 0 - Baseline Freeze And Work Intake

### Goal

Freeze the current failure mode and organize the replacement work before changing production pathfinding behavior.

### Required Work

1. Create or confirm a Linear parent issue for the replacement.
2. Create one Linear child issue for every phase in this document.
3. Record current branch and dirty worktree state.
4. Re-read:
   - `AGENTS.md`
   - `manifesto.md`
   - `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`
   - `CODEX_MATURE_NAV_PLAN.md`
   - `NPC_PATHFINDING_REGRESSION_HANDOFF.md`
5. Capture a current real-boot NPC autonomy baseline.

### Strict Requirements

- No gameplay-affecting code changes in this phase.
- No attempt to repair a single named NPC.
- The baseline must state exactly which flow was run and whether any environment flags were present.

### Exit Gate

Phase 0 is complete only when Linear has:

- branch name;
- dirty worktree summary;
- baseline command;
- report path;
- screenshots or trace evidence;
- observed NPC state matrix.

## Phase 1 - Real-Boot NPC Autonomy Matrix

### Goal

Create the acceptance gate that exposes the real bug class: one NPC may move while others stall, stay home, or silently idle.

### Required Work

1. Add a headed real-boot runner that starts at the main menu and clicks New Game.
2. Prove `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, `VOXEL_SAVE_PATH_OVERRIDE`, god mode, and gameplay-affecting shortcuts are unset unless the test name explicitly says otherwise.
3. Observe named town NPCs across these checkpoints:
   - after world spawn;
   - after tutorial knock;
   - after Mira should return home;
   - after sleep transition;
   - next morning job/forage window.
4. Emit an NPC matrix per checkpoint:
   - NPC name;
   - position;
   - current behavior intent;
   - route authority state if present;
   - route status/reason;
   - inside/outside classification;
   - last movement delta;
   - last collision/probe result;
   - screenshot reference.

### Strict Requirements

- The runner must not directly call tutorial handlers, NPC movement helpers, door helpers, sleep helpers, or metadata setters during the act phase.
- This gate is expected to fail before the replacement is complete.
- Passing only because one NPC moved is failure.

### Exit Gate

Phase 1 is complete when the real-boot autonomy matrix fails honestly against current production behavior and the failure is tracked in Linear.

## Phase 2 - Route State Writer Lockdown

### Goal

Stop the project from having multiple route authorities.

### Required Work

1. Introduce a route state store or authority facade as the only allowed writer for:
   - `routeStatus`;
   - `routeReason`;
   - route lease id;
   - route proof;
   - active route lifecycle;
   - terminal route classification.
2. Add a static audit that fails if production code writes those fields outside approved authority files.
3. Convert direct route-state writes in behavior, movement, recovery, LOD, and home services into authority calls or read-only observations.
4. Keep spawn/load initialization explicit and separately audited.

### Strict Requirements

- Behavior may request or cancel intents. It may not declare route success/failure.
- Movement may report physical execution facts. It may not declare final route truth.
- LOD may request abstraction. It may not write route truth.
- Home logic may validate strict inside/outside. It may not bypass route authority.

### Exit Gate

Phase 2 is complete only when:

- static writer audit passes;
- compile smoke passes;
- real-boot autonomy matrix still runs;
- Linear comment includes the before/after list of route-state writers.

## Phase 3 - NpcRouteAuthorityV2 Skeleton

### Goal

Build the new authority lifecycle before migrating actual NPC behavior.

### Required Work

1. Add `NpcRouteAuthorityV2` with explicit request, queue, lifecycle, result, and cancellation APIs.
2. Add route request ids and route leases.
3. Add starvation accounting:
   - queued frame count;
   - pending budget count;
   - pending nav data count;
   - pending probe count;
   - last serviced frame.
4. Add debug export of authority state per NPC.
5. Add contract tests for state transitions.

### Strict Requirements

- This phase must not use generated-cell bridge as a production route source.
- This phase must not move NPCs through the new system yet.
- The old system may remain active, but the new authority must be testable and observable.

### Exit Gate

Phase 3 is complete when contract tests prove lifecycle transitions and the real-boot matrix includes the new authority debug fields without changing gameplay behavior.

## Phase 4 - Collision-Backed Route Substrate

### Goal

Create the physical navigation substrate for town NPCs.

### Required Work

1. Build a collision-backed town route graph from generated-world data and real physics checks.
2. Represent standable cells, blocked cells, slopes/steps if applicable, dynamic blockers, and doors.
3. Generate candidate poses for each semantic target:
   - home interior;
   - home exterior;
   - work area;
   - forage target;
   - guard post;
   - interaction target.
4. Add strict target validation:
   - goal exists;
   - goal is standable;
   - actor footprint fits;
   - target is not merely near a wall/porch/window unless that is the intent.

### Strict Requirements

- Prefer a simple collision-grid planner for town NPCs unless this phase produces written evidence that Godot navmesh is safer for the current game.
- Generated cell data may inform the graph, but cannot be accepted without collision validation.
- Partial endpoint routes are not success.

### Exit Gate

Phase 4 is complete when route substrate tests can classify reachable, blocked, invalid, and pending cases on generated town fixtures and report collision proof.

## Phase 5 - Probe-Before-Commit Planning

### Goal

Make collision probing mandatory before any route becomes executable.

### Required Work

1. Add a route probe service that sweeps the actor's real footprint along candidate route segments.
2. Probe door edges as structured portal edges:
   - approach side;
   - door open state;
   - crossing clearance;
   - destination side;
   - threshold clearance.
3. Return a route proof object for every authority decision.
4. Classify probe outcomes:
   - clear;
   - blocked by static world;
   - blocked by dynamic actor/object;
   - door unavailable;
   - pending probe budget;
   - invalid route geometry.
5. Repair only through the authority.

### Strict Requirements

- No NPC can receive a route lease without a successful probe certificate.
- Probe budget deferral must remain `pending_budget` or `probing`, not `blocked`.
- Probe failure must include blocker identity or blocker class when available.

### Exit Gate

Phase 5 is complete when route plans cannot become `ready` without probe proof and collision-blocked routes fail before actor movement begins.

## Phase 6 - Route Executor And Motor Integration

### Goal

Move NPCs through authority-issued leases using the existing `CharacterBody3D` motor.

### Required Work

1. Add or refactor a route executor that consumes only route leases from `NpcRouteAuthorityV2`.
2. Preserve use of the shared character motor profile.
3. Report execution events back to authority:
   - segment started;
   - segment completed;
   - stuck;
   - unexpected collision;
   - door wait;
   - arrived.
4. Convert local avoidance and stuck recovery into authority-visible execution reports.

### Strict Requirements

- Executor may not invent fallback routes.
- Executor may not mutate route truth directly.
- Direct `move_npc` style calls remain legacy-only until migrated and must be clearly audited.

### Exit Gate

Phase 6 is complete when a controlled NPC can follow a leased, probed route through real physics and the executor reports all movement outcomes to authority.

## Phase 7 - Migrate Home Return

### Goal

Make home return the first production behavior fully owned by the new authority.

### Required Work

1. Route all home-return intents through `NpcRouteAuthorityV2`.
2. Replace legacy `homeRoutePositions`, porch fallback, threshold fallback, partial-arrival success, and hand-authored home route terminal logic.
3. Define strict inside-home validation:
   - actor is inside the correct home volume;
   - actor cleared the threshold;
   - door state is valid after crossing;
   - porch, wall edge, roof, or near-door exterior does not count.
4. Run the real-boot matrix against the post-knock and night-return cases.

### Strict Requirements

- Do not special-case Mira.
- Door traversal must be route-edge based.
- The acceptance evidence must include screenshots or trace frames showing outside-to-inside transition.

### Exit Gate

Phase 7 is complete only when all relevant NPCs can return home through real gameplay in the real-boot runner and no named-NPC special case exists.

## Phase 8 - Migrate Work, Forage, Guard, And Roam

### Goal

Move daytime autonomy onto the same route authority.

### Required Work

1. Convert work, forage, guard, and roam behavior into intents.
2. Remove route retry and route truth writes from behavior.
3. Require routeable candidate poses for all job and forage targets.
4. If a forage target is unreachable, report it through authority and select another valid intent.
5. If no forage target exists, route to collision-validated roam/search anchors.

### Strict Requirements

- Foragers must not idle silently outside unless their intent and pending reason are visible.
- Staying inside during a daytime job window must be explained by behavior state, route state, or schedule state.
- Blocking one target must not poison unrelated future targets.

### Exit Gate

Phase 8 is complete when the next-morning autonomy matrix shows town NPCs selecting and progressing through appropriate work/forage/guard intents over multiple generated seeds.

## Phase 9 - Remove Legacy Production Pathfinding

### Goal

Delete or quarantine the old route decision stack so regressions cannot re-enter through fallback paths.

### Required Work

1. Remove production use of:
   - generated-cell bridge routes;
   - exact-home collision lattice as a separate production planner;
   - composed door routes;
   - partial endpoint success;
   - behavior-owned route retries;
   - non-authority route-state writes.
2. Keep useful diagnostics only if renamed and clearly blocked from production acceptance.
3. Make old APIs delegate to the new authority or fail loudly in production audits.
4. Update AGENTS-facing docs to describe the new authority.

### Strict Requirements

- No hidden fallback planner may claim production success.
- Diagnostics must not be cited as gameplay acceptance.
- Static audit must catch legacy route-state writes and forbidden route sources.

### Exit Gate

Phase 9 is complete when static audits prove production NPC movement has one route authority and no generated-cell/composed-door fallback path remains active.

## Phase 10 - Performance, Fairness, And Soak

### Goal

Make the new authority stable under real gameplay load.

### Required Work

1. Add bounded queue budgets for planning and probing.
2. Add fairness guarantees so one NPC cannot starve indefinitely.
3. Add counters for:
   - queue wait;
   - probe wait;
   - dynamic blocks;
   - static unreachable;
   - route repairs;
   - successful arrivals;
   - stuck recovery.
4. Run runtime performance observation with tutorial town traversal and active NPCs.
5. Run NPC soak tests across day/night transition.

### Strict Requirements

- Budgeting can delay but cannot silently idle an NPC indefinitely.
- Performance fixes must not weaken route proof.
- No acceptance claim from metadata alone.

### Exit Gate

Phase 10 is complete when performance reports show bounded planning/probe cost and soak evidence shows no persistent NPC starvation.

## Phase 11 - Full Release Acceptance

### Goal

Declare the replacement complete only after real gameplay proves it.

### Required Work

1. Run compile smoke.
2. Run static acceptance audits.
3. Run real-boot NPC autonomy matrix.
4. Run full live tutorial playthrough with no gameplay-affecting flags.
5. Run focused home/door visual playtests.
6. Run multi-seed generated-town NPC autonomy tests.
7. Inspect screenshots and traces manually.
8. Update Linear parent and child issues with evidence.

### Strict Requirements

- The final claim must state what was proven and what was not proven.
- At least one known failing seed and multiple fresh random seeds must be included where practical.
- The final evidence must include command, report path, screenshots or trace/timeline evidence, and result summary.

### Exit Gate

Phase 11 is complete when:

- all phase child issues are Done in Linear;
- the parent Linear issue is Done;
- the project docs point to the new authority;
- real-boot gameplay shows stable home return, daytime work/forage/guard progression, and no unexplained NPC standing still.

## Standard Phase Report Template

Each phase report must include:

```text
Phase:
Branch:
Linear issue:
Commands run:
Reports:
Screenshots/traces:
Code changed:
Acceptance result:
Known failures:
Next phase allowed: yes/no
Reason:
```

## Immediate Next Step

Start at Phase 0. Do not write new pathfinding code until Phase 0 and Phase 1 have created the real-boot failure matrix. The project needs an honest failing gate before it needs another pathfinding patch.
