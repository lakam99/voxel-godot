# NPC Pathfinding Authority Rebuild Plan

## Purpose

This document is the step-by-step implementation plan for replacing the current fragile NPC pathfinding stack with one mature, collision-backed route authority.

The plan must be followed sequentially. A later phase must not begin until every strict requirement and exit gate for the current phase is satisfied.

The goal is not to make one screenshot look correct. The goal is to make real booted gameplay, headed live playtests, and automated evidence agree about NPC autonomy.

## Governing Principles

1. Live gameplay is the source of truth.
   - Boot the game.
   - Click New Game where the flow requires it.
   - Observe real NPC bodies, real doors, real physics, real generated structures, and real schedules.

2. One route authority owns route truth.
   - Behavior may choose intent.
   - The route authority decides reachability, route proof, route commitment, cancellation, repair, and failure classification.
   - Movement follows only an authority-issued route lease.

3. Collision is the contract.
   - A route is not executable until the actor footprint has been probed along it.
   - The probe must account for terrain, structures, fences, props, doors, thresholds, and dynamic blockers.

4. Door traversal is part of routing.
   - A door is not a hand-composed offset route.
   - Door edges must prove approach, open, crossing, strict clearance, and close.

5. No named-NPC patches.
   - Mira, Niko, Rowan, or any other named NPC must not receive custom route logic.
   - Named failures are symptoms of shared route contract failures.

6. Budgets can delay work, not hide failure.
   - `pending_budget`, `pending_nav_data`, and `probing` must be bounded and visible.
   - Starvation is a bug.

7. Linear evidence is part of completion.
   - Every phase has a Linear child issue.
   - A phase is Done only when its Linear item includes command, report path, screenshot or trace evidence, and outcome.

8. Do not weaken tests to pass.
   - Tests may be added or clarified.
   - Acceptance requirements must not be relaxed to fit the current implementation.

## Universal Phase Protocol

Every phase uses this protocol.

### Before Starting

1. Re-read `AGENTS.md`, `manifesto.md`, this plan, and the latest phase report.
2. Confirm all lower-numbered phases are complete.
3. Run `git status --short` and record dirty worktree context.
4. Move only the current Linear child issue to In Progress.
5. State the phase goal before editing files.

### During Work

1. Touch only the files required for the current phase.
2. If a lower-phase assumption proves false, stop and repair the lower phase.
3. Keep temporary diagnostics bounded and remove or demote them before exit.
4. Do not introduce gameplay-affecting flags, teleports, direct helper calls, or test-only route success.

### Before Completion

1. Run the phase's focused tests.
2. Run compile smoke.
3. Run required live/headed acceptance when listed.
4. Inspect screenshots or traces when visual behavior matters.
5. Write a phase report under `docs/npc_pathfinding/`.
6. Update Linear with evidence.
7. Mark the Linear child Done only after the gate passes.

### Hard Stop Conditions

Any of these blocks phase completion:

- acceptance comes from mocks, metadata, direct helper calls, source scans, or teleports;
- a no-flags run uses gameplay-affecting flags;
- a route is called ready without collision proof;
- a door route is composed from offsets instead of a door route edge;
- an NPC idles without a truthful route or behavior reason;
- a porch, threshold, wall edge, or roof counts as home interior;
- route state is written outside the authority after the route-state phase;
- Linear is marked Done without evidence.

## Target Architecture

Production NPC pathfinding must converge on this pipeline:

```text
Behavior intent
-> candidate goal resolver
-> route authority
-> collision-backed planner
-> route probe
-> route lease
-> route executor
-> CharacterBody3D motor
-> execution feedback to route authority
```

The route authority owns these states:

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

## Phase 0 - Intake, Freeze, And Linear Setup

### Goal

Freeze the current failure mode and organize the rebuild without changing gameplay behavior.

### Steps

