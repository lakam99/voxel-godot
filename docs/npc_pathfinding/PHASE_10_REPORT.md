# Phase 10 Report - Environment Interaction, Jobs, Guards, and World-Aware Purpose

## 1. Phase Identification

- Phase: 10 - Environment Interaction, Jobs, Guards, and World-Aware Purpose
- Branch: `npc-pathfinding/phase-10-world-interaction`
- Date: 2026-06-27
- Scope status: branch and merged `master` gates pass.
- Base commit before Phase 10 branch changes: `7f1b77650c12019dc8626abf388360be6bbbf0ef`
- Branch implementation/report commit: `2554cbfee4dfcf9a33980463935b28c17b9498a8`
- Merge commit: `1d2d2d6c520a9a02de8d27ac7677687c99c5d8d5`
- Post-merge `master` evidence commit: this report update

## 2. Objective

Phase 10 attaches real shared environment interaction authority to the Phase 09 purpose and schedule stack. NPC travel now leads to reserved world objects, valid approach slots, shared availability checks, resource effects, deposits, trader stall use, guard posts, and tutorial action affordances rather than isolated timer outcomes.

## 3. Pre-Phase State And Risks

Before this phase, NPC day jobs could choose reachable destinations and move with schedule-aware purpose, but job effects were still mostly owned by local timers and legacy resource counters. The player and NPCs did not yet share one authoritative object reservation/effect layer for equivalent harvest and use actions.

Relevant risks at phase start:

- A player and NPC could race the same resource and duplicate or lose rewards.
- A timer could grant an NPC job result even if the actor had not reached a valid approach slot.
- Resource target positions could refer to collider centers or wrong vertical layers instead of action slots.
- Prop destruction by the player had to preserve existing player UX while also invalidating NPC reservations.
- Trader, guard, and tutorial semantic actions needed to fit the shared interface without moving story authority into navigation code.
- Additive save facts were needed for durable hunger, inventory, job, guard, and job run state.

## 4. Implementation Summary

Expanded `SmartObjectService` from door-only routing into shared smart-object authority:

- generic object, resource, workstation, and semantic anchor registration;
- stable slot records with approach positions, facing, occupancy, capacity, reservations, revisions, depletion, and metadata;
- command handling for reserve, release/cancel, effect application, harvest, deposit, use, rest, and guard actions;
- access policy checks for actor kind, role, schedule, object busy state, depletion, approach distance, vertical tolerance, and object validity;
- idempotent request/action IDs for repeated callbacks;
- telemetry counters and event records for registration, selected candidates, reservations, releases, blocked attempts, and effects.

Expanded NPC integration:

- `NpcAutonomySystem` exposes smart-object registration, reservation, release, and effect proxy methods.
- `NpcSystem` records durable job facts, restores saved job facts additively, and routes forager, wood, stone, trader, deposit, and player prop harvest flows through the smart-object layer.
- Worker jobs reserve actual resource props, travel to smart-object approach slots, apply effects only after valid approach/reservation, carry resources, and deposit after returning through home/door semantics.
- Foragers reserve reachable forage sources, harvest, carry, eat when hungry, or deposit by role needs.
- Traders use the `trade` role loop and occupy a trader stall by day while returning home by schedule.
- Guards and semantic anchors are available as shared smart-object actions for guard posts, standoff/intercept choices, beds/rest, storage, and tutorial script migration.
- Player prop harvest calls `request_shared_prop_harvest()` before existing reward grants, so player and NPC availability share the same object state while preserving player-facing inventory behavior.

Branch validation found and fixed two issues:

- Initial all-runner playtest failed `generic_npc_job_outings` and `forager_goal_inventory_hunger`; outbound NPC jobs now reserve direct resource targets earlier, accept route `arrived` as terminal, and create a missing reservation before applying an injected target.
- Follow-up standalone playtest still failed ore/tree/forage drops because player prop action origin used the ray hit point above the prop and tripped vertical-layer validation. `MainPropFactory` now sends the prop action origin from the prop `Node3D` position.

## 5. Files Added And Changed

Added test/tool files:

- `scripts/testing/npc/NpcInteractionTestCases.gd`
- `tools/npc/run-npc-interaction-tests.ps1`

