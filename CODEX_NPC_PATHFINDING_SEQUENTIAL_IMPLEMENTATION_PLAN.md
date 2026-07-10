# NPC Pathfinding Sequential Implementation Plan

## Plan Status

Exported on 2026-07-10 as the strict sequential implementation plan for the NPC pathfinding rebuild.

Use this document as the working phase gate for replacement work unless the user explicitly supersedes it. Earlier pathfinding plans and handoffs remain context, but this file is the step-by-step execution checklist. If this plan conflicts with `AGENTS.md`, `manifesto.md`, or a current user instruction, stop and resolve the conflict before coding.

## Purpose

This document is a strict, phase-by-phase implementation plan for replacing the current NPC pathfinding stack with one mature collision-backed route authority.

It exists because the current pattern is not acceptable for production gameplay: one NPC moves, another stalls, a narrow test passes, then real gameplay contradicts it. The replacement must make live gameplay and automated playtests agree.

The plan is sequential. Do not skip phases. Do not start a later phase because it looks easier. Do not mark a phase complete because one named NPC improved.

## Governing Principle

Behavior chooses intent. The route authority decides whether that intent can physically become movement.

The production pipeline must become:

```text
NPC schedule / behavior intent
-> one route authority
-> collision-backed route planning
-> probe-before-commit proof
-> authority-issued route lease
-> route executor
-> CharacterBody3D motor
-> execution result back to route authority
```

Everything else is either input, execution, observation, or diagnostics.

## Non-Negotiable Rules

1. Live gameplay is the source of truth.
   - A headed real game run can disprove a synthetic test.
   - A synthetic test cannot prove live gameplay.

2. There is one route authority.
   - Production code must have exactly one owner for route status, route reason, route leases, route proof, route cancellation, and terminal route classification.

3. Collision is the contract.
   - A route is not executable until the actor footprint has been collision-probed along the route.
   - Guessing from metadata, generated cells, or hand-authored offsets is not route proof.

4. Door traversal is a route edge.
   - Doors are not a composed route trick.
   - Door routes must prove approach, open, cross, threshold clearance, and close.

5. No named-NPC fixes.
   - Mira, Niko, Rowan, and every other named NPC are symptoms unless proven otherwise.
   - Fix the shared route contract.

6. No fake acceptance.
   - No teleport-driven proof.
   - No direct tutorial handler calls.
   - No direct `move_npc` acceptance.
   - No metadata-only success.
   - No gameplay-affecting flags in no-flags acceptance.

7. Linear mirrors completion.
   - Every phase has a Linear child issue.
   - A phase is not Done in Linear until its strict exit gate passes.
   - The parent pathfinding replacement issue stays In Progress until all phases pass.

8. Budgets defer work; they do not decide truth.
   - `pending_budget`, `pending_nav_data`, and `probing` are temporary states.
   - Starvation must be measured, bounded, and reported.

9. Porch, threshold, roof, exterior wall edge, and "close enough" do not mean inside.
   - Home acceptance requires strict interior occupancy and threshold clearance.

## Required Route States

Use these states consistently across production, reports, and tests:

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

No phase may add an alternate synonym for these states without updating this plan and all reports.

## Standard Phase Protocol

### Before A Phase

1. Re-read:
   - `AGENTS.md`
   - `manifesto.md`
   - this plan
   - the previous phase report
2. Run `git status --short`.
3. Confirm all lower phases have:
   - report file;
   - Linear evidence;
   - `Next phase allowed: yes`.
4. Move only the current phase Linear issue to In Progress.
5. State the current phase goal before editing code.

### During A Phase

1. Implement only the current phase.
2. Keep compatibility shims small and explicitly marked.
3. If a lower phase contract proves false, stop and repair the lower phase.
4. Do not start later phase code while the current phase has failing gates.
5. Keep diagnostics bounded and remove or demote temporary probes before exit.

### Exiting A Phase

Every phase exit requires:

1. Focused phase tests.
2. Compile smoke.
3. Required headed/live playtest when visual or gameplay behavior matters.
4. Manual inspection of screenshots/traces when NPC visibility matters.
5. Phase report under `docs/npc_pathfinding/`.
6. Linear comment with:
   - commands;
   - report paths;
   - screenshots or traces;
   - outcome;
   - known remaining failures.
7. Linear child issue marked Done only if the gate passes.
8. Report line: `Next phase allowed: yes` or `Next phase allowed: no`.

## Phase 0 - Intake, Baseline, And Work Control

### Goal

Freeze the current failure mode and organize the replacement work before changing production pathfinding.

### Implementation Steps

1. Confirm or create the Linear parent issue for NPC pathfinding replacement.
2. Create Linear child issues for every phase in this plan.
3. Record current branch and dirty worktree state.
4. Capture the current real gameplay failure:
   - boot game;
   - click New Game where relevant;
   - avoid gameplay-affecting flags;
   - observe NPC autonomy after tutorial knock, night return, and next morning.
5. Write a baseline matrix for Mira, Niko, Rowan, guards, foragers, and workers.

### Strict Requirements

- No production pathfinding code changes.
- No named-NPC fixes.
- No acceptance claims.
- The baseline must say exactly what was run and which flags were present.

### Exit Gate

Phase 0 is complete only when:

- Linear has all child phase issues;
- baseline command is recorded;
- report path is recorded;
- screenshots or trace evidence are attached or referenced;
- current NPC failure matrix is written;
- `docs/npc_pathfinding/PHASE_0_BASELINE_FREEZE_REPORT.md` exists.

## Phase 1 - Real-Boot Autonomy Acceptance Gate

### Goal

Build the acceptance test that tells the truth about actual gameplay before fixing the system.

### Implementation Steps

1. Add or harden a headed real-boot runner that starts at the main menu.
2. The runner must click New Game through the real UI.
3. The runner must prove these are unset for no-flags acceptance:
   - `VOXEL_PLAYTEST`
   - `VOXEL_TEST_SEED`
   - `VOXEL_SAVE_PATH_OVERRIDE`
   - god mode
   - any gameplay shortcut flag
4. Observe checkpoints:
   - world loaded;
   - post-knock Mira state;
   - Mira should have returned home;
   - after sleep transition;
   - next morning work/forage/guard window;
   - night return home.
5. Emit per-NPC rows:
   - name;
   - job/role;
   - schedule state;
   - behavior intent;
   - route state;
   - route reason;
   - current position;
   - moved distance since prior checkpoint;
   - inside/outside classification;
   - door/threshold classification;
   - screenshot reference.

### Strict Requirements

- The runner must not call tutorial progression handlers during the act phase.
- The runner must not directly call NPC movement helpers.
- The runner must not directly open/close doors.
- The runner must not mark success from metadata alone.
- The expected initial result is allowed to fail if gameplay is actually broken.

### Exit Gate

Phase 1 is complete only when the runner can fail honestly against broken gameplay and produce a trustworthy report.

## Phase 2 - Route State Writer Lockdown

### Goal

Stop multiple systems from owning route truth.

### Implementation Steps

1. Inventory all production writes to:
   - route status;
   - route reason;
   - route destination;
   - route lease;
   - route proof;
   - arrival state;
   - stuck/failure classification.
2. Create or finalize a route state store owned by the route authority.
3. Convert other systems to authority APIs:
   - behavior requests intent;
   - movement reports facts;
   - doors report portal state;
   - traffic reports reservation state;
   - LOD reports abstraction requests.
4. Add a static audit that fails on forbidden route-state writes.

### Strict Requirements

- Behavior cannot declare `arrived`.
- Movement cannot declare terminal route truth.
- Recovery cannot silently rewrite route state.
- `NpcSystem` cannot become the route authority.

### Exit Gate

Phase 2 is complete only when:

- static route writer audit passes;
- compile smoke passes;
- real-boot autonomy gate still runs;
- Linear lists approved route-state writers.

## Phase 3 - Route Authority State Machine