1. Create or confirm the parent Linear issue for NPC pathfinding replacement.
2. Create one Linear child issue for each phase in this plan.
3. Record branch name and dirty worktree state.
4. Collect current relevant docs:
   - `AGENTS.md`
   - `manifesto.md`
   - existing pathfinding handoff and implementation plans
   - latest live playtest reports
5. Run or collect the most recent real gameplay failure evidence.

### Strict Requirements

- No production pathfinding code changes.
- No named-NPC fix attempt.
- The baseline must say whether the game was booted normally and which flags were present.

### Exit Gate

Phase 0 is complete only when Linear contains:

- branch name;
- dirty worktree summary;
- baseline command;
- report path;
- screenshots or trace paths;
- observed NPC state matrix;
- explicit `Next phase allowed: yes`.

## Phase 1 - Current System Audit And Retire List

### Goal

Identify every system that currently influences NPC route truth, then decide what is kept, wrapped, or retired.

### Steps

1. Audit route-related writes and decisions in:
   - `NpcSystem.gd`
   - behavior planners and executors
   - route coordinators
   - navmesh services
   - local planners
   - movement controllers
   - door traversal services
   - traffic and reservation services
   - playtest runners
2. Build a table of:
   - file;
   - responsibility;
   - route state writes;
   - movement writes;
   - collision assumptions;
   - door assumptions;
   - whether it remains production, becomes adapter, or is retired.
3. Identify all direct or implied route authorities.

### Strict Requirements

- No behavior changes unless required to add read-only diagnostics.
- The audit must explain why an NPC can currently stop without one clear owner.
- The retire list must name specific files or functions, not vague subsystems.

### Exit Gate

Phase 1 is complete when the audit report contains:

- complete route authority map;
- retire/wrap/keep decision table;
- known live failure explanation;
- Linear evidence comment;
- explicit `Next phase allowed: yes`.

## Phase 2 - Real-Boot Acceptance Truth Gate

### Goal

Create the acceptance gate that proves whether playtests match actual gameplay.

### Steps

1. Build or verify a headed runner that boots the actual game.
2. The runner must click New Game through the real menu flow.
3. The runner must prove gameplay-affecting flags are unset.
4. Capture checkpoints:
   - spawn;
   - post-knock;
   - Mira expected home return;
   - sleep transition;
   - next morning work/forage/guard window;
   - night return home.
5. Emit an NPC matrix per checkpoint:
   - NPC name/id;
   - role/job;
   - position;
   - inside/outside classification;
   - behavior intent;
   - route state;
   - route reason;
   - collision/probe proof;
   - distance moved;
   - screenshot reference.

### Strict Requirements

- No direct tutorial progression handlers during the act phase.
- No direct NPC movement helpers.
- No metadata-only success.
- The runner is allowed to fail. An honest failure is useful evidence.

### Exit Gate

Phase 2 is complete when the runner exposes the current gameplay truth and Linear records:

- command;
- no-flags proof path;
- report path;
- screenshots;
- pass/fail outcome;
- any mismatch between automated playtest and manual gameplay.

## Phase 3 - Route State Ownership Lockdown

### Goal

Make route truth single-writer before replacing route behavior.

### Steps

1. Introduce or finalize a route state store owned by the route authority.
2. Restrict writes for:
   - `routeStatus`;
   - `routeReason`;
   - route lease id;
   - route proof;
   - terminal route result;
   - route retry counters.
3. Convert behavior, movement, LOD, recovery, and home logic to authority calls or read-only observations.
4. Add a static audit that fails on unauthorized route-state writes.

### Strict Requirements

- Behavior may request intent and cancel intent. It may not declare route success.
- Movement may report physical facts. It may not declare final route truth.
- LOD may defer simulation. It may not invent route states.
- Initialization exceptions must be explicit and audited.

### Exit Gate

Phase 3 is complete only when:

- route-state writer audit passes;
- compile smoke passes;
- real-boot truth gate still runs;
- phase report lists old writers and new approved writers;
- Linear is updated with evidence.

## Phase 4 - Authority Contract And Data Model

### Goal

Define the mature route contract before implementing deeper behavior.

### Steps

