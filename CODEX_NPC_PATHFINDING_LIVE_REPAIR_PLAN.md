# Codex Repair Specification: Real Tutorial Playthrough, Mira Return-Home, and Niko Forager Recovery

**Project:** Godot Procedural Voxel Game  
**Branch root:** current `master` after the completed NPC pathfinding merge  
**Document status:** mandatory repair specification  
**Primary goal:** restore real gameplay NPC behavior without another architecture rewrite  
**Core proof:** a real automated tutorial playthrough from knock to morning foraging, using real player inputs and real NPC pathfinding

---

## 0. Directive To Codex

Read this document before changing code. This is a repair pass, not a new pathfinding redesign.

The architecture may be large, but the live failures are concrete:

1. Niko/forager selection can crash because `SmartObjectService.live_registration_node_3d()` evaluates `node is Node3D` on a previously freed instance.
2. Mira moves by inching because active NPC movement is still coupled to a throttled high-level NPC update budget.
3. Tutorial acceptance tests currently bypass real gameplay by directly flipping tutorial/state methods instead of walking the player, opening the real door, acknowledging real dialogue, placing real repair blocks, sleeping, and observing morning NPC behavior.
4. Mira has a tutorial-specific movement speed branch (`holdIntroDoor -> speed = 20.0`) that must not exist in a physically authoritative NPC stack.
5. Foragers must select live smart-object resources, route to reachable approach slots, and interact only after real arrival. They must never walk into a wall, harvest through geometry, or crash on stale resource registrations.

Do not implement another pathfinding architecture. Do not weaken the existing focused suites. Do not hide failures by flipping flags, teleporting actors, setting tutorial completion state, or bypassing player/NPC interaction APIs.

The winning fix is small and strict:

1. Add the real playthrough test and make it fail on the current build.
2. Fix stale smart-object lifetime.
3. Separate every-frame active movement from staggered high-level brain planning.
4. Replace tutorial movement hacks with explicit scripted orders backed by normal NPC pathfinding.
5. Prove the actual tutorial sequence and morning foraging behavior with an automated playthrough.
6. Preserve every existing focused and broad regression gate.

---

## 1. Current Failure Evidence To Treat As Blocking

### 1.1 Freed smart-object instance

Observed live error:

```text
SCRIPT ERROR: Left operand of 'is' is a previously freed instance.
    at: SmartObjectService.live_registration_node_3d (res://scripts/npc_ai/interactions/SmartObjectService.gd:832)
```

Relevant call chain:

```text
SmartObjectService.live_registration_node_3d
SmartObjectService.registration_drop_value
SmartObjectService.registration_matches_candidate_filters
SmartObjectService.collect_candidate_object_ids
SmartObjectService.candidate_object_ids_for_query
SmartObjectService.query_resource_nodes
NpcSemanticGoalPlanner.indexed_resource_props
NpcSemanticGoalPlanner.add_resource_prop_candidates
NpcSemanticGoalPlanner.choose_job_target
NpcPlanExecutor._update_forager_goal
```

The current dangerous pattern is conceptually:

```gdscript
var node = registration.node
if node is Node3D:
    return node as Node3D
```

This is unsafe when `node` is a freed Godot instance. Every path must validate with `is_instance_valid(node)` before any `is`, cast, `get_meta`, `position`, `global_position`, or slot/scoring access.

### 1.2 Movement cadence bug

`NpcSystem.update_npcs()` currently budgets whole NPC updates:

```gdscript
var budget := update_count
if update_count > 24:
    budget = 4
elif update_count > 16:
    budget = 6
```

Because route movement is still advanced through the same `update_npc()` / `NpcPlanExecutor` path, skipped brain updates also skip physical progress. This explains Mira inching forward every few frames and then stalling.

Required invariant:

> High-level thinking may be staggered. Active physical movement must run every physics/update tick for every active, non-abstract NPC with a route, scripted order, door action, return-home order, or job movement.