### Goal

Build the single production authority lifecycle before broad behavior migration.

### Implementation Steps

1. Implement the authority request API:
   - request id;
   - actor id;
   - intent;
   - priority;
   - deadline;
   - candidate goals;
   - world/topology revision.
2. Implement the authority lifecycle states from this plan.
3. Implement cancellation and replacement semantics.
4. Implement route leases as the only executable route artifact.
5. Implement per-NPC debug export.
6. Add contract tests for all lifecycle transitions.

### Strict Requirements

- No NPC may move through the new authority until lifecycle tests pass.
- No production route source may skip the authority.
- New authority state must be observable in the real-boot matrix.

### Exit Gate

Phase 3 is complete only when lifecycle tests pass and the real-boot matrix includes authority state for every observed NPC.

## Phase 4 - Collision-Backed Route Substrate

### Goal

Create the physical route substrate that the authority can trust.

### Implementation Steps

1. Build a town navigation representation from generated world data plus real collision checks.
2. Validate standable actor poses:
   - terrain support;
   - actor footprint clearance;
   - head clearance;
   - no fence/wall/prop overlap;
   - no invalid roof/porch/threshold unless explicitly requested.
3. Validate route segments using collision sweeps.
4. Generate routeable candidate poses for:
   - home interior;
   - home exterior;
   - work areas;
   - forage targets;
   - guard posts;
   - door approach and exit sides.
5. Classify failures as:
   - invalid goal;
   - pending nav data;
   - blocked dynamic;
   - unreachable static.

### Strict Requirements

- Generated cells may suggest topology but cannot prove physical movement.
- Partial endpoint success is failure.
- A route that lands on a wall edge, roof, porch, or threshold is not home success.
- Prefer the simplest collision grid that works before adding more planner layers.

### Exit Gate

Phase 4 is complete only when generated-town fixture tests prove reachable, blocked, invalid, and pending cases with collision evidence.

## Phase 5 - Probe Before Commit

### Goal

Make route probing mandatory before an NPC receives movement instructions.

### Implementation Steps

1. Implement route probe certificates.
2. Probe every segment with the actor's real footprint.
3. Probe dynamic blocker cases.
4. Probe static blocker cases.
5. Probe door edge cases.
6. Store proof on the route authority result.
7. Reject or defer every unprobed route.

### Strict Requirements

- No route lease without probe proof.
- Probe budget deferral must remain pending, not blocked.
- Probe failure must include blocker class or blocker id when available.
- The executor cannot start on an unprobed route.

### Exit Gate

Phase 5 is complete only when tests prove an unprobed route cannot become `ready` and collision-blocked routes fail before actor movement begins.

## Phase 6 - Door Portal Authority

### Goal

Make doors first-class route edges instead of offsets, hacks, or composed routes.

### Implementation Steps

1. Model each door as a portal edge in the route graph.
2. Validate both approach side and exit side.
3. Reserve the portal for the actor before traversal.
4. Open the door before crossing.
5. Probe crossing clearance.
6. Move through the portal.
7. Verify threshold clearance.
8. Close the door when safe.
9. Release reservation only after success, cancellation, or timeout cleanup.

### Strict Requirements

- No composed door route.
- No teleport through door.
- No success while actor remains on threshold, porch, or door sweep.
- Route replacement cannot silently drop an active door reservation.

### Exit Gate

Phase 6 is complete only when headed visual evidence shows an NPC approaching, opening, crossing, clearing, and closing a real generated-world door.

## Phase 7 - Lease Executor And Motor Integration

### Goal

Execute only authority-issued leases through the shared character motor.

### Implementation Steps

1. Build or finalize the route lease executor.
2. Use the same `CharacterBody3D` movement contract as live NPC bodies.
3. Report execution events to the authority:
   - segment started;
   - segment completed;
   - door wait;
   - dynamic blocker;
   - no target progress;
   - stuck;
   - arrived;
   - cancelled.
4. Add stuck and no-progress detection based on destination progress, not just body motion.
5. Add route cancellation cleanup.