1. Define `RouteRequest` fields:
   - actor id;
   - actor body/profile;
   - intent kind;
   - start pose;
   - candidate goals;
   - priority;
   - constraints;
   - world/navigation revision;
   - deadline or patience policy.
2. Define `RouteResult` fields:
   - state;
   - reason;
   - selected goal;
   - route points;
   - route edges;
   - proof;
   - retry policy;
   - required nav data;
   - blocked body/door/segment when known.
3. Define `RouteLease` fields:
   - lease id;
   - owner actor;
   - route revision;
   - current segment;
   - door reservations;
   - expiration/cancel rules.
4. Add focused contract tests for state transitions.

### Strict Requirements

- The contract must distinguish `pending_nav_data`, `pending_budget`, `blocked_dynamic`, `unreachable_static`, and `invalid_goal`.
- `unreachable_static` is illegal until required nav data is ready.
- A route without proof cannot be `ready`.

### Exit Gate

Phase 4 is complete when:

- contract tests pass;
- compile smoke passes;
- docs describe every state and who may set it;
- Linear evidence is attached.

## Phase 5 - Collision Substrate

### Goal

Build the collision-backed primitives that make route proof real.

### Steps

1. Implement actor-footprint standability checks.
2. Implement segment sweep/probe checks using the real NPC movement footprint.
3. Implement route probe checks across all points and edges.
4. Classify probe failures:
   - terrain;
   - wall;
   - fence;
   - prop;
   - closed door;
   - actor/body;
   - unknown physics blocker.
5. Add diagnostics that identify the failed segment and blocker.

### Strict Requirements

- Do not rely on generated cells alone as production proof.
- Do not mark a route ready when the probe fails.
- Do not poison semantic goals permanently for dynamic blockers.

### Exit Gate

Phase 5 is complete when:

- collision probe unit/contract tests pass;
- at least one real headed fixture proves route rejection before actor commitment;
- compile smoke passes;
- report includes screenshots or traces of blocked and valid routes.

## Phase 6 - Candidate Goal Resolver

### Goal

Make semantic goals produce legal, routeable candidate poses instead of guessed vectors.

### Steps

1. Implement candidate generation for:
   - home interior;
   - home exterior;
   - work sites;
   - forage search;
   - guard posts;
   - roam/search points;
   - NPC interaction approach;
   - rescue/tutorial semantic targets where applicable.
2. Filter candidates by:
   - standability;
   - private interior rules;
   - door legality;
   - town bounds;
   - terrain occupancy;
   - actor clearance.
3. Send candidates to the route authority for reachability selection.

### Strict Requirements

- Behavior must not choose final movement points directly.
- Close-enough porch, threshold, wall-edge, or roof poses are invalid for home interior.
- Foragers must support routeable roaming/search when no forage object is reachable.

### Exit Gate

Phase 6 is complete when:

- candidate resolver tests pass for home, work, forage, guard, and invalid target cases;
- compile smoke passes;
- report includes examples of rejected and accepted candidate poses;
- Linear is updated.

## Phase 7 - Planner Broker Behind The Authority

### Goal

Put all route planning behind the authority while reusing useful existing planner pieces as adapters.

### Steps

1. Create the route broker entry point used by production NPCs.
2. Wrap existing navmesh/local planners behind the broker.
3. Ensure required nav data is requested before route failure is declared.
4. Ensure dynamic blockers return `blocked_dynamic`.
5. Ensure budget deferral returns `pending_budget`.
6. Issue route leases only from broker-approved results.

### Strict Requirements

- Production NPCs must not call legacy planners directly.
- Route cache keys must account for relevant static/nav revisions without churning on irrelevant dynamic state.
- Missing tiles or links must not become static unreachable.

### Exit Gate

Phase 7 is complete when:

- direct planner-call audit passes;
- route broker tests pass;
- compile smoke passes;
- real-boot truth gate still runs;
- Linear has evidence.

## Phase 8 - Door Portal Route Edges

### Goal