Changed shared interaction authority:

- `scripts/npc_ai/interactions/SmartObjectRegistration.gd`
- `scripts/npc_ai/interactions/SmartObjectService.gd`

Changed NPC runtime and behavior integration:

- `scripts/NpcSystem.gd`
- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/behavior/NpcActionLibrary.gd`
- `scripts/npc_ai/behavior/NpcGoalSelector.gd`
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd`
- `scripts/NpcProfileRules.gd`
- `resources/npc_roles/trader.tres`

Changed player/save/test integration:

- `scripts/MainPropFactory.gd`
- `scripts/MainSaveState.gd`
- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

No tracked world-signature baseline file changed in this phase.

## 6. Data And API Contracts

Smart-object registrations now carry:

- `objectId`
- `kind`
- `slots`
- `reservations`
- `capacity`
- `depleted`
- `revision`
- `requiresApproach`
- `actionReach`
- `verticalTolerance`
- access metadata such as role, actor kind, schedule, resource drop, block type, and action kind

Smart-object requests now support:

- reserve
- release/cancel
- effect application
- harvest
- deposit
- use
- rest
- guard

NPC job facts saved additively through `npcJobFacts` include:

- `id`
- `role`
- `job`
- `jobResource`
- `personalInventory`
- `hunger`
- `nightGuard`
- `guardDuty`
- `jobRuns`

Runtime job fields added to NPC entries include:

- `jobObjectId`
- `jobReservationId`
- `jobApproachSlotId`
- `jobFailureReason`
- `carriedResource`

## 7. Migration And Compatibility

Save changes are additive. Old saves without `npcJobFacts` load with generated job state as before. Saves with `npcJobFacts` restore durable job, hunger, inventory, guard, and job run facts by NPC ID after registration.

Player harvesting remains on the existing player UX path for inventory and visual feedback, but availability and depletion checks now pass through shared smart-object authority where equivalent prop interactions exist. NPC plans still use existing route, door, traffic, combat, and schedule infrastructure from earlier phases.

Legacy timers remain as pacing, retry, and cooldown controls. They no longer grant worker/forager resource effects without the smart-object reservation and valid approach result.

## 8. Focused Test Evidence

Command:

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-interaction-after-player-origin-fix.json
```

Report:

- Path: `artifacts/npc/reports/phase10-interaction-after-player-origin-fix.json`
- Suite: `interaction`
- Time mode: both
- Result count: 20
- Failure count: 0
- Assertion count: 31
- Duration: 0.039 seconds

Minimum IDs covered:

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

Additional standalone playtest repair evidence:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\test-runners\playtest-after-prop-origin-fix.json -Seed atlas-1492 -StaleProgressSeconds 240
```

- Report: `artifacts/test-runners/playtest-after-prop-origin-fix.json`
- Finished: true
- Passed: true
- Result count: 181
- Failure count: 0
- Repaired checks: `ore_generation_and_drops`, `tree_fall_visual_and_logs`, `forage_and_wildlife_drops`

## 9. Day/Night Evidence

The Phase 10 focused interaction suite covers explicit day/night object policy:

- `npc_interaction_trader_day_stall_night_home` verifies day stall use and night home behavior.
- `npc_interaction_day_night_object_policy` verifies access policy changes across schedule state.
- `npc_interaction_deposit_through_real_door` verifies deposit after real door traversal.
- `npc_interaction_tutorial_scripted_action_migrated` verifies scripted tutorial action use through the new interaction interface.

The branch all-runner also reran the Phase 09 observation scenarios:

- `npc_observation_dusk`: pass, exit 0, 0.647 seconds
- `npc_observation_midnight`: pass, exit 0, 0.661 seconds

Those observation reports preserve the generated-town matrix: one assigned guard outside, seven non-duty NPCs indoors, zero porch/threshold occupants counted as inside, and ending doors closed with zero threshold occupants.

