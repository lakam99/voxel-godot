# Phase 09 Report - Utility Goals, Symbolic Task Planning, and Day/Night Schedules

## 1. Phase Identification

- Phase: 09 - Utility Goals, Symbolic Task Planning, and Day/Night Schedules
- Branch: `npc-pathfinding/phase-09-purpose-schedules`
- Date: 2026-06-27
- Scope status: branch gates pass; merged `master` evidence is pending the required merge and rerun step.
- Base commit before Phase 09 branch changes: `2c0c6af59dfada2bbc290af51f581d9371fbd213`
- Branch implementation commit: `35e0e07f0e505972e056953d4c8ebb4d6bef59e2`
- Branch report commit: pending
- Merge commit: pending
- Post-merge `master` evidence commit: pending

## 2. Objective

Phase 09 replaces destination and phase-script NPC decisions with purpose-driven goals, role schedules, symbolic action plans, explicit guard duty, interior night compliance, and observation evidence for dusk and midnight behavior. The new stack must own high-level NPC movement decisions while preserving existing tutorial, story, combat, job, door, traffic, and route behavior.

## 3. Pre-Phase State And Risks

Before this phase, route, door, local avoidance, traffic, and repair infrastructure existed, but the high-level NPC decision loop still lived in `NpcSystem.update_npc_legacy_fallback()`. That fallback selected home, guard, job, and wander destinations directly.

Relevant risks at phase start:

- `canFight` and `nightGuard` were easy to conflate.
- Non-duty NPC night behavior depended on legacy target selection rather than a role/schedule matrix.
- Home arrival could be inferred from target proximity rather than semantic interior containment.
- Guard behavior could remain tied to combat capability instead of explicit duty assignment.
- Playtest coverage existed, but there was no dedicated day/night observation runner with role counts, door crossing evidence, captures, and traces.

## 4. Implementation Summary

Added a composed Phase 09 behavior layer under `scripts/npc_ai/behavior/`:

- `NpcScheduleService` produces deterministic day/dusk/night/dawn schedule snapshots and role profile data.
- `GuardRosterService` migrates legacy `nightGuard` data into explicit night duty only for actual guard/watch roles.
- `NpcPerceptionService` reports threat state, semantic home containment, porch/threshold state, route state, and schedule state.
- `NpcGoalSelector` scores idle, work, forage, home, guard, and scripted goals with logged utility breakdown and hysteresis.
- `NpcActionLibrary` defines bounded action records with preconditions, effects, costs, execution kind, interruptibility, timeouts, and failure reasons.
- `NpcTaskPlanner` turns selected goals into bounded symbolic action sequences.
- `NpcPlanExecutor` executes the selected plan through existing movement, route, door, traffic, combat, job, and scripted target APIs.
- `NpcRecoveryPolicy` reports unreachable or blocked goals as explicit terminal state and records `teleportUsed=false`.

`NpcAutonomySystem.update_legacy_npc()` now delegates migrated NPC high-level behavior to the Phase 09 executor. `NpcSystem.update_npc()` calls the autonomy system first and the legacy fallback only remains as compatibility fallback if the composed system is absent.

Role schedule resources were added for guard, farmer, carpenter, forager, mason, trader, civilian, and tutorial NPCs. Generated town and tutorial NPC registration now publishes home interior, guard post, and route semantics needed by the new schedule and observation checks.

Two playtest regressions were found during branch validation and fixed:

- Tutorial elder home return failed because the legacy XZ blocker snapshot treated roof/header blocks as ground blockers and door cells as static blockers. `NpcNavigationWorld` now ignores above-headroom blocks for NPC occupancy and lets logical door cells be handled by door traversal instead of static obstruction.
- Tutorial guard engagement failed because the new executor path bypassed the old combat cooldown decay. `NpcPlanExecutor` now decays `entry["cooldown"]` before planning/execution, and a focused behavior case covers it.

## 5. Files Added And Changed

Added behavior/runtime files:

- `scripts/npc_ai/behavior/NpcRoleScheduleResource.gd`
- `scripts/npc_ai/behavior/GuardRosterService.gd`
- `scripts/npc_ai/behavior/NpcScheduleService.gd`
- `scripts/npc_ai/behavior/NpcPerceptionService.gd`
- `scripts/npc_ai/behavior/NpcGoalSelector.gd`
- `scripts/npc_ai/behavior/NpcActionLibrary.gd`
- `scripts/npc_ai/behavior/NpcTaskPlanner.gd`
- `scripts/npc_ai/behavior/NpcRecoveryPolicy.gd`
- `scripts/npc_ai/behavior/NpcPlanExecutor.gd`

Added role resources:

- `resources/npc_roles/guard.tres`
- `resources/npc_roles/farmer.tres`
- `resources/npc_roles/carpenter.tres`
- `resources/npc_roles/forager.tres`
- `resources/npc_roles/mason.tres`
- `resources/npc_roles/trader.tres`
- `resources/npc_roles/civilian.tres`
- `resources/npc_roles/tutorial.tres`

Added test and observation files:

- `scripts/testing/npc/NpcBehaviorTestCases.gd`
- `scripts/testing/npc/NpcObservationRunner.gd`
- `scenes/testing/npc/NpcObservationTest.tscn`
- `tools/npc/run-npc-behavior-tests.ps1`
- `tools/npc/run-npc-observation-tests.ps1`

Changed integration and diagnostics:

- `scripts/NpcSystem.gd`
- `scripts/NpcProfileRules.gd`
- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_nav/NpcGoalPlanner.gd`
- `scripts/npc_nav/NpcNavigationWorld.gd`
- `scripts/npc_ai/routing/HierarchicalRoutePlanner.gd`
- `scripts/npc_ai/interactions/DoorTraversalExecutor.gd`
- `scripts/TutorialSystem.gd`
- `scripts/TutorialSceneBuilder.gd`
- `scripts/StructureSystem.gd`
- `scripts/PlaytestRunner.gd`
- `scripts/NpcNavigationTestRunner.gd`
- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`
- `tools/test-runner-registry.json`

## 6. Data And API Contracts

New role schedule resources expose:

- `role_id`
- `canonical_job`
- `day_goal_kind`
- `dusk_goal_kind`
- `night_goal_kind`
- `requires_interior_home`
- `can_take_night_guard`
- `semantic_anchor_kinds`

New per-NPC runtime/debug fields include:

- `agentContext`
- `blackboard`
- `activeGoalKind`
- `goal`
- `goalReason`
- `utilityBreakdown`
- `currentPlan`
- `scheduleState`
- `scheduleCompliance`
- `guardDutyKind`
- `guardDutyState`
- `homeSettleDebug`

Observation reports include:

- role counts
- duty assignments
- indoors/outdoors/porch/threshold counts
- exceptions and explicit reasons
- door crossings
- ending door states
- screenshots/captures
- trace path

The all-runner registry now includes:

- `npc_focused`
- `npc_observation_dusk`
- `npc_observation_midnight`
- `world_signature`
- `visual_manifest`
- `npc_navigation_legacy`
- `story_playtest`
- `visual_captures`
- `playtest`

## 7. Migration And Compatibility

`NpcSystem.update_npc()` now delegates to `autonomy_system.update_legacy_npc()` when the composed autonomy system is present. The previous fallback remains for safety if the autonomy system cannot be constructed, but the focused behavior test `npc_behavior_no_raw_random_world_goal` asserts that the migrated update path delegates rather than owning the decision loop.

Existing public methods remain as integration adapters:

- `home_route_target`
- `move_npc`
- `settle_home_if_reached`
- `update_day_job`
- `update_scripted_npc`
- `update_fighter_target`
- `face_hostile_if_needed`

Existing tutorial and story holds are preserved through `npc_is_held_by_intro_or_dialogue()` and the scripted goal/action path. Existing job effects remain compatible; richer shared environment job actions are left to Phase 10 as specified.

## 8. Focused Test Evidence

Command:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase09-behavior-both-after-fixes.json
```

Report:

- Path: `artifacts/npc/reports/phase09-behavior-both-after-fixes.json`
- Time mode: both
- Result count: 22
- Failure count: 0
- Duration: 0.060 seconds

Command:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Transition -ReportPath artifacts\npc\reports\phase09-behavior-transition-after-fixes.json
```

Report:

- Path: `artifacts/npc/reports/phase09-behavior-transition-after-fixes.json`
- Time mode: transition
- Result count: 2
- Failure count: 0
- Duration: 0.034 seconds

Additional regression case:

```powershell
.\tools\npc\run-npc-behavior-tests.ps1 -Case npc_behavior_executor_decays_guard_cooldown -TimeMode Night -ReportPath artifacts\npc\reports\phase09-behavior-cooldown-case.json
```

- Result count: 1
- Failure count: 0
- Details: `cooldown 0.75 -> 0.50`

Minimum IDs covered:

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
- `npc_behavior_executor_decays_guard_cooldown`

## 9. Day/Night Observation Evidence

Command:

```powershell
.\tools\npc\run-npc-observation-tests.ps1 -Scenario DuskReturnHome -TimeMode Transition -ReportPath artifacts\npc\reports\phase09-observation-dusk-after-fixes.json
```

Report:

- Path: `artifacts/npc/reports/phase09-observation-dusk-after-fixes.json`
- Scenario: `DuskReturnHome`
- Failure count: 0
- Role counts: guard 1, farmer 1, carpenter 1, forager 1, mason 1, trader 1, civilian 1, tutorial 1
- Location counts: indoors 7, outdoors 1, porch 0, threshold 0
- Duty assignments: 1 night guard, `guard_00`, outside at `guard:town-main`
- Door crossings: 8
- Captures: 3, dusk/full_night/settled_midnight
- Trace: `artifacts/npc/traces/observation-DuskReturnHome-transition/DuskReturnHome-trace.json`

Command:

```powershell
.\tools\npc\run-npc-observation-tests.ps1 -Scenario MidnightTown -TimeMode Night -ReportPath artifacts\npc\reports\phase09-observation-midnight-after-fixes.json
```

Report:

- Path: `artifacts/npc/reports/phase09-observation-midnight-after-fixes.json`
- Scenario: `MidnightTown`
- Failure count: 0
- Role counts: guard 1, farmer 1, carpenter 1, forager 1, mason 1, trader 1, civilian 1, tutorial 1
- Location counts: indoors 7, outdoors 1, porch 0, threshold 0
- Duty assignments: 1 night guard, `guard_00`, outside patrol at `guard:town-main`
- Door crossings: 8
- Captures: 1, settled_midnight
- Trace: `artifacts/npc/traces/observation-MidnightTown-night/MidnightTown-trace.json`

Normal generated-town assertions passed in both observation reports:

- assigned guards outside in valid duty states
- every other NPC inside assigned home interior
- zero porch/threshold occupants counted as inside
- no ordinary day job active
- exceptions list empty
- ending door states closed with zero threshold occupants

## 10. NPC Suite Evidence

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase09-all-npc-after-fixes.json
```

Report:

- Path: `artifacts/npc/reports/phase09-all-npc-after-fixes.json`
- Time mode: Both
- Result count: 9
- Failure count: 0
- Duration: 13.957 seconds

Suites:

- `contract`: pass
- `motor`: pass
- `nav_world`: pass
- `route`: pass
- `repair`: pass
- `door`: pass
- `avoidance`: pass
- `traffic`: pass
- `behavior`: pass

## 11. Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase09-all-test-runners-after-fixes.json -Seed atlas-1492
```

Report:

- Path: `artifacts/test-runners/phase09-all-test-runners-after-fixes.json`
- Seed: `atlas-1492`
- Result count: 9
- Failure count: 0
- Duration: 1509.482 seconds
- Stopped early: false

Runner registry used: `tools/test-runner-registry.json`

Runner results:

- `npc_focused`: pass, exit 0, 13.605 seconds
- `npc_observation_dusk`: pass, exit 0, 0.560 seconds
- `npc_observation_midnight`: pass, exit 0, 0.572 seconds
- `world_signature`: pass, exit 0, 18.173 seconds
- `visual_manifest`: pass, exit 0, 0.120 seconds
- `npc_navigation_legacy`: pass, exit 0, 110.515 seconds
- `story_playtest`: pass, exit 0, 77.274 seconds
- `visual_captures`: pass, exit 0, 97.948 seconds
- `playtest`: pass, exit 0, 1190.649 seconds

Broad playtest branch evidence:

- Command: `.\tools\run-playtest.ps1 -ReportPath artifacts\test-runners\phase09-playtest-after-fixes.json -Seed atlas-1492 -TimeoutSeconds 1800 -StaleProgressSeconds 300`
- Report: `artifacts/test-runners/phase09-playtest-after-fixes.json`
- Finished: true
- Passed: true
- Result count: 181
- Failures: 0

## 12. Merged Master Evidence