### 1.3 Tutorial tests currently bypass real gameplay

The broad playtest contains direct calls such as:

```gdscript
tutorial_system.on_door_opened(null)
tutorial_system.interact_with(mira)
tutorial_system.complete_step(...)
tutorial_system.on_block_placed(block)
tutorial_system.on_bed_used()
inventory_system.add_item("logs", 24)
inventory_system.add_item("stones", 16)
```

Those calls can remain as narrow contract tests only if clearly named as state-contract tests. They are not proof that the real tutorial works.

The new acceptance gate must use real player-facing actions.

### 1.4 Tutorial-specific movement hack

`NpcPlanExecutor._execute_home()` contains a special speed branch similar to:

```gdscript
var speed := 6.4
if bool(entry.get("holdIntroDoor", false)):
    speed = 20.0
```

Remove this as movement behavior. Tutorial NPCs may receive scripted orders and priority. They may not receive illegal speed, teleport, or custom movement bypasses.

---

## 2. Non-Negotiable Repair Rules

These rules apply to every phase.

1. Do not redesign the whole pathfinding stack.
2. Do not reintroduce direct route transform movement.
3. Do not teleport as recovery.
4. Do not bypass doors, traffic, smart objects, or the shared motor.
5. Do not weaken, skip, or rename existing tests to make the build green.
6. Do not accept headless synthetic tests as proof of tutorial feel.
7. Do not call tutorial internals from the real playthrough runner.
8. Do not add more broad playtest cheating and call it coverage.
9. Do not use `canFight` as guard duty.
10. Do not count porch, threshold, roof, or exterior edge as indoors.
11. Do not allow smart-object queries to return freed, stale, depleted, missing, or invalid nodes.
12. Do not let active NPC movement depend on brain update budget.
13. Do not let resource effects happen from a timer unless physical approach, reservation, and action completion are valid.
14. Do not merge a phase without its report and both branch/master gates.

---

## 3. Branch And Report Protocol

Use one repair phase per branch.

Branch naming:

```text
npc-pathfinding/repair-00-red-real-playthrough
npc-pathfinding/repair-01-smart-object-lifetime
npc-pathfinding/repair-02-active-motion-cadence
npc-pathfinding/repair-03-scripted-orders
npc-pathfinding/repair-04-real-tutorial-playthrough
npc-pathfinding/repair-05-forager-recovery
npc-pathfinding/repair-06-final-cleanup-gate
```

For each phase:

1. Start from current green `master` unless `master` is already red from this repair; if red, fix the red state first.
2. Inspect `git status --short` and preserve user work.
3. Create the phase branch.
4. Implement only the phase scope.
5. Run the focused phase runner repeatedly.
6. Run every affected NPC focused runner.
7. Run the full all-runner gate before merge.
8. Write `docs/npc_pathfinding/repair/PHASE_RXX_REPORT.md`.
9. Commit implementation and report.
10. Merge with `--no-ff` into `master`.
11. Rerun the full all-runner gate on merged `master`.
12. Do not continue while `master` is red.

Each phase report must include:

- branch, base commit, final commit, merge commit;
- exact failure reproduced or prevented;
- files changed;
- implementation summary;
- focused test commands and reports;
- full all-runner evidence on branch and merged `master`;
- stdout/stderr script-error scan;
- forbidden shortcut search results;
- manual/live-observation notes if applicable;
- final pass/fail verdict.

---

## 4. Phase R00 — Add The Red Real Tutorial Playthrough Runner

**Branch:** `npc-pathfinding/repair-00-red-real-playthrough`  
**Primary output:** a real playthrough test that fails on the current broken behavior

### 4.1 Add files

Create:

```text
tools/npc/run-real-tutorial-playthrough.ps1
scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
scenes/testing/npc/NpcRealTutorialPlaythroughTest.tscn
```

Register the new runner in:

```text
tools/test-runner-registry.json
tools/npc/npc-suite-registry.json
```

Add docs/report directory if missing:

```text
docs/npc_pathfinding/repair/
```

### 4.2 Runner requirements

The runner must instantiate the real `Main.tscn` and run with deterministic seed `atlas-1492` by default.

It may:

- reset/start a deterministic tutorial world;
- use `PlayerController.automated_input` or the existing player automation layer;
- move the player by simulated input;
- aim the real camera;
- dispatch real interact, build/place, chest, dialogue, and bed input events;
- inspect state after real actions;
- use deterministic setup only before gameplay starts.

It must not:

- call `tutorial_system.on_door_opened(...)`;
- call `tutorial_system.interact_with(...)`;
- call `tutorial_system.complete_step(...)`;
- call `tutorial_system.on_block_placed(...)`;
- call `tutorial_system.on_bed_used(...)`;
- directly set tutorial flags;
- directly add tutorial inventory after the playthrough begins;
- teleport the player as a substitute for walking;
- teleport NPCs;
- call `npc_system.move_npc(...)` from the test;
- call `safe_place_npc(...)` after gameplay begins;
- count porch/threshold as inside;
- assert only final state while ignoring movement timeline.

### 4.3 Static self-guard

The runner must fail if its own source contains forbidden calls.

Add a check equivalent to:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd
```

Expected result for the real runner: zero matches, except documented pre-start deterministic setup if absolutely unavoidable.

### 4.4 Required first failing scenario

Test ID:

```text
npc_tutorial_real_knock_to_morning_foragers
```

Initial run on current broken code should reproduce at least one of:

- freed smart-object instance error;
- Mira does not return home;
- Mira moves at non-profile speed;
- Mira stalls/inches due to brain budget;
- Niko/forager walks into wall;
- morning forager target selection crashes or selects stale node;
- night schedule matrix is wrong;
- real input path fails to open door or progress dialogue.

Do not fix behavior before this red test exists.

### 4.5 R00 acceptance

- The new runner exists and runs.
- It uses real player-facing actions.
- It fails honestly on current broken behavior.
- The failure report includes player timeline, Mira timeline, NPC schedule matrix, script-error scan, and last route/smart-object state for Niko/foragers.
- Existing tests are not weakened.

---

## 5. Phase R01 — Fix SmartObjectService Stale Node Lifetime

**Branch:** `npc-pathfinding/repair-01-smart-object-lifetime`  
**Primary target:** `scripts/npc_ai/interactions/SmartObjectService.gd`

### 5.1 Required implementation

Fix every registration/node access path so a freed object is never type-checked, cast, scored, filtered, or positioned.

`live_registration_node_3d(registration)` must follow this shape:

```gdscript
func live_registration_node_3d(registration) -> Node3D:
    if registration == null:
        return null
    var node = registration.node
    if node == null:
        return null
    if not is_instance_valid(node):
        mark_registration_stale(registration, "freed_node")
        return null
    if not (node is Node3D):
        mark_registration_stale(registration, "not_node_3d")
        return null
    return node as Node3D