## 10. NPC Suite Evidence

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-all-npc-after-fixes.json
```

Report:

- Path: `artifacts/npc/reports/phase10-all-npc-after-fixes.json`
- Time mode: Both
- Result count: 10
- Failure count: 0
- Duration: 14.042 seconds

Suites:

- `contract`: pass, exit 0, 1.318 seconds
- `motor`: pass, exit 0, 1.239 seconds
- `nav_world`: pass, exit 0, 1.280 seconds
- `route`: pass, exit 0, 2.378 seconds
- `repair`: pass, exit 0, 1.533 seconds
- `door`: pass, exit 0, 1.295 seconds
- `avoidance`: pass, exit 0, 1.205 seconds
- `traffic`: pass, exit 0, 1.304 seconds
- `behavior`: pass, exit 0, 1.272 seconds
- `interaction`: pass, exit 0, 1.198 seconds

## 11. Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase10-branch-all-after-fixes.json -StopOnFailure
```

Report:

- Path: `artifacts/test-runners/phase10-branch-all-after-fixes.json`
- Seed: `atlas-1492`
- Result count: 9
- Failure count: 0
- Duration: 1168.510 seconds
- Stopped early: false

Runner registry used: `tools/test-runner-registry.json`

Runner results:

- `npc_focused`: pass, exit 0, 21.354 seconds
- `npc_observation_dusk`: pass, exit 0, 0.647 seconds
- `npc_observation_midnight`: pass, exit 0, 0.661 seconds
- `world_signature`: pass, exit 0, 19.254 seconds
- `visual_manifest`: pass, exit 0, 0.094 seconds
- `npc_navigation_legacy`: pass, exit 0, 122.159 seconds
- `story_playtest`: pass, exit 0, 78.490 seconds
- `visual_captures`: pass, exit 0, 89.402 seconds
- `playtest`: pass, exit 0, 836.388 seconds

Earlier branch all-runner failure, fixed before the green rerun:

- Report: `artifacts/test-runners/phase10-branch-all.json`
- Result count: 9
- Failure count: 1
- Stopped early: true
- Failed runner: `playtest`, exit 1, 518.649 seconds
- Follow-up report before the player-origin fix: `artifacts/test-runners/playtest-after-phase10-fix.json`
- Remaining failed checks then: `ore_generation_and_drops`, `tree_fall_visual_and_logs`, `forage_and_wildlife_drops`
- Repair evidence: `artifacts/test-runners/playtest-after-prop-origin-fix.json`, 181 results, 0 failures

## 12. Merged Master Evidence

Focused command:

```powershell
.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-master-interaction.json
```

Focused report:

- Path: `artifacts/npc/reports/phase10-master-interaction.json`
- Result count: 20
- Failure count: 0
- Assertion count: 31
- Duration: 0.043 seconds

NPC suite command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase10-master-all-npc.json
```

NPC suite report:

- Path: `artifacts/npc/reports/phase10-master-all-npc.json`
- Result count: 10
- Failure count: 0
- Duration: 14.092 seconds

Full repository command:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase10-master-all-test-runners.json -StopOnFailure
```

Full repository report:

- Path: `artifacts/test-runners/phase10-master-all-test-runners.json`
- Seed: `atlas-1492`
- Result count: 9
- Failure count: 0
- Duration: 1181.777 seconds
- Stopped early: false

Runner results:

- `npc_focused`: pass, exit 0, 20.905 seconds
- `npc_observation_dusk`: pass, exit 0, 0.673 seconds
- `npc_observation_midnight`: pass, exit 0, 0.644 seconds
- `world_signature`: pass, exit 0, 19.149 seconds
- `visual_manifest`: pass, exit 0, 0.090 seconds
- `npc_navigation_legacy`: pass, exit 0, 132.907 seconds
- `story_playtest`: pass, exit 0, 81.929 seconds
- `visual_captures`: pass, exit 0, 89.750 seconds
- `playtest`: pass, exit 0, 835.666 seconds

## 13. Performance And Boundedness Metrics

Measured runner durations:

- Interaction focused suite: 0.039 seconds
- Master interaction focused suite: 0.043 seconds
- All NPC suites: 14.042 seconds
- Master all NPC suites: 14.092 seconds
- Branch all-runner: 1168.510 seconds
- Master all-runner: 1181.777 seconds
- Branch all-runner playtest: 836.388 seconds
- Master all-runner playtest: 835.666 seconds
- Standalone repaired playtest: 181 results, 0 failures