### Strict Requirements

- Executor cannot invent route semantics.
- Executor cannot create fallback routes.
- Executor cannot write final route status directly.
- Sliding along a wall without closing distance must become an authority-visible execution failure.

### Exit Gate

Phase 7 is complete only when controlled route execution tests and a headed fixture prove leased routes move through real physics and report failures truthfully.

## Phase 8 - Home Return Migration

### Goal

Move home return onto the new authority as the first production behavior.

### Implementation Steps

1. Convert all home-return intents to authority requests.
2. Remove production use of:
   - porch fallback;
   - threshold fallback;
   - near-home success;
   - direct home route arrays;
   - legacy return-home movement loops.
3. Define strict home success:
   - correct home;
   - strict interior position;
   - threshold cleared;
   - not in door sweep;
   - door state valid after traversal.
4. Run post-knock and night-return live checks.

### Strict Requirements

- Do not special-case Mira.
- Do not accept metadata-only `npc_inside_home`.
- Do not let a visual porch/doorway position count as inside.

### Exit Gate

Phase 8 is complete only when the real-boot runner proves post-knock and night-return home behavior for all relevant non-guard NPCs through real gameplay.

## Phase 9 - Daytime Work, Forage, Guard, And Roam Migration

### Goal

Move daytime autonomy onto the same authority.

### Implementation Steps

1. Convert work behavior to route intents.
2. Convert forage behavior to route intents.
3. Convert guard behavior to route intents.
4. Convert roam/search fallback to collision-validated route intents.
5. Require routeable candidate poses for every semantic target.
6. Make unreachable target selection explicit and non-poisoning.
7. Add per-NPC reason reporting for standing still.

### Strict Requirements

- Foragers cannot silently idle outside with no visible route reason.
- Workers cannot remain in houses during work windows without an explicit schedule, behavior, or route reason.
- Guards may remain outside only through explicit guard assignment.
- Blocking one target cannot poison unrelated future targets.

### Exit Gate

Phase 9 is complete only when multi-seed next-morning autonomy evidence shows workers, foragers, guards, and roam/search fallback progressing through authority-owned routes.

## Phase 10 - Legacy Pathfinding Removal

### Goal

Remove or quarantine the old route stack so regressions cannot re-enter through fallback paths.

### Implementation Steps

1. Remove production use of:
   - generated-cell bridge routes;
   - composed door routes;
   - exact-home lattice planners as separate production authority;
   - behavior-owned route retries;
   - movement-owned fallback route repair;
   - partial endpoint success.
2. Keep diagnostics only if clearly named synthetic/diagnostic.
3. Make legacy APIs delegate to the authority or fail static audits.
4. Update docs that describe NPC routing ownership.

### Strict Requirements

- No hidden production fallback planner.
- No diagnostic test may be cited as gameplay acceptance.
- No route-state writer outside approved authority paths.

### Exit Gate

Phase 10 is complete only when static audits prove old production pathfinding cannot write route truth or claim acceptance.

## Phase 11 - Budgeting, Fairness, And Starvation Control

### Goal

Make the new authority stable under real town load.

### Implementation Steps

1. Add bounded queue budgets for route planning.
2. Add bounded queue budgets for collision probing.
3. Add fairness so one actor cannot starve others.
4. Add aging priority for blocked or long-waiting requests.
5. Add telemetry:
   - queued frames;
   - pending budget frames;
   - pending nav frames;
   - probe wait;
   - dynamic blocks;
   - static unreachable;
   - stuck reports;
   - arrival count;
   - cancellation count.
6. Run soak and runtime performance observations.

### Strict Requirements

- Budgeting cannot become unexplained idling.
- Performance fixes cannot weaken route proof.
- Starvation counters must appear in reports.

### Exit Gate

Phase 11 is complete only when soak evidence shows bounded route waits and runtime evidence shows no pathfinding-related gameplay hitch that invalidates the route system.

## Phase 12 - Player-Driver Test Reliability Separation

### Goal