```

Rules:

1. Store `registration.node` in a local variable before checks.
2. Check `node == null` first.
3. Check `is_instance_valid(node)` before any `is Node3D`.
4. Never call `get_meta`, `has_meta`, `global_position`, `position`, `is_inside_tree`, or slot/candidate logic on an invalid node.
5. Stale registrations must be removed from availability indexes and query caches.
6. Reservations owned by stale/deleted objects must be released.
7. Object revision and query cache revision must increment.
8. Candidate queries must skip stale IDs and continue without throwing.

### 5.2 Add lifecycle removal hook

On every smart-object/resource registration:

- connect to `tree_exiting` or equivalent lifecycle signal;
- on exit/free, call a single authoritative removal method;
- clear `registration.node`;
- mark unavailable/depleted as appropriate;
- release reservations;
- remove from indexed buckets;
- invalidate candidate query cache.

Required methods or equivalents:

```gdscript
notify_object_removed(object_id, reason := "node_removed")
mark_registration_stale(registration, reason := "stale_node")
registration_is_live(registration) -> bool
```

### 5.3 Focused tests

Add cases to interaction or smart-object suite:

```text
npc_interaction_stale_registered_resource_ignored
npc_interaction_queue_free_resource_query_no_script_error
npc_interaction_stale_resource_unindexed
npc_interaction_stale_resource_reservation_released
npc_interaction_query_cache_invalidates_on_resource_removal
npc_interaction_forager_query_after_harvest_no_crash
```

Each case must scan stdout/stderr for:

```text
SCRIPT ERROR
previously freed instance
Invalid get index
Invalid call
ObjectDB instances leaked
```

Treat any match as failure unless a known unrelated ObjectDB shutdown warning is already documented and not caused by this phase.

### 5.4 R01 acceptance

- Niko/forager resource queries cannot crash on freed nodes.
- Query results contain only live `Node3D` objects or stable metadata-backed candidates proven valid.
- Depleted/removed resources are not returned as available.
- Existing interaction, behavior, route, repair, and broad playtest gates remain green.

---

## 6. Phase R02 — Separate Active Physical Movement From Brain Budget

**Branch:** `npc-pathfinding/repair-02-active-motion-cadence`  
**Primary targets:**

```text
scripts/NpcSystem.gd
scripts/npc_ai/NpcAutonomySystem.gd
scripts/npc_ai/behavior/NpcPlanExecutor.gd
scripts/npc_ai/movement/NpcRouteMovementController.gd
```

### 6.1 Problem

The current update budget skips whole NPC updates. That skips not only high-level thinking but also active route movement.

This causes:

- Mira inching every few frames;
- scripted NPCs stalling mid-town;
- morning NPCs not leaving smoothly;
- possibly delayed door/traffic release.

### 6.2 Required architecture correction

Split NPC updates into two lanes:

```text
Every frame / physics tick:
  active physical movement, route following, door crossing, traffic wait advancement, motor state, visual state

Budgeted/staggered:
  high-level goal selection, task replanning, expensive semantic target selection, long route planning job creation