Boundedness controls present:

- Object reservations are finite and tied to explicit slots.
- Object capacity blocks concurrent single-capacity use.
- Request/action ID tracking makes repeated callbacks idempotent.
- Removed or depleted objects release reservations and return bounded failure reasons.
- Access, approach distance, and vertical tolerance are checked before effects.
- Job retry timers are pacing/backoff state; resource effects require smart-object authority.
- Route failures release reservations and reset job phase instead of looping indefinitely.

## 14. Determinism And World Signature

Command through all-runner:

```powershell
.\tools\run-world-signature.ps1 -OutputPath artifacts\test-runners\world-signature-atlas-1492.json -Seed atlas-1492
```

Evidence:

- Baseline: `artifacts/baselines/world-signature/atlas-1492.json`
- Fresh output: `artifacts/test-runners/world-signature-atlas-1492.json`
- Baseline SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Fresh output SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Runner result: pass

No tracked world-signature baseline change is present in this phase. The generated fresh signature matches the tracked baseline byte-for-byte.

## 15. Invariant Checklist

- Current NPC job loops use shared environment authority: yes, forager, wood, stone, trader, deposit, and player prop harvest paths route through smart-object reservation/effect APIs.
- No effect occurs from invalid approach or through geometry: yes, focused cases cover wall and wrong vertical layer rejection.
- Object capacity/reservations prevent duplicate simultaneous use: yes, resource and workstation capacity cases pass.
- Resource depletion/removal triggers bounded replanning: yes, removed resource and player-first harvest cases pass.
- Guard intercepts are reachable and collision-aware: yes, ranged, melee, and no-attack-through-wall interaction cases pass, with legacy navigation and combat gates still green.
- Day/night role loops remain correct: yes, trader day/night and object policy cases pass, and observation runners pass.
- Tutorial/story integration remains green: yes, tutorial scripted action case, `story_playtest`, and broad `playtest` pass.
- Save changes are additive: yes, `npcJobFacts` is optional on load and broad save/load playtest coverage passes.
- Full focused and repository gates pass on branch: yes.
- Full focused and repository gates pass on `master`: yes, focused interaction, all NPC, and full all-runner reports pass.

## 16. Deviation Register

None for Phase 10 branch scope.

## 17. Known Issues And Debt

- Legacy fallback and some legacy pacing fields remain for compatibility with later phases. They are no longer the authority for migrated resource effects.
- Broad playtest remains long; this phase used explicit progress polling and stale-progress guards to avoid silent waits.

## 18. Static Audit Results

Search run:

```powershell
rg -n "global_position\s*=|position\s*=|transform\s*=|global_transform\s*=|toggle_door\(|workTimer|jobTimer|harvest_timer|timer-only|randf_range|RandomNumberGenerator" scripts\NpcSystem.gd scripts\MainPropFactory.gd scripts\MainSaveState.gd scripts\npc_ai scripts\testing\npc
```

Classified results:

- No NPC production route locomotion transform writes were introduced.
- `global_position =` matches are player save/load, NPC safe placement, and test fixtures.
- `position =` matches in `SmartObjectService` are local variable writes for slot/approach calculation, not actor movement.
- `toggle_door` was not introduced for NPC behavior.
- `RandomNumberGenerator` remains in deterministic RNG stream code and tests.
- `randf_range` and `jobTimer` remain in legacy-compatible spawn, cooldown, pacing, and retry timing. Migrated Phase 10 resource effects require reservation and valid approach before effect application.

Additional validation:

```powershell
git diff --check
```

Result: no whitespace errors; only existing line-ending normalization warnings from Git.

## 19. Risk Assessment For Phase 11

Phase 11 will need to keep smart-object reservations and durable job facts safe across chunk streaming, actor lifecycle changes, abstract simulation, and save/load promotion/demotion.

Main risks:

- active reservations must release when an object, actor, or chunk leaves active simulation;
- abstract transit must not grant effects without representing the same preconditions;
- saved job facts must not point to stale object IDs without a bounded repair path;
- long journeys and simulation LOD must preserve door, traffic, and schedule invariants.

## 20. Verdict

Phase 10 branch and merged `master` evidence pass. Phase 11 may begin from updated `master`.