Make doors first-class route edges with visible, collision-backed traversal.

### Steps

1. Represent door traversal as a route edge.
2. Reserve the door edge before crossing.
3. Open the door before the actor crosses.
4. Probe crossing clearance.
5. Keep active ownership until the actor clears or the route is cancelled.
6. Close the door after clearance when safe.
7. Report door failure distinctly from generic route failure.

### Strict Requirements

- No composed door route offsets.
- No direct door helper calls as acceptance proof.
- Porch/threshold positions cannot count as home.
- Door closure must not happen while the actor occupies the sweep/threshold.

### Exit Gate

Phase 8 is complete when a headed visual test proves:

- approach;
- open;
- cross;
- strict interior or exterior arrival;
- threshold clearance;
- close.

The report must include command, screenshots, trace, and Linear evidence.

## Phase 9 - Route Lease Executor And Motor Integration

### Goal

Make movement execution consume route leases and report physical facts back to the authority.

### Steps

1. Executor accepts only active route leases.
2. Executor follows segments through the shared `CharacterBody3D` motor.
3. Executor reports:
   - segment progress;
   - collision;
   - stuck detection;
   - off-route drift;
   - arrival candidate;
   - cancellation.
4. Authority decides whether to repair, retry, wait, or fail.
5. Remove direct movement loops from production NPC behavior.

### Strict Requirements

- Executor may not invent alternate route points.
- Executor may not mark final success without authority confirmation.
- Stuck detection must include enough data to debug the physical blocker.

### Exit Gate

Phase 9 is complete when:

- lease executor tests pass;
- compile smoke passes;
- static audit finds no production direct movement loops;
- a headed obstacle case shows collision, report, and recovery or truthful failure.

## Phase 10 - Migrate Home And Night Behavior

### Goal

Move the highest-risk home/door/night flow onto the new authority before migrating all jobs.

### Steps

1. Route non-guard night return through the authority.
2. Route home entry through door portal edges.
3. Validate strict interior arrival.
4. Validate threshold clearance.
5. Validate door close after clearance.
6. Keep guard-duty exceptions explicit.

### Strict Requirements

- `canFight` is not guard duty.
- Non-guards outside at night require a truthful route state or behavior reason.
- Home success cannot be metadata-only.

### Exit Gate

Phase 10 is complete when headed real gameplay proves:

- Mira returns home after the knock;
- non-guard NPCs return indoors at night;
- guards remain outside only when assigned guard duty;
- screenshots and route matrices agree.

## Phase 11 - Migrate Day Jobs, Forage, Guard, And Roam

### Goal

Move normal daily autonomy onto the authority so NPCs live their roles without special cases.

### Steps

1. Migrate work routes.
2. Migrate forage search routes.
3. Migrate forage target approach and gathering.
4. Migrate guard patrol/stand routes.
5. Migrate collision-aware roam/search fallback.
6. Ensure idle is explicit and truthful.

### Strict Requirements

- A forager with no reachable forage target must search or roam safely, not freeze.
- A worker with pending nav data must say pending, not idle.
- A guard must not walk into fences, doors, or walls.
- Motion and brain budgets must not starve one role while another moves.

### Exit Gate

Phase 11 is complete only when generated-town headed playtests prove:

- foragers leave or search/roam with active route evidence;
- workers move or work in town;
- guards guard with route/position evidence;
- no unexplained role idling;
- screenshots and NPC matrices agree.

## Phase 12 - Budget, LOD, And Fairness Hardening

### Goal

Prevent route, brain, motion, and nav budgets from becoming silent NPC paralysis.

### Steps

1. Add starvation counters for:
   - route requests;
   - route probes;
   - nav data publication;
   - motion updates;
   - brain updates.
2. Add priority aging for overdue route work.
3. Make active jobs and active route leases eligible for immediate service.
4. Ensure LOD abstraction cannot hide required visible NPC behavior near the player or observed test camera.
5. Add bounded telemetry for skipped actors.

### Strict Requirements