```

### 6.3 Required implementation details

1. Add an every-active-NPC movement pass before or after the budgeted brain pass.
2. Every active, non-abstract NPC with any active movement intent must receive a motion tick every frame.
3. High-level brain updates remain budgeted.
4. Existing active route/corridor/order state must continue on non-brain frames.
5. `NpcPlanExecutor` must expose or preserve a current movement/action intent that can be advanced without reselecting goals.
6. Door traversal/crossing actions must continue while brain is skipped.
7. Traffic reservations and waits must continue while brain is skipped.
8. Visual facing/animation must use actual motor result, not desired but skipped route state.
9. Do not recompute all goals every frame.
10. Do not solve this by increasing budget to all NPCs.

### 6.4 Required instrumentation

Add counters/fields:

```text
npc_brain_updates
npc_motion_updates
npc_motion_skipped_reason
npc_last_motion_tick
npc_active_route_motion_ticks
npc_scripted_order_motion_ticks
npc_door_action_motion_ticks
npc_brain_budget_skipped
```

Per NPC debug should show:

- last brain tick;
- last motion tick;
- current order/goal;
- active route status;
- whether movement was advanced this frame.

### 6.5 Focused tests

Add cases:

```text
npc_motor_every_active_actor_motion_tick_32_npcs
npc_behavior_brain_budget_does_not_skip_route_motion
npc_behavior_scripted_order_moves_while_brain_skipped
npc_behavior_mira_no_inching_after_dialogue
npc_behavior_morning_departures_not_brain_starved
npc_traffic_door_crossing_continues_while_brain_skipped
```

The Mira case may initially use a synthetic scripted order. The real tutorial runner will prove the full live sequence later.

### 6.6 R02 acceptance

- With 24+ NPCs, every active moving NPC receives motion ticks every frame.
- Brain update count remains budgeted.
- Mira-like scripted movement progresses smoothly, not in intermittent bursts.
- No new performance spike from full high-level replanning.
- Existing focused and broad gates remain green.

---

## 7. Phase R03 — Replace Tutorial Movement Hacks With Scripted Orders Backed By Normal Pathfinding

**Branch:** `npc-pathfinding/repair-03-scripted-orders`

### 7.1 Required scripted order API

Implement one simple explicit order interface backed by the normal NPC stack:

```gdscript
order_wait(actor_id, reason)
order_go_to(actor_id, target, reason, arrival_radius := -1.0)
order_go_home(actor_id, reason)
order_face_player(actor_id, reason)
order_resume_schedule(actor_id)
cancel_order(actor_id, reason)
```

This API must route through:

```text
goal/order -> task/action -> route planner -> door/traffic/smart object -> corridor follower -> shared motor
```

It must not bypass with transforms or special movement loops.

### 7.2 Scripted order result states

Every scripted order must end in one of:

```text
PENDING
ACTIVE
ARRIVED
CANCELLED
FAILED_UNREACHABLE
FAILED_BLOCKED
FAILED_TIMEOUT
FAILED_TARGET_GONE
FAILED_INTERNAL
```

Each failure must include a reason and route/action diagnostic.

### 7.3 Mira-specific behavior

Required tutorial flow behavior:

1. Before the player opens the starter door, Mira may wait near the door or at a scripted holding anchor.
2. While waiting, Mira may face the player or door.
3. The hold must not mutate route speed or movement physics.
4. When the player opens the door through the real door interaction path, Mira dialogue begins.
5. While dialogue is open, Mira faces the player and does not wander.
6. When the player acknowledges/closes dialogue through the real HUD action, Mira receives:

```text
order_go_home("intro_acknowledged_return_home")
```

7. Mira walks home at normal NPC profile speed.
8. Mira uses the regular route planner, doors, traffic, and motor.
9. Mira reaches their registered home interior.
10. Mira resumes normal schedule after arrival.

### 7.4 Remove or neutralize hacks

Remove tutorial-specific movement behavior such as:

```gdscript
if holdIntroDoor:
    speed = 20.0