Keep live playtest reliability from blocking NPC pathfinding acceptance while ensuring the playtest still reflects real gameplay.

### Implementation Steps

1. Use a route-planned player driver only for player movement reliability in tests.
2. Ensure the player driver uses real input paths:
   - WASD-style movement;
   - real clicks for interactions;
   - real door interactions;
   - no direct tutorial handlers.
3. Prove no gameplay-affecting flags in no-flags tutorial runs.
4. Report when the player driver, not NPC pathfinding, causes a failure.

### Strict Requirements

- Player-driver routing is not NPC pathfinding acceptance.
- It must not force NPCs to move.
- It must not make test gameplay more favorable than manual gameplay.

### Exit Gate

Phase 12 is complete only when the tutorial playtest can drive the player reliably without changing NPC autonomy truth.

## Phase 13 - Full Live Acceptance

### Goal

Declare the replacement complete only after real gameplay proves it.

### Implementation Steps

1. Run compile smoke.
2. Run static route authority audits.
3. Run route, behavior, door, traffic, interaction, streaming/save, and soak NPC suites.
4. Run real-boot autonomy matrix from New Game.
5. Run full live tutorial playthrough with no gameplay-affecting flags.
6. Run known failing seed coverage.
7. Run multiple fresh generated-town seeds.
8. Inspect screenshots and traces manually.
9. Update every Linear phase item.
10. Mark the parent Linear issue Done only after all evidence passes.

### Strict Requirements

- The final report must say what was proven and what was not proven.
- At least one known failing seed must be included.
- Fresh random seeds must be included where practical.
- Screenshots/traces must be inspected, not just generated.
- Any unexplained NPC standing still blocks completion.

### Exit Gate

Phase 13 is complete only when live gameplay shows:

- Mira returns home after knock through real gameplay;
- non-guard NPCs return indoors at night;
- next morning workers and foragers leave or act according to visible schedule reasons;
- guards remain outside only because guard duty says so;
- doors open, crossing clears, and doors close;
- no NPC is reported arrived on porch, threshold, roof, or exterior wall edge;
- automated playtests and manual gameplay tell the same story.

## Standard Phase Report Template

Each phase report must use this shape:

```text
Phase:
Branch:
Linear issue:
Dirty worktree before phase:
Commands run:
Reports:
Screenshots/traces:
Code changed:
Acceptance result:
Known failures:
Hard stops encountered:
Next phase allowed: yes/no
Reason:
```

## Required Commands By Class

Use the exact project scripts where possible:

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\assert-npc-acceptance-runner-clean.ps1
.\tools\npc\assert-npc-route-state-writers.ps1
.\tools\npc\assert-npc-legacy-pathfinding-clean.ps1
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both
.\tools\npc\run-real-tutorial-playthrough.ps1
.\tools\npc\run-real-tutorial-playthrough-no-flags.ps1 -DayOne -Visible
.\tools\npc\run-npc-town-job-cycle-visual-playtest.ps1
.\tools\npc\run-npc-go-home-visual-playtest.ps1
.\tools\run-normal-runtime-performance-pass.ps1
```

## Hard Stop Checklist

Stop and repair the current or lower phase if any of these happen:

- a test forces an NPC to move;
- a test succeeds through metadata without visible gameplay proof;
- a route lease exists without probe proof after Phase 5;
- an NPC is considered home on a porch, threshold, roof, or exterior wall edge;
- a door route is composed from hand-authored offsets instead of a route portal edge;
- a route state is written outside the authority after Phase 2;
- a budget state persists without starvation telemetry;
- a named NPC patch is proposed;
- Linear is marked Done without evidence;
- manual gameplay contradicts automated playtest results.

## Immediate Execution Order

1. Finish or repair the lowest incomplete phase.
2. Do not proceed to a later phase until the current phase report says `Next phase allowed: yes`.
3. If the project is already mid-phase, identify the earliest violated contract and resume there.
4. Keep the final acceptance standard tied to real booted gameplay, not a narrow runner result.
