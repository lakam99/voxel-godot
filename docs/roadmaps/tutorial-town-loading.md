# Tutorial Town Loading And Ordinary NPC Integration Plan

Historical phase reports referenced below are preserved in the [documentation repository](https://github.com/lakam99/voxel-godot-docs/tree/main/gameplay/tutorial-town/history). New reports for resumed work belong under `gameplay/tutorial-town/reports/` in that repository.

## Purpose

This plan removes tutorial-specific movement privilege from production NPC systems and makes the generated tutorial town a complete loading artifact before gameplay begins.

The motivating failure is the recurring post-knock delay where Mira remains at the player house before eventually returning home. Source audit found that the dialogue acknowledgement path can reject a one-shot home command while generated town-home records are incomplete, then discard the command. The Phase 0 real-boot baseline also proved a separate failure mode: generated records were available and the generic go-home order and route request were accepted promptly, but route authority remained `pending_budget` for 2,656 physics frames and Mira did not begin moving for 21.77 seconds. The loading/ownership repair in this plan must remove the dropped-command hazard, but it must not be misreported as a fix for a shared route-budget delay.

The mature outcome is:

```text
Main Menu -> New Game
-> loading builds and validates the tutorial town manifest
-> loading drains required structures, doors, terrain collision, and navigation publication
-> ordinary NPCs register once with complete home assignments
-> tutorial scenario issues generic wait/go_home/go_to commands
-> normal NPC authority plans and executes those commands
-> gameplay is enabled only after all startup invariants pass
```

This is a sequential implementation plan. Complete phases in order. Do not combine a loading-contract phase with a pathfinding rewrite or mark a phase complete from synthetic evidence alone.

## Current Failure And Ownership Audit

### Source-Level Dropped-Command Hazard

1. `TutorialSystem.acknowledge_dialogue()` marks the intro elder dialogue acknowledged.
2. `release_intro_elder_home_order()` calls `refresh_tutorial_npc_home_records(true)`.
3. If the generated record count is below four, the function returns before releasing the hold or submitting a home order.
4. The acknowledgement is one-shot; there is no retained request and no retry of `release_intro_elder_home_order()`.
5. `NpcSystem.npc_is_held_by_intro_or_dialogue()` later notices that acknowledgement is complete and clears the intro hold.
6. Ordinary scheduling eventually chooses a home goal, making Mira move much later and hiding the dropped command.

### Phase 0 Real-Boot Finding

On seed `atlas-16449406`, the actual main-menu -> New Game flow produced this sequence:

1. Dialogue acknowledgement was observed at 13.183 seconds.
2. A generic active `go_home` order and route-authority request were observed at 13.200 seconds.
3. The request remained `pending_budget` with `search_budget_deferred` while Mira remained stationary.
4. First nontrivial displacement occurred at 34.967 seconds, 21.767 seconds after command observation.
5. Route authority accumulated 2,656 `pending_budget` frames before execution completed.
6. Mira cleared the player porch, traversed her own door, reached strict interior, and closed the door.

This distinguishes two contracts:

- startup must guarantee complete records so gameplay commands cannot be dropped;
- shared route authority must service an accepted ordinary NPC request within its mature latency contract.

Do not raise tutorial priority, add a Mira retry, or bypass collision to hide the second defect. If it remains after tutorial privilege removal, track and repair it as a shared route-authority issue with profiler evidence.

### Existing Architectural Problems

- `TutorialSystem` performs runtime town-record readiness checks during dialogue completion.
- `TutorialSystem` can synchronously invoke town-home construction after startup work has supposedly completed.
- Readiness is represented by a magic minimum count (`4`) instead of the scenario's required semantic home assignments.
- `TutorialSceneBuilder` supplies hand-authored home/porch fallbacks when generated records are missing.
- Tutorial spawn metadata includes `holdIntroDoor`, `tutorial`, and `requiredVisibleScripted`.
- `NpcSystem` exposes `release_intro_hold_and_order_home()` and interprets `holdIntroDoor`/`npc_hold_intro_door`.
- A one-shot gameplay command can be dropped because a dependency is pending.
- `start_new_world_staged()` returns a boolean and can continue after incomplete readiness rather than returning a structured loading failure.
- Current acceptance emphasizes eventual home arrival more than prompt command acceptance after the visible interaction.

### Acceptable Tutorial Responsibilities

The tutorial layer may:

- define named scenario actors and dialogue;
- map actors to generated home slots by semantic key or building index;
- place story props and quest markers;
- issue generic NPC commands such as `order_wait`, `order_go_to`, `order_go_home`, `order_resume_schedule`, and `cancel_order`;
- observe generic command state to advance tutorial objectives;
- apply explicit story capabilities such as temporary combat immunity when that state is not implemented as movement authority.

The tutorial layer must not:

- generate or refresh town records during dialogue or interaction callbacks;
- invent home, porch, door, or interior cells after loading;
- write route state or movement vectors;
- bypass collision-backed route authority;
- require a named actor branch in `NpcSystem` or `scripts/npc_ai/`;
- discard an intent because loading, nav data, or a budget is pending;
- depend on normal scheduling to recover a tutorial command that was never accepted.

## Target Architecture

### 1. Serializable Town Manifest

`StructureSystem` remains the owner of deterministic generated-town structure records. Add a serializable manifest/validation layer rather than a second generator.

Recommended file:

```text
scripts/world/TownRuntimeManifest.gd
```

The manifest should contain data, validation, and summaries only. It must not own movement or generate structures.

Minimum schema:

```gdscript
{
    "schemaVersion": 1,
    "townKey": "280,0",
    "seed": "atlas-...",
    "center": Vector2i(...),
    "generationRevision": 0,
    "requiredHomeKeys": [1, 2, 3],
    "homesByKey": {
        1: { ...complete home record... },
        2: { ...complete home record... },
        3: { ...complete home record... }
    },
    "doorPortalIds": [...],
    "pendingStructureOps": 0,
    "ready": true,
    "failureReasons": []
}
```

Every required home record must validate:

- stable semantic key/building index;
- town key and center;
- `homeCell`;
- `porchCell`;
- `doorCell`;
- `interiorLandingCell`;
- `homeRouteCells` containing a coherent semantic sequence;
- `interiorMinCell` and `interiorMaxCell` containing the strict interior cells;
- a generated door record with a stable portal ID;
- no duplicate semantic key;
- no assignment to a record from another town;
- deterministic equality for the same seed.

Do not store live node references in the serializable manifest. Resolve runtime nodes from stable cells/portal IDs after scene objects are created.

### 2. Scenario Requirements

Tutorial actor data should declare which generated home it needs, not fallback coordinates.

Example:

```gdscript
{
    "id": "mira",
    "name": "Mira",
    "role": "Elder",
    "homeKey": 3,
    "initialOrder": "wait",
    "initialOrderReason": "tutorial_knock_wait"
}
```

The set of required home keys must be derived from the actor specifications. Do not use `records.size() >= 4` when the scenario actually depends on keys `1`, `2`, and `3`.

### 3. Loading Gate

The loading pipeline must not emit `startup_loading_completed` until all required tutorial-town startup facts are true:

- tutorial town generation selected deterministically;
- required structure operations drained;
- town manifest validates;
- perimeter, starter shelter, story utilities, and required doors exist;
- terrain collision is published for the player spawn and required tutorial-town footprint;
- door portals are registered;
- tutorial NPCs are registered with complete home profiles from the manifest;
- initial navigation changes are drained;
- initial navigation snapshot/tiles required by startup actors are published or have a bounded, explicit readiness result;
- no startup-only NPC hold metadata remains as hidden movement authority.

If a requirement fails, keep gameplay disabled and emit `startup_loading_failed` with a structured reason. A timeout must report what remained pending; it must not silently continue.

### 4. Generic Tutorial Commands

Use the existing generic scripted-order surface unless a missing capability is proven:

- `order_wait(actor, reason)`;
- `order_go_to(actor, target, reason, ...)`;
- `order_go_home(actor, reason, speed_mode)`;
- `order_resume_schedule(actor)`;
- `cancel_order(actor, reason)`.

For the knock sequence:

1. After ordinary NPC registration, the tutorial issues `order_wait(mira, "tutorial_knock_wait")`.
2. Dialogue focus may face Mira toward the player through the generic dialogue-focus mechanism.
3. When the visible dialogue closes, the tutorial issues exactly one ordinary `order_go_home(mira, "tutorial_knock_complete")`.
4. The returned order state is recorded. Failure is surfaced; pending route work remains owned by normal route authority.
5. The tutorial does not refresh town records, clear route metadata, or manipulate door state.

Replacing a wait order with a go-home order should be sufficient. Do not add a new combined `release_tutorial_hold_and_go_home` API.

## Global Invariants

These invariants apply to every phase:

1. Tutorial NPCs are ordinary NPCs after registration.
2. Named actor IDs remain scenario data, not generic movement branches.
3. `NpcSystem` remains an integration adapter, not tutorial orchestration.
4. Route authority remains collision-backed and unchanged unless a phase produces direct evidence of a shared route defect.
5. Loading budgets may defer work but cannot discard readiness or gameplay commands.
6. New Game and Continue must both satisfy the relevant readiness contract.
7. Generated town RNG order and output remain deterministic.
8. Save changes remain additive and old saves load without the new manifest fields.
9. No hand-authored home/porch/door fallback may be used as production route truth after startup.
10. No direct movement, teleport, composed route, metadata-only arrival, or test-only flag may be used for live acceptance.
11. Do not weaken current NPC route, door, terrain, or performance tests.
12. Every phase has a Linear child issue and evidence before it is marked Done.

## Scope

### In Scope

- tutorial-town manifest requirements and validation;
- startup loading completion/failure semantics;
- generated home/door assignment readiness;
- tutorial NPC spawn profiles;
- removal of intro-specific NPC hold/order APIs and metadata;
- migration of tutorial wait/home/escort choreography to generic orders;
- New Game and Continue compatibility;
- actual-gameplay acceptance timing and evidence;
- bounded loading and runtime performance verification.

### Out Of Scope

- replacing the collision-backed route authority;
- changing route budgets without profiler evidence;
- redesigning generic town generation unrelated to manifest completeness;
- rewriting dialogue, quests, combat, or narrative content;
- visual redesign of tutorial NPCs or buildings;
- named-NPC patches.

## Sequential Execution Protocol

### Before Each Phase

1. Re-read `AGENTS.md`, this plan, `manifesto.md`, and the current phase.
2. Confirm all previous phases have passed and their Linear issues are Done.
3. Record `git branch --show-current` and `git status --short`.
4. Create or switch to the phase branch using the `codex/` prefix.
5. Move only the current Linear child issue to In Progress.
6. State the phase goal and prohibited shortcuts before editing.

### During Each Phase

1. Make only the current phase's changes plus minimum compile compatibility.
2. Preserve unrelated dirty worktree files.
3. Add focused tests before broad acceptance.
4. Do not use an eventual schedule transition as proof that a submitted command worked.
5. If a lower-phase invariant fails, stop and repair/reopen that phase.
6. Do not begin the next phase while the current phase has an unresolved gate.

### Exiting Each Phase

1. Run compile smoke.
2. Run the phase's focused checks.
3. Run headed/no-flags evidence where required.
4. Inspect reports, timelines, and screenshots manually.
5. Write a phase report under `gameplay/tutorial-town/reports/` in the documentation repository.
6. Add command, seed, report paths, capture paths, and honest residual failures to Linear.
7. Commit the phase with a behavior-focused message.
8. Merge/fast-forward into `master` only after the phase is green.
9. Mark the Linear child Done and explicitly state `Next phase allowed: yes`.

## Phase 0 - Baseline And Privilege Inventory

### Goal

Freeze the live delayed-departure symptom and enumerate every tutorial-specific behavior privilege before changing production code.

### Required Work

1. Run the actual main-menu -> New Game knock flow without gameplay-affecting flags.
2. Capture timestamps for:
   - New Game click;
   - startup loading completion;
   - door interaction;
   - dialogue acknowledgement;
   - go-home command submission, if any;
   - first route ticket/request;
   - first nontrivial Mira displacement;
   - player-porch clearance;
   - strict-home arrival;
   - home-door closure.
3. Capture the tutorial state's `homeRefresh` report at acknowledgement.
4. Capture Mira's generic order, route authority, movement, and door state without changing them.
5. Audit source usage of:
   - `tutorial`;
   - `requiredVisibleScripted`;
   - `holdIntroDoor`;
   - `npc_hold_intro_door`;
   - `npc_force_hold`;
   - `npc_rescue_stranded`;
   - `release_intro_hold_and_order_home`;
   - named IDs inside `NpcSystem` and `scripts/npc_ai/`.
6. Classify each use as presentation, quest/story state, generic capability, or prohibited movement privilege.

### Files To Inspect

- `scripts/TutorialSystem.gd`
- `scripts/TutorialSceneBuilder.gd`
- `scripts/TutorialDialogueSystem.gd`
- `scripts/TutorialRescueSystem.gd`
- `scripts/NpcSystem.gd`
- `scripts/npc_ai/**`
- `scripts/StructureSystem.gd`
- `scripts/MainCore.gd`
- `scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd`

### Strict Requirements

- No production gameplay changes.
- Diagnostic instrumentation must be passive and bounded.
- Record whether Mira was waiting because no command existed, because an order was pending, or because a route was pending.
- Do not call `order_go_home` directly from the acceptance runner.

### Exit Gate

- At least one current real-boot trace exists.
- Every tutorial privilege has an owner/classification.
- The trace distinguishes command delay from route delay.
- Phase report and Linear evidence are complete.

### Linear Child

`VOX-21 Phase 0: Baseline tutorial NPC privilege and delayed departure`

## Phase 1 - Define Manifest And Loading Contracts

### Goal

Define structured, testable contracts before moving generation or tutorial behavior.

### Required Work

1. Add `TownRuntimeManifest.gd` or an equivalent composed data/validation class.
2. Define manifest schema constants and validation result shape.
3. Add a requirements builder that derives required home keys from tutorial actor data.
4. Add a structured startup result shape:

```gdscript
{
    "ok": bool,
    "status": "ready|pending|failed",
    "reason": String,
    "manifest": Dictionary,
    "pending": Array,
    "metrics": Dictionary
}
```

5. Define generic scripted-order acceptance states separately from route states.
6. Document that `order_go_home` acceptance means the intent was retained, not that the route is already ready.
7. Add contract tests for:
   - complete manifest;
   - missing required key;
   - duplicate key;
   - wrong town key;
   - missing door/strict interior data;
   - deterministic serialization;
   - structured pending/failure summaries.

### Strict Requirements

- No generated structures or runtime behavior move yet.
- No live node references in the serializable manifest.
- No magic count readiness checks in new code.
- Validation reports all missing semantic requirements, not only the first failure.

### Exit Gate

- Manifest contracts pass deterministic tests.
- Existing compile and world-signature checks remain green.
- No production caller depends on the new contract yet.

### Linear Child

`VOX-21 Phase 1: Define town manifest and startup readiness contracts`

## Phase 2 - Make StructureSystem The Manifest Authority

### Goal

Make deterministic town generation publish one complete manifest from existing generated structure records.

### Required Work

1. Add `StructureSystem.town_manifest_status(town, requirements)` as a read/validate operation.
2. Add a bounded generation/publish operation used only during loading.
3. Reuse `town_home_records`, generated doors, structure queues, and existing deterministic RNG.
4. Remove the assumption that any nonempty record array is ready.
5. Replace `minimum_count` checks with required semantic keys.
6. Ensure deferred home records become authoritative only once their associated structure operations are published.
7. Ensure a manifest is not ready while required structure operations remain pending.
8. Detect and report deterministic generation failure when a required home site cannot be produced.
9. Prevent duplicate rebuilding when loading polls readiness repeatedly.
10. Include bounded metrics:
    - required keys;
    - published keys;
    - pending op count;
    - generation attempts;
    - elapsed loading time;
    - failure reasons.

### Files Expected To Change

- `scripts/StructureSystem.gd`
- `scripts/world/TownRuntimeManifest.gd`
- focused structure/manifest test runner and wrapper

### Strict Requirements

- Preserve seed/RNG order and world signatures.
- Do not generate homes from dialogue, NPC, or route code.
- Polling readiness must be idempotent.
- Do not create a second town/home registry.

### Exit Gate

- Known and random seeds produce deterministic manifests.
- Required home keys have complete door/interior records.
- Pending structure work prevents readiness.
- Repeated readiness calls do not duplicate blocks, doors, records, or RNG consumption.
- World-signature verification passes.

### Linear Child

`VOX-21 Phase 2: Publish complete town manifests from StructureSystem`

## Phase 3 - Enforce Startup Loading Readiness

### Goal

Prevent gameplay from starting until the tutorial town and ordinary NPC prerequisites are complete.

### Required Work

1. Refactor `TutorialSystem.start_new_world_staged()` to return a structured result instead of an optimistic boolean.
2. During loading:
   - derive scenario requirements;
   - request/poll the `StructureSystem` manifest;
   - drain required structure operations across frames;
   - display meaningful loading messages;
   - stop on structured timeout/failure.
3. Remove the post-loop `ensure_tutorial_town_home_records(4)` escape hatch.
4. Do not spawn tutorial NPCs until the manifest validates.
5. After scene objects and NPCs exist, require initial terrain collision and navigation publication before enabling gameplay.
6. Update `MainCore._run_deferred_startup_boot()` to:
   - inspect the structured tutorial startup result;
   - emit `startup_loading_failed(reason)` on failure;
   - keep player physics and gameplay input disabled;
   - never emit `startup_loading_completed` after a failed invariant.
7. Apply equivalent readiness for Continue/restore where generated tutorial state is active.
8. Add startup timeline fields for each readiness domain.

### Files Expected To Change

- `scripts/MainCore.gd`
- `scripts/TutorialSystem.gd`
- `scripts/TitleMenu.gd` only if failure presentation needs existing UI wiring
- startup smoke/loading test runners

### Strict Requirements

- No synchronous unbounded structure build in a gameplay frame.
- No gameplay enablement on timeout.
- No silent fallback home coordinates.
- Loading messages must remain responsive.
- Existing fast-boot diagnostics must be clearly excluded from gameplay acceptance and must not alter normal startup contracts.

### Exit Gate

- Main Menu -> New Game does not become playable with an incomplete manifest.
- Forced missing-manifest contract test produces visible structured failure.
- Successful loading reports zero required pending structure operations.
- Player/NPC physics starts only after readiness.
- Startup performance has no new single-frame freeze.

### Linear Child

`VOX-21 Phase 3: Gate gameplay on tutorial town readiness`

## Phase 4 - Register Tutorial Actors As Ordinary NPCs

### Goal

Spawn tutorial actors from scenario data plus the validated manifest, with no guessed home data or tutorial movement metadata.

### Required Work

1. Split `tutorial_npc_specs()` into:
   - stable scenario identity/presentation data;
   - ordinary NPC role/job/capability data;
   - semantic `homeKey` assignment;
   - optional initial generic order.
2. Resolve each `homeKey` from the validated manifest before spawning.
3. Fail startup if any required assignment cannot resolve.
4. Register through the same `NpcSystem.register_npc()` profile contract used by other NPCs.
5. Remove production fallback coordinates from `tutorial_home_record()` and related helpers.
6. Remove the second post-spawn `refresh_tutorial_npc_home_records()` assignment pass.
7. Ensure every actor's registered profile already includes:
   - home/porch/door/interior cells;
   - stable door portal ID or resolvable door cell;
   - role/job/capabilities;
   - schedule data;
   - town identity.
8. Audit `tutorial` and `requiredVisibleScripted` consumers:
   - retain tutorial identity only for dialogue/quest/presentation;
   - replace simulation privilege with generic active-order, player-proximity, or story-pin semantics;
   - do not let tutorial identity bypass LOD, routing, collision, or schedules.

### Files Expected To Change

- `scripts/TutorialSceneBuilder.gd`
- `scripts/TutorialSystem.gd`
- `scripts/NpcSystem.gd` only for generic profile compatibility
- scenario data resource/script if introduced

### Strict Requirements

- Do not patch actor IDs individually in generic code.
- Shared homes are allowed only when declared in scenario data and valid for ordinary schedules/doors.
- Spawn fallback placement may find a nearby safe physical pose, but it must not change the actor's semantic home assignment.
- No NPC may enter gameplay without a valid home profile.

### Exit Gate

- All tutorial actors register once with manifest-derived homes.
- No runtime home refresh is needed.
- Generic generated-town NPC spawning still works.
- Contract tests prove tutorial identity does not alter routing or collision behavior.

### Linear Child

`VOX-21 Phase 4: Register tutorial actors from the town manifest`

## Phase 5 - Replace Tutorial Holds With Generic Orders

### Goal

Reduce tutorial NPC choreography to ordinary commands and remove tutorial-specific movement APIs from `NpcSystem`.

### Required Work

1. At intro setup, submit a generic wait order for the knock actor after registration.
2. On visible dialogue acknowledgement, call generic `order_go_home(actor, "tutorial_knock_complete")`.
3. Record and surface the returned command state.
4. Remove:
   - `release_intro_hold_and_order_home()`;
   - `holdIntroDoor` profile state;
   - `npc_hold_intro_door` metadata;
   - the intro-specific branch in `npc_is_held_by_intro_or_dialogue()`;
   - `release_intro_elder_home_order()` readiness/generation work;
   - any post-ack home-record refresh.
5. Keep dialogue focus generic: it may face and pause an actively interacting NPC while the dialogue UI is open.
6. Audit rescue/tutorial uses of `npc_force_hold` and `npc_rescue_stranded`.
7. Replace movement holds with generic wait/cancel/go-to/go-home orders.
8. Keep non-movement story facts in tutorial/story state rather than generic NPC movement metadata.
9. Verify order replacement cancels/releases old route tickets, door holds, and traffic reservations through existing generic cancellation contracts.
10. Do not add a new tutorial-specific wrapper API with a different name.

### Files Expected To Change

- `scripts/TutorialSystem.gd`
- `scripts/TutorialSceneBuilder.gd`
- `scripts/TutorialDialogueSystem.gd`
- `scripts/TutorialRescueSystem.gd`
- `scripts/NpcSystem.gd`
- generic scripted-order tests

### Strict Requirements

- The tutorial submits one generic go-home order after acknowledgement.
- That order is never conditioned on record generation; records are already ready.
- Generic NPC code contains no named tutorial actor checks.
- Do not change route budgets to make the command appear faster.
- Do not directly move, snap, or teleport the actor during the act phase.

### Exit Gate

- Source audit finds none of the removed intro movement privileges.
- Generic order tests prove wait -> go_home replacement and cancellation cleanup.
- Actual-gameplay trace shows command submission promptly after acknowledgement.
- Mira begins generic home execution without waiting for ordinary schedule selection.
- Non-tutorial NPC scripted orders remain green.

### Linear Child

`VOX-21 Phase 5: Replace tutorial NPC holds with generic orders`

## Phase 6 - Save, Continue, And Compatibility

### Goal

Ensure the new startup and ordinary-NPC contracts survive saves, Continue, and older data.

### Required Work

1. Decide whether the manifest is regenerated deterministically or saved as an additive snapshot/reference.
2. Prefer deterministic regeneration plus validation unless runtime edits require additive manifest state.
3. Preserve existing NPC home assignments from saves when valid.
4. Validate saved assignments against the regenerated town without overwriting valid player progress.
5. Migrate old saves that lack manifest version fields.
6. Restore tutorial order state safely:
   - before acknowledgement: ordinary wait order;
   - after acknowledgement and before strict-home arrival: retained/reissued generic home intent only if no equivalent active order exists;
   - after arrival: resume saved schedule/state without replaying the knock command.
7. Make restoration idempotent across repeated Continue loads.
8. Do not duplicate NPCs, doors, rewards, dialogue completion, or orders.

### Strict Requirements

- Save schema changes are additive.
- Old saves load without named migration hacks.
- Continue does not rebuild structures over player edits.
- Continue does not replay completed tutorial dialogue or rewards.
- A pending generic home intent survives save/load as an intent, not as doctored route metadata.

### Exit Gate

- New save round trip passes.
- Old save without manifest fields passes.
- Save during knock wait, after acknowledgement, during route, and after home arrival all restore correctly.
- Duplicate-load/idempotency tests pass.

### Linear Child

`VOX-21 Phase 6: Preserve tutorial town readiness through save and Continue`

## Phase 7 - Live Acceptance And Performance

### Goal

Prove the architecture in normal gameplay and ensure loading correctness does not create unacceptable stalls.

### Required Focused Commands

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-door-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both
```

Add a dedicated loading/manifest wrapper if no existing runner can prove those contracts cleanly.

### Required Live Runs

1. Known failing/recurrent seed when available.
2. At least three fresh random New Game seeds.
3. One Continue run from a save created during tutorial progress.
4. Full unflagged tutorial playthrough.
5. Normal runtime performance observation covering startup and first tutorial movement.

### Actual-Gameplay Timing Evidence

The headed runner must record:

- `startup_loading_completed` timestamp;
- dialogue acknowledgement timestamp;
- generic go-home order submission timestamp;
- order state and generation;
- first route request timestamp/classification;
- first movement timestamp;
- porch-clear timestamp;
- strict-home timestamp;
- door-open, crossing-clearance, and door-close timestamps.

Recommended acceptance thresholds, to be confirmed from baseline performance rather than weakened after failures:

- go-home order submitted in the same frame or next process frame after acknowledgement;
- order retained immediately (`PENDING` or `ACTIVE`, never absent/dropped);
- first route work begins within 1 second under normal startup load;
- visible departure begins within 5 seconds;
- no unbounded `pending_budget` or `pending_nav_data`;
- strict-home arrival and door closure complete through ordinary systems.

### Screenshot Requirements

- main menu before New Game;
- loading screen with tutorial-town readiness step;
- knock dialogue acknowledged;
- actor visibly leaving player porch;
- actor approaching own home;
- own door open before crossing;
- actor strict inside and clear of threshold;
- own door closed after clearance.

### Performance Evidence

Report:

- total startup loading duration;
- longest loading step;
- worst gameplay frame after enabling input;
- p95/p99/max frame time;
- structure queue peak;
- nav publication peak;
- whether any work moved from loading into the first playable seconds.

### Strict Requirements

- No `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, god mode, direct service call, teleport, or fixture-only state in live acceptance.
- Isolated save path is allowed only when documented as save isolation, not gameplay behavior.
- The actual-gameplay runner must pass `assert-npc-acceptance-runner-clean.ps1`.
- Synthetic manifest/command tests support but do not replace live evidence.
- A passing single seed is insufficient.

### Exit Gate

- All focused checks pass.
- Known and fresh live runs pass.
- Screenshots and timelines were manually inspected.
- Startup remains responsive and performance regressions are within established standards.
- Any unrelated failure is separately tracked rather than hidden.

### Linear Child

`VOX-21 Phase 7: Verify unflagged tutorial loading and ordinary NPC behavior`

## Phase 8 - Cleanup, Documentation, And Release

### Goal

Remove obsolete privilege paths and leave one understandable production contract.

### Required Work

1. Delete obsolete home refresh/fallback helpers that have no valid non-loading caller.
2. Delete tutorial-specific NPC movement metadata and APIs.
3. Remove temporary diagnostics or reduce permanent telemetry to bounded useful fields.
4. Add static audit coverage preventing reintroduction of:
   - named NPC movement branches in generic systems;
   - tutorial-time home generation;
   - `release_intro_hold_and_order_home`-style combined APIs;
   - production fallback home coordinates;
   - loading completion with incomplete manifest.
5. Update architecture docs and phase reports.
6. Re-run full test and live acceptance matrices.
7. Update VOX-21 with final commit, commands, reports, captures, and residual risks.

### Strict Requirements

- Do not retain dead compatibility paths without an identified caller and removal date.
- Do not mark VOX-21 Done from contract tests alone.
- Do not claim the broader NPC pathfinding project complete unless its own controlling plan gates are satisfied.

### Exit Gate

- Source audit is clean.
- Full regression suite is green or unrelated failures are explicitly tracked.
- Real gameplay confirms prompt departure and strict-home completion.
- Documentation matches production ownership.
- VOX-21 is Done only after final evidence is attached.

### Linear Child

`VOX-21 Phase 8: Remove obsolete tutorial NPC privilege and close acceptance`

## Required Reports

Create these reports as phases complete:

```text
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-0-baseline-and-privilege-audit.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-1-manifest-contract.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-2-structure-manifest-authority.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-3-loading-gate.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-4-tutorial-actor-registration.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-5-generic-tutorial-orders.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-6-save-continue-compatibility.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-7-live-acceptance.md
https://github.com/lakam99/voxel-godot-docs/blob/main/gameplay/tutorial-town/history/phase-8-release-report.md
```

Each report must include:

- phase objective;
- branch and commit;
- files changed;
- contract decisions;
- commands run;
- reports/captures inspected;
- pass/fail results;
- known residual risks;
- Linear issue status;
- `Next phase allowed: yes|no`.

## Definition Of Done

This project is complete only when all of the following are true:

- the tutorial town is complete and validated before gameplay is enabled;
- required home and door records are not generated or refreshed from dialogue/runtime NPC behavior;
- tutorial actor home assignments derive from the generated manifest without production fallback guesses;
- tutorial movement choreography uses only generic NPC commands;
- `NpcSystem` and `scripts/npc_ai/` contain no tutorial-intro or named-NPC movement privilege;
- the post-knock go-home command is submitted and retained immediately after acknowledgement;
- Mira leaves promptly and completes the ordinary collision-backed home/door flow;
- other tutorial and non-tutorial NPCs retain ordinary schedules, jobs, doors, and saves;
- New Game and Continue both pass;
- live unflagged random-seed evidence and performance evidence are attached;
- every Linear phase issue and VOX-21 are updated honestly.