```

`holdIntroDoor` may remain only as a tutorial state/hold reason before dialogue acknowledgement. It must not change movement speed, skip route planning, or mark home arrival.

### 7.5 Tests

Add cases:

```text
npc_behavior_scripted_order_go_home_uses_route_stack
npc_behavior_scripted_order_normal_profile_speed
npc_behavior_scripted_order_no_transform_write
npc_behavior_mira_dialogue_ack_releases_go_home_order
npc_behavior_mira_home_arrival_requires_interior
npc_behavior_hold_intro_door_not_speed_override
```

Speed assertion:

```text
sampled_applied_speed <= traversal_profile.max_walk_speed * 1.15
```

Allow short acceleration/physics tolerances, but not a 20.0-speed spike.

### 7.6 R03 acceptance

- Tutorial/story NPC movement is expressible as simple orders.
- Orders use normal pathfinding/motor/doors/traffic.
- Mira no longer has special speed hacks.
- Mira synthetic go-home order reaches interior at regular pace.
- Existing story/tutorial tests remain green.

---

## 8. Phase R04 — Implement The Real Tutorial Full Playthrough Acceptance Gate

**Branch:** `npc-pathfinding/repair-04-real-tutorial-playthrough`  
**Primary test ID:** `npc_tutorial_real_knock_repair_sleep_morning_foragers`

This is the central proof. Do not merge this phase unless this runner passes honestly.

### 8.1 Required sequence

The runner must execute this exact gameplay sequence:

1. Start deterministic new tutorial world with seed `atlas-1492`.
2. Confirm the opening knock loop/state is active.
3. Physically move the player to the starter door using real movement input.
4. Aim the real camera/cursor at the starter door.
5. Dispatch the actual interact/right-click input.
6. Assert the shared door authority opens the real door.
7. Assert tutorial door-open state was reached only through real door interaction.
8. Assert Mira dialogue begins in the actual HUD/dialogue system.
9. Acknowledge/close the dialogue through the real HUD input path.
10. Assert Mira is released from intro/dialogue hold.
11. Observe Mira returning home:
    - progresses every active movement window;
    - no wall penetration;
    - no stuck collision loop;
    - no teleport;
    - no special speed spike;
    - uses regular route stack;
    - enters own home interior, not porch/threshold.
12. During this nighttime state, assert:
    - assigned guards are outside on duty or en route to duty;
    - all non-duty NPCs are inside assigned interiors/shelters;
    - porch/threshold/roof/exterior edge is failure.
13. Drive player to the repair chest or repair material source through real movement.
14. Open chest/utility through the real interaction path.
15. Obtain required repair materials through real gameplay affordances. If the tutorial intentionally grants materials from the chest, use that real chest flow. Do not add inventory directly.
16. Place repair blocks/torches with real build/place input.
17. Assert perimeter repair completes from actual placed blocks.
18. Drive player to bed.
19. Interact with bed through real input.
20. Assert sleep is blocked before repair and succeeds after repair if the design requires that gate.
21. Wake at morning/day.
22. Assert NPCs leave homes at regular pace:
    - workers open/use real doors;
    - non-guards do not remain stuck indoors forever;
    - no one wall-bumps at their own house.
23. Assert Niko/foragers:
    - select a live smart-object berry/forage source;
    - reserve it;
    - route to a valid approach slot;
    - do not walk into a wall;
    - harvest only through smart-object authority;
    - carry/eat/deposit according to design;
    - recover if a resource disappears.
24. Assert no script errors or freed-instance warnings.

### 8.2 Required report contents

The JSON/Markdown report must include:

```text
seed
branch
git commit
player position timeline
door state timeline
Mira dialogue state timeline
Mira route/order timeline
Mira speed samples
Mira final home/interior status
night guard/non-guard matrix
repair target placement proof
sleep transition proof
morning NPC departure matrix
Niko selected object id
Niko reservation id
Niko approach slot
Niko route status/reason
Niko harvest/eat/deposit result
script-error scan
forbidden-call self-scan
```

### 8.3 Forbidden shortcuts in this runner

The real playthrough runner must not contain or indirectly call:

```text
on_door_opened
interact_with(
complete_step
on_block_placed
on_bed_used
intro_.*=
inventory_system.add_item
player.global_position =
npc_system.move_npc
safe_place_npc
```

If a helper wraps a real input action, document it and prove it enters the same path actual gameplay uses.

### 8.4 R04 acceptance

- The real tutorial playthrough passes from knock to morning foraging.
- No direct tutorial flag flipping.
- No direct inventory injection after gameplay begins.
- No direct NPC movement from the test.
- Mira returns home at normal pace.
- Night matrix is correct.
- Perimeter repair and sleep work through real actions.
- Morning departures and Niko foraging work.
- Existing broad playtest still passes.

---

## 9. Phase R05 — Hardening Forager And Resource Behavior Against The Real Runner

**Branch:** `npc-pathfinding/repair-05-forager-recovery`

Use this phase only for defects revealed by R04 around Niko/foragers, resource target choice, or job loops.

### 9.1 Required behavior

Foragers must:

1. select only live smart-object candidates;
2. route to a registered approach slot, not collider center;
3. reject approach slots that are unreachable, wall-separated, wrong vertical layer, or blocked by closed doors without an action;
4. reserve before harvesting;
5. require physical proximity to the approach slot;
6. require line-of-action / no wall or floor obstruction;
7. release reservation on failure/interruption;
8. handle target removal/depletion with `target_gone` and reselect;
9. mark per-NPC unreachable target IDs for bounded retry suppression;
10. stop using raw outside-town position as proof of gathering.

### 9.2 Required implementation rules

`NpcSemanticGoalPlanner` and `SmartObjectService` must cooperate like this:

```text
candidate query -> live object IDs -> live slots -> route-scored approach slot -> reservation -> physical arrival -> action effect
```

Do not let any of these imply success alone:

- being outside town;
- having a target ID;
- being near the object center;
- having a timer elapsed;
- having a route that is partial or blocked;
- having stale metadata from a freed prop.

### 9.3 Tests

Add cases:

```text
npc_interaction_forager_live_candidate_only
npc_interaction_forager_reachable_approach_slot
npc_interaction_forager_no_wall_bump_on_morning_exit
npc_interaction_forager_target_gone_reselects
npc_interaction_forager_route_blocked_marks_target_unreachable
npc_interaction_forager_harvest_requires_reservation_and_arrival
npc_interaction_niko_full_forage_cycle_morning
```

### 9.4 R05 acceptance

- Niko leaves home in the morning.
- Niko reaches a real forage source.
- Niko does not walk into a wall.
- Niko completes at least one real forage cycle.
- Removed/depleted resources do not crash or remain queryable as available.
- Existing job/forager broad playtest assertions pass.

---

## 10. Phase R06 — Replace False-Green Tutorial Assertions And Final Gate

**Branch:** `npc-pathfinding/repair-06-final-cleanup-gate`

### 10.1 Reclassify old tutorial shortcuts

Existing tests that call tutorial internals must be renamed or documented as contract-only tests.

Allowed examples:

```text
tutorial_contract_door_open_state_transition
tutorial_contract_repair_completion_state_transition
tutorial_contract_bed_use_state_transition
```

They must not be described as gameplay playthrough proof.

### 10.2 Real playthrough becomes mandatory gate

Add the new runner to the repository-wide all-runner registry.

The final all-runner must include:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -Seed atlas-1492
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
.\tools\npc\run-npc-motor-tests.ps1 -TimeMode Both
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
.\tools\run-npc-navigation-tests.ps1
.\tools\story\run-story-playtest.ps1
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-all-test-runners.ps1
```

### 10.3 Final static searches

Run and report:

```powershell
rg -n "on_door_opened|interact_with\(|complete_step|on_block_placed|on_bed_used|intro_.*=|inventory_system\.add_item|player\.global_position\s*=|npc_system\.move_npc|safe_place_npc" scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd

rg -n "speed\s*=\s*20\.0|holdIntroDoor.*speed|speed.*holdIntroDoor" scripts/NpcSystem.gd scripts/npc_ai scripts/Tutorial*.gd

rg -n "node is Node3D|as Node3D|get_meta|global_position|position" scripts/npc_ai/interactions/SmartObjectService.gd

rg -n "budget = 4|budget = 6|npc_update_cursor" scripts/NpcSystem.gd scripts/npc_ai
```

The third and fourth searches are not expected to be zero. They must be inspected:

- `SmartObjectService` matches must prove `is_instance_valid()` happens before unsafe node use.
- NPC update budget matches must prove only brain planning is throttled, not active physical movement.

### 10.4 Final acceptance report

Create:

```text
docs/npc_pathfinding/repair/FINAL_LIVE_REPAIR_ACCEPTANCE_REPORT.md
```

It must include:

- real tutorial runner report path and result;
- player action timeline;
- Mira home-return proof;
- night duty/interior matrix;
- repair/sleep proof;
- morning departure proof;
- Niko/forager full cycle proof;
- script-error scan;
- forbidden shortcut scans;
- branch all-runner evidence;
- merged `master` all-runner evidence;
- no unapproved deviations.

### 10.5 R06 acceptance

- The live failure is fixed.
- The real tutorial playthrough passes.
- The old false-green tutorial path is no longer accepted as gameplay proof.
- No freed-instance errors.
- No Mira inching/stalling.
- No Mira speed hack.
- No Niko wall-bump or stale-resource crash.
- Night guard/non-guard schedule is correct.
- Morning NPC departure and foraging behavior are correct.
- Full all-runner passes on branch and merged `master`.

---

## 11. Implementation Notes And Expected Touch Points

Likely files to inspect/change:

```text
scripts/npc_ai/interactions/SmartObjectService.gd
scripts/npc_ai/interactions/SmartObjectRegistration.gd
scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd
scripts/npc_ai/behavior/NpcPlanExecutor.gd
scripts/npc_ai/NpcAutonomySystem.gd
scripts/npc_ai/movement/NpcRouteMovementController.gd
scripts/NpcSystem.gd
scripts/TutorialSystem.gd
scripts/TutorialDialogueSystem.gd
scripts/TutorialSceneBuilder.gd
scripts/GameHud.gd
scripts/PlayerController.gd
scripts/PlaytestRunner.gd
scripts/testing/npc/NpcAutonomyTestRunner.gd
tools/test-runner-registry.json
```

Likely files to avoid large redesigns in unless directly needed:

```text
scripts/npc_ai/routing/HierarchicalRoutePlanner.gd
scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd
scripts/npc_ai/traffic/TrafficReservationService.gd
scripts/npc_ai/interactions/DoorPortalService.gd
```

Touch those only if the real playthrough proves the defect is there.

---

## 12. Debugging Guidance

### 12.1 For the freed-instance error

Do not stop at fixing only `live_registration_node_3d()`. Search every SmartObjectService path where a registration node is used.

Look for unsafe patterns:

```gdscript
registration.node is Node3D
registration.node.get_meta(...)
registration.node.global_position
registration.node.position
registration.node.is_inside_tree()
registration.node.name
registration.node.get_instance_id()
```

Every one must be guarded by a live-node helper.

### 12.2 For Mira movement

Record these values every few frames during the post-dialogue return-home segment:

```text
Mira position
Mira route status/reason
Mira current order kind
Mira brain tick count
Mira motion tick count
Mira desired velocity
Mira applied velocity
Mira actual displacement
Mira blocker classification
Mira speed sample
```

Failure patterns:

- motion tick count increments only every few frames: update cadence bug;
- desired velocity nonzero but applied velocity zero: collision/route/traffic issue;
- speed sample > profile max tolerance: tutorial speed hack;
- route reason stuck on door/traffic: door/traffic release issue;
- final location porch/threshold: interior truth issue.

### 12.3 For Niko morning foraging

Record:

```text
selected object id
object kind
node validity
resource depleted state
slot id
approach position
route status/reason
reservation id
blocked contact category
arrival state
action effect result
inventory/hunger delta
```

Failure patterns:

- stale node ID selected: SmartObjectService index bug;
- route status `no_goal_span`/`blocked`: bad approach slot or nav semantics;
- wall contact while target remains active: approach/route candidate bug;
- effect without arrival/reservation: job authority bug.

---

## 13. Do Not Declare Success Until This Exact User Story Works

This live story must work in the actual game and in the real automated runner:

```text
Player hears knock.
Player walks to the door.
Player opens the real door.
Mira dialogue starts.
Player acknowledges dialogue.
Mira walks home smoothly at normal NPC pace.
It is night: guards are on duty, everyone else is indoors.
Player completes perimeter repair through real placement.
Player sleeps.
Morning arrives.
NPCs leave homes smoothly.
Niko/foragers go forage through live smart-object targets and normal pathfinding.
No one walks into walls.
No one crashes on stale objects.
No flags were flipped to fake the sequence.
```

If that story fails, the repair is not done, regardless of how many synthetic suites pass.

---

## 14. Final Instruction

Do not make this complicated. The original system already had the basic gameplay loop. Restore that gameplay loop on top of the new architecture by fixing lifetime safety, update cadence, tutorial scripted orders, and honest tests.

This repair is accepted only when the real tutorial playthrough proves the player, Mira, guards, civilians, repair quest, sleep transition, morning departures, and Niko/foragers all behave correctly through the same systems used in normal gameplay.