Pending. Per protocol, after this branch report is committed, the branch will be merged into `master`, then:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase09-master-all-test-runners.json -Seed atlas-1492
```

The report will be updated with the merge hash and master runner result.

## 13. Performance And Boundedness Metrics

Measured runner durations:

- Behavior both: 0.060 seconds
- Behavior transition: 0.034 seconds
- Observation dusk: 0.0 seconds reported by runner
- Observation midnight: 0.0 seconds reported by runner
- All NPC suites: 13.957 seconds
- Branch all-runner: 1509.482 seconds
- Broad playtest: 1190.649 seconds inside the all-runner

Boundedness controls present:

- `NpcTaskPlanner` bounds plans to 8 actions.
- `NpcActionLibrary` action records include timeout seconds.
- Goal selection uses a fixed goal set and stable tie ordering.
- Dusk/night observation uses fixed synthetic role matrix and deterministic seed.
- Recovery policy records unreachable/blocked goal terminal state and does not teleport.
- Traffic and door owned state release is called on goal changes/interruption.

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

No tracked world-signature baseline change is present in this phase.

## 15. Invariant Checklist

- New goal/task/executor stack owns generic and tutorial NPC high-level movement decisions: yes, `NpcSystem.update_npc()` delegates to `NpcAutonomySystem.update_legacy_npc()`; `npc_behavior_no_raw_random_world_goal` passes.
- `canFight` no longer implies night duty: yes, `GuardRosterService` assigns duty only to guard/watch roles; `npc_contract_guard_duty_not_can_fight` and behavior matrix cases pass.
- Night role matrix passes exactly: yes, behavior and observation reports pass with 7 indoors, 1 assigned guard outdoors, 0 porch/threshold.
- Dusk return-home is a real plan through a real door into a real interior: yes, observation reports include inbound door crossings and ending interior states.
- Ordinary wandering uses semantic anchors only: yes, idle goal plans use `relocate_semantic_anchor`; raw idle ring targets are absent from idle candidates.
- Unreachable/blocked goals terminate or choose explicit alternatives without teleporting: yes, `npc_behavior_night_blocked_home_explicit_failure_no_teleport` and `npc_behavior_unreachable_goal_terminal` pass.
- Observation artifacts prove day/night behavior: yes, reports include role counts, duty assignments, locations, exceptions, door crossings, ending door states, captures, and traces.
- Existing story/tutorial behavior remains green: yes, `story_playtest` and broad `playtest` runners pass.
- All focused suites and repository gate pass on branch: yes.
- All focused suites and repository gate pass on `master`: pending required merge and rerun.

## 16. Deviation Register

None for Phase 09 branch scope.

## 17. Known Issues And Debt

- Phase 10 still needs richer shared environment interactions for jobs and resources as specified.
- Some legacy compatibility methods remain in `NpcSystem` because later phases remove duplicate legacy dictionaries and old fallback code.
- Broad playtest remains long; Phase 09 added section filtering and extra progress markers to improve diagnostic runs without changing normal full-run behavior.

## 18. Static Audit Results

Searches run:

```powershell
rg -n "canFight|nightGuard|guardDuty|guard_duty|GUARD_DUTY" scripts\NpcProfileRules.gd scripts\NpcSystem.gd scripts\npc_ai scripts\testing\npc
rg -n "update_npc\(|update_npc_legacy_fallback|update_wander_target|choose_day_target|add_deterministic_ring_candidates|randf_range|randi|RandomNumberGenerator" scripts\NpcSystem.gd scripts\npc_ai\behavior scripts\npc_nav\NpcGoalPlanner.gd
rg -n "teleport|global_position\s*=|position\s*=" scripts\NpcSystem.gd scripts\npc_ai scripts\npc_nav scripts\testing\npc
rg -n "VOXEL_PLAYTEST_ONLY|playtest_section_filter" scripts\PlaytestRunner.gd tools
```

Classified results:

- Guard duty references are expected in `GuardRosterService`, `NpcAgentContext`, `NpcScheduleService`, behavior tests, and metadata/debug fields. The legacy profile flag is migrated and narrowed by role in `GuardRosterService`.
- `canFight` remains combat capability only. Threat exceptions use `canFight`; scheduled night duty uses guard roster/schedule.
- `update_npc_legacy_fallback()` remains as compatibility fallback but is not authoritative when `NpcAutonomySystem` is present.
- `update_wander_target()` remains only inside the fallback path.
- `add_deterministic_ring_candidates()` remains for outside work anchors, not ordinary idle relocation.
- `randf_range()` remains for spawn/job timers and compatibility job effect timers, not production idle world target choice.
- `global_position =` matches in production are spawn/load/safe-placement or test fake setup. Route locomotion tests assert no gameplay route transform write.
- `teleport` matches are test names or `teleportUsed=false` recovery records.
- `VOXEL_PLAYTEST_ONLY` is test-runner instrumentation. Unsupported values create a failing playtest result; default full-run behavior is unchanged.

## 19. Risk Assessment For Phase 10

Phase 10 will attach real environment interactions to this schedule/planner layer. Main risks:

- job/resource action ownership now needs to move from timer simulation toward shared smart objects;
- forager target selection already returns route status diagnostics, so Phase 10 should preserve terminal failure reporting;
- guard threat handling now fires and animates, but richer patrol/intercept behavior should keep cooldown and line-of-sight gates covered;
- retained fallback code should not regain authority as environment actions are migrated.

## 20. Verdict

Phase 09 branch evidence passes and merge is allowed. Master evidence is pending the required merge and rerun step.