- Budget skips must be observable.
- Active route leases cannot be skipped indefinitely.
- `pending_budget` cannot survive beyond the documented patience limit without escalation.

### Exit Gate

Phase 12 is complete when:

- budget/fairness tests pass;
- generated-town multi-NPC visual playtest has no budget-starved NPCs;
- runtime performance remains acceptable;
- Linear includes report paths and worst observed stall data.

## Phase 13 - Legacy Removal And Static Lockdown

### Goal

Remove production use of the old pathfinding stack and make regression difficult.

### Steps

1. Delete or demote legacy production pathfinding paths.
2. Keep old logic only in explicitly named synthetic tests or diagnostics when useful.
3. Add static audits for:
   - direct route-state writes;
   - direct planner calls;
   - direct movement loops;
   - composed door routes;
   - metadata-only acceptance claims.
4. Update docs to name the new authority as the only production pathfinding owner.

### Strict Requirements

- No production fallback may bypass the route authority.
- No acceptance runner may certify NPC movement through direct helper calls.
- Static audits must run in the standard NPC test sequence.

### Exit Gate

Phase 13 is complete when:

- all static audits pass;
- compile smoke passes;
- focused NPC suites pass;
- docs and AGENTS ownership statements are updated;
- Linear is updated.

## Phase 14 - Full Live Acceptance Matrix

### Goal

Prove the replacement in real gameplay across tutorial and generated-town autonomy.

### Steps

1. Run full no-flags real tutorial playthrough from the main menu.
2. Run focused Mira home/door visual acceptance.
3. Run generated-town day job cycle visual acceptance.
4. Run go-home/night visual acceptance.
5. Run multiple fresh random seeds.
6. Inspect screenshots and matrices.
7. Record any remaining failures as explicit bugs, not hidden caveats.

### Strict Requirements

- At least one run must be true real boot from main menu/New Game.
- At least one run must use a known previously failing seed.
- Fresh random seeds must be included unless blocked by a documented external failure.
- Screenshots must be inspected, not merely generated.

### Exit Gate

Phase 14 is complete only when reports show:

- Mira returns home after knock in actual gameplay;
- Niko or equivalent foragers forage/search/roam with route evidence;
- Rowan or equivalent workers leave/work with route evidence;
- guards guard;
- non-guards return home at night;
- no unexplained NPC idling;
- automated playtests and manual-style live observations tell the same story.

## Phase 15 - Rollout, Maintenance, And Future Guardrails

### Goal

Make the new pathfinding authority maintainable so future gameplay work can resume safely.

### Steps

1. Update developer docs.
2. Add short architecture notes near the route authority files.
3. Add troubleshooting guidance for route states and common failures.
4. Add recurring acceptance command list.
5. Close the parent Linear issue only after all child phases are Done.

### Strict Requirements

- The docs must explain where to add new route intents.
- The docs must explain where not to add movement shortcuts.
- The docs must preserve the live-gameplay evidence standard.

### Exit Gate

Phase 15 is complete when:

- all phase reports exist;
- all Linear children are Done;
- parent Linear issue is Done;
- the current branch is committed as requested;
- no known pathfinding blocker remains untracked.

## Recommended Command Gates

Run these as applicable during phase exits:

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\assert-npc-acceptance-runner-clean.ps1 <runner-script-or-scene>
.\tools\npc\assert-npc-route-state-writers.ps1
.\tools\npc\assert-npc-legacy-pathfinding-clean.ps1
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -RealBoot -Visible
.\tools\npc\run-npc-go-home-visual-playtest.ps1
.\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1
```

## Completion Definition

This rebuild is complete only when the live booted game can show the NPC loop working without special flags:

- NPCs choose appropriate goals.
- NPCs move with purpose.
- NPCs enter and exit homes through real doors.
- Foragers forage or search safely.
- Workers work.
- Guards guard.
- Night and morning transitions work.
- Blocked routes produce truthful reasons.
- Playtests and real gameplay agree.

Until this is true, NPC pathfinding remains the project priority.
