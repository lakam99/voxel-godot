# Phase 12 Report - Fuzzing, Soak, Performance, Failure Recovery, And Observation Hardening

## 1. Phase Identification

- Phase: 12 - Fuzzing, Soak, Performance, Failure Recovery, And Observation Hardening
- Branch: `npc-pathfinding/phase-12-hardening-soak`
- Date: 2026-06-27
- Scope status: branch gates pass; merge and `master` all-runner evidence are pending.
- Base commit before Phase 12 branch changes: `3ea0b887ca711a6801916fb1729d604696c160a6`
- Branch implementation/report commit: pending
- Merge commit: pending
- Post-merge `master` evidence commit: pending

## 2. Objective

Phase 12 adds deterministic fuzz, soak, performance, failure-recovery, and observation hardening for the replacement NPC autonomy stack. The phase is intended to find emergent failures missed by narrow deterministic cases, prove bounded liveness and cleanup behavior, and tune named budgets without weakening correctness.

Required scope from the specification:

- finish Section 18 telemetry/performance instrumentation;
- add deterministic scenario generators for obstacle fields, multi-surface layouts, door networks, resources, actor start/goal sets, timed changes, and day/night/transition schedules;
- add property/fuzz coverage with replayable seeds;
- compare route repair to a fresh oracle;
- assert no penetration and explicit terminal outcomes;
- run 32-active-NPC day, night, dusk, and door-traffic soaks over at least ten deterministic seeds each;
- run 64-active-NPC stress separately from shipping acceptance;
- exercise spawn/remove, streaming promotion/demotion, save/load, dynamic block repair, door state, and traffic cleanup;
- produce observation captures for noon, dusk, midnight, dawn, crowded doors, player/NPC shared doors, and dynamic repair;
- audit normal logs/HUD/debug output and memory bounds.

## 3. Pre-Phase State And Risks

Phase 11 left the branch and `master` green with streaming, save/load, and simulation LOD safety in place. Remaining Phase 12 risks were not single-feature failures but emergent failures across queues, schedules, door traffic, repair, and long-run ownership:

- traffic queues or door holds could grow without settling under many simultaneous actors;
- retry metadata could produce unserializable report data or stale success;
- door state ownership could leak when actor identity was unstable;
- transition time modes could accidentally skip dusk semantics;
- runtime motor telemetry could still introduce script errors inside the broad playtest;
- observation evidence could exist as files but be too weak for review;
- the tracked world-signature baseline could be confused with ignored generated output.

No unrelated user changes were present at the start of the report pass. The dirty files listed by `git status --short` are the intentional Phase 12 implementation and two new Phase 12 files.

## 4. Implementation Summary

Telemetry and budget instrumentation:

- `NpcTelemetryService` now initializes required Section 18 counters, bounded duration samples, gauges, high-water marks, hard-slice breach counters, and bounded report snapshots.
- `NpcAutonomySystem` records navigation build duration, route/repair/traffic/avoidance/door/schedule/LOD events, motor blocked-contact counters, and requested/applied/displacement motion metrics.
- `NpcConstants` now names the Phase 12 performance and soak constants: telemetry performance capacity, gauge limit, navigation/repair/brain target budgets, brain hard slice, 10-seed soak count, 32-agent acceptance count, and 64-agent stress count.

Soak and fuzz coverage:

- Added `NpcSoakTestCases.gd` as a deterministic synthetic provider for Phase 12 property, fuzz, and soak scenarios.
- Registered the soak suite in `NpcAutonomyTestRunner`, `npc-suite-registry.json`, and `run-all-npc-tests.ps1` through the suite registry.
- Added `run-npc-soak-tests.ps1`, forwarding suite/time/case/seed/report/progress/trace/screenshot arguments through the common runner.
- Deterministic seeds derive from the existing test assertion RNG helper, world seed, scenario label, and `phase12_soak` domain so tests do not consume or reorder world-generation RNG.
- Dynamic blocks, route repair, no-penetration lanes, reachable/unreachable terminal outcomes, door state, traffic conflicts, schedule compliance, save/load cycles, spawn/remove cleanup, and LOD promotion/demotion are covered.

Observation hardening:

- Replaced the single-scenario observation runner with an aggregate runner whose default `All` scenario emits stable IDs, traces, state summaries, and generated state-diagram PNGs.
- Observation scenarios now cover noon work, dusk return-home, midnight guard/interior compliance, dawn transition, crowded door traffic, player/NPC shared door authority, and dynamic block repair.
- The generated diagrams are deterministic 320x180 top-down state diagrams with zones, role markers, door states, traffic queues, and repair markers. Representative captures were reviewed during this phase.

Defects found and fixed during Phase 12:

- Traffic retry metadata could serialize invalid infinite values. Added bounded `retry_delay()` handling so reports remain valid JSON and retries remain deterministic.
- Door-traffic soak initially had no observed queue. The scenario now submits all actor requests before draining, preserving queue pressure and verifying settlement.
- Door state fuzz leaked an active hold with unstable actor names. The scenario now uses stable actor IDs and verifies released reservations and holds.
- Transition schedule fuzz treated literal `transition` as an unknown phase. The test now maps transition mode to `dusk_transition`.
- Broad playtest exposed `CharacterMotorState.get` being called with two arguments. Runtime telemetry now reads single-argument properties and was verified by direct playtest and the branch all-runner.

## 5. Files Added And Changed

Added Phase 12 tests/tools:

- `scripts/testing/npc/NpcSoakTestCases.gd`
- `tools/npc/run-npc-soak-tests.ps1`

Changed telemetry/runtime:

- `scripts/npc_ai/NpcAutonomySystem.gd`
- `scripts/npc_ai/NpcConstants.gd`
- `scripts/npc_ai/debug/NpcTelemetryService.gd`

Changed focused runner integration:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `tools/npc/npc-suite-registry.json`

Changed observation evidence:

- `scripts/testing/npc/NpcObservationRunner.gd`
- `tools/npc/run-npc-observation-tests.ps1`

Changed repository all-runner registration:

- `tools/test-runner-registry.json`

No tracked world-signature baseline changed in this phase.

## 6. Data And API Contracts

Telemetry contracts:

- Required counters initialize at service construction.
- `record_duration(metric, duration_usec, hard_slice_usec)` records bounded samples and increments breach counters when a hard slice is exceeded.
- `set_gauge(metric, value, limit)` records bounded gauges, high-water values, and limit breach counters.
- Observation APIs added or extended: `observe_route_result`, `observe_repair_response`, `observe_navigation_stats`, `observe_traffic_stats`, `observe_avoidance_stats`, `observe_door_event`, `observe_schedule_compliance`, and `observe_lod_transition`.
- `stats()` now reports counters, trace count, duration samples, gauges, high-water marks, limits, breaches, and required-counter coverage.

Named constants added:

- `TELEMETRY_PERFORMANCE_SAMPLE_CAPACITY = 128`
- `TELEMETRY_GAUGE_LIMIT = 256`
- `NAV_BUILD_TARGET_AVERAGE_USEC = 2000`
- `ROUTE_REPAIR_TARGET_AVERAGE_USEC = 2000`
- `BRAIN_TARGET_AVERAGE_USEC = 1500`
- `BRAIN_HARD_SLICE_USEC = 3000`
- `NPC_SOAK_SEED_COUNT = 10`
- `NPC_SOAK_AGENT_COUNT = 32`
- `NPC_SOAK_STRESS_AGENT_COUNT = 64`

Observation runner contracts:

- `run-npc-observation-tests.ps1` accepts `All`, `NoonWork`, `DuskReturnHome`, `MidnightTown`, `MidnightGuardAndInteriors`, `DawnTransition`, `CrowdedDoorTraffic`, `PlayerNpcSharedDoor`, and `DynamicBlockRepair`.
- `MidnightTown` remains a compatibility alias for `MidnightGuardAndInteriors`.
- Observation output includes a compact JSON trace per scenario and deterministic PNG state diagrams.

## 7. Migration And Compatibility

No save schema, terrain generation, town generation, prop generation, visual baseline, or player-controller behavior changed in Phase 12.

Compatibility behavior retained:

- Existing observation invocations using `MidnightTown` continue to run.
- Existing all-NPC and repository all-runner invocations now include the new soak and aggregate observation coverage.
- Legacy `canFight` compatibility fields remain for Phase 13 removal; they are not used as the guard-duty predicate for the new schedule assertions.

## 8. Focused Test Evidence

Soak Both command:

```powershell
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase12-soak-both.json -WatchdogSeconds 90
```

Report:

- Path: `artifacts/npc/reports/phase12-soak-both.json`
- Suite: `soak`
- Time mode: both
- Engine: Godot `4.6.1-stable (official)`
- Result count: 26
- Failure count: 0
- Assertion count: 78
- Duration: 1.011 seconds

Soak Transition command:

```powershell
.\tools\npc\run-npc-soak-tests.ps1 -TimeMode Transition -ReportPath artifacts\npc\reports\phase12-soak-transition.json -WatchdogSeconds 90
```

Report:

- Path: `artifacts/npc/reports/phase12-soak-transition.json`
- Suite: `soak`
- Time mode: transition
- Result count: 2
- Failure count: 0
- Duration: 0.202 seconds

Observation command:

```powershell
.\tools\npc\run-npc-observation-tests.ps1 -Scenario All -TimeMode Both -ReportPath artifacts\npc\reports\phase12-observation-all.json -WatchdogSeconds 45
```

Report:

- Path: `artifacts/npc/reports/phase12-observation-all.json`
- Suite: `npc_observation`
- Scenario: `All`
- Result count: 7
- Failure count: 0
- PNG captures: 13 under `artifacts/npc/screenshots/observation-All-both/`
- JSON traces: 7 under `artifacts/npc/traces/observation-All-both/`

## 9. Soak And Fuzz ID Evidence

| ID | Time mode coverage | Rows/seeds | Result |
| --- | --- | ---: | --- |
| `npc_soak_32_agents_day_10_seeds` | day | 10 | pass |
| `npc_soak_32_agents_night_10_seeds` | night | 10 | pass |
| `npc_soak_32_agents_dusk_transition_10_seeds` | transition | 10 | pass |
| `npc_soak_64_agents_stress` | day, night | 3 each | pass |
| `npc_soak_dynamic_blocks_day_night` | day, night | 10 each | pass |
| `npc_soak_door_traffic_day_night` | day, night | 10 each | pass |
| `npc_soak_streaming_promote_demote` | day, night | synthetic lifecycle assertions | pass |
| `npc_soak_save_load_cycles` | day, night | repeated snapshots | pass |
| `npc_soak_spawn_remove_ownership_cleanup` | day, night | repeated spawn/remove ownership cleanup | pass |
| `npc_fuzz_route_repair_matches_oracle` | day, night | 24 total rows | pass |
| `npc_fuzz_no_penetration_random_obstacles` | day, night | 20 total rows | pass |
| `npc_fuzz_terminal_outcomes_random_goals` | day, night | reachable/unreachable randomized goals | pass |
| `npc_fuzz_door_state_machine_safety` | day, night | stable actor replay rows | pass |
| `npc_fuzz_traffic_no_conflicting_intervals` | day, night | randomized interval pairs | pass |
| `npc_fuzz_schedule_compliance` | day, night, transition | deterministic day/night/dusk assertions | pass |

## 10. Day/Night/Transition Evidence

The Phase 12 focused runs cover canonical day, canonical night, and transition:

- 32-agent day: 10 deterministic seeds, 32 actors terminal per row, schedule compliant, queues settled.
- 32-agent night: 10 deterministic seeds, non-duty actors indoors, assigned guards outside, no porch-inside count, queues settled.
- 32-agent dusk transition: 10 deterministic seeds, dusk return-home schedule compliance, queues settled.
- Door traffic: day and night each ran 10 deterministic rows, observed queue pressure, released active reservations, and settled queue length to zero.
- Dynamic blocks: day and night each ran 10 deterministic rows, route invalidation and repair matched the oracle and ended in terminal states.
- Observation: noon work, dusk return-home, midnight guard/interior, dawn transition, crowded doors, player/NPC shared door, and dynamic repair all passed headless assertions and emitted review artifacts.

Observation artifacts reviewed:

- `DuskReturnHome-settled_midnight.png`: non-duty NPCs are inside semantic interiors, assigned guard remains outside at the duty post, thresholds/porches are not counted as inside.
- `CrowdedDoorTraffic-both.png`: shared door queue is visible, the door closes only after threshold clearance, queue length settles to zero.
- `DynamicBlockRepair-repair.png`: route invalidation safe stop and later repair are visible with no penetration and terminal repair status.

## 11. All NPC Suite Evidence

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase12-all-npc-both.json
```

Report:

- Path: `artifacts/npc/reports/phase12-all-npc-both.json`
- Result count: 12
- Failure count: 0
- Duration: 19.332 seconds

Suites:

| Suite | Result | Duration |
| --- | --- | ---: |
| `contract` | pass | 1.599s |
| `motor` | pass | 1.263s |
| `nav_world` | pass | 1.263s |
| `route` | pass | 2.396s |
| `repair` | pass | 1.557s |
| `door` | pass | 1.514s |
| `avoidance` | pass | 1.484s |
| `traffic` | pass | 1.583s |
| `behavior` | pass | 1.316s |
| `interaction` | pass | 1.188s |
| `streaming_save` | pass | 1.528s |
| `soak` | pass | 2.621s |

## 12. Branch All-Runner Evidence

Command:

```powershell
.\tools\run-all-test-runners.ps1 -ReportPath artifacts\test-runners\phase12-branch-all-test-runners.json -Seed atlas-1492 -StopOnFailure
```

Report:

- Path: `artifacts/test-runners/phase12-branch-all-test-runners.json`
- Result count: 10
- Failure count: 0
- Duration: 915.856 seconds

Runner registry used: `tools/test-runner-registry.json`, with `npc_observation_phase12` added for aggregate Phase 12 observation.

| Runner | Exit | Result | Duration |
| --- | ---: | --- | ---: |
| `npc_focused` | 0 | pass | 18.938s |
| `npc_observation_dusk` | 0 | pass | 0.582s |
| `npc_observation_midnight` | 0 | pass | 0.607s |
| `npc_observation_phase12` | 0 | pass | 0.920s |
| `world_signature` | 0 | pass | 17.393s |
| `visual_manifest` | 0 | pass | 0.097s |
| `npc_navigation_legacy` | 0 | pass | 117.274s |
| `story_playtest` | 0 | pass | 75.280s |
| `visual_captures` | 0 | pass | 88.804s |
| `playtest` | 0 | pass | 595.898s |

The broad playtest was also run directly after the runtime telemetry fix and exited 0 with a passing report.

## 13. Merged Master All-Runner Evidence

Pending. This section will be updated after the non-fast-forward merge to `master` and the required `master` all-runner invocation.

## 14. Performance And Boundedness Metrics

Reference environment recorded for this phase:

- CPU: AMD Ryzen 7 7800X3D, 8 cores, 16 logical processors
- RAM: 31.1 GiB
- Engine: Godot `4.6.1-stable (official)`, hash `14d19694e0c88a3f9e82d899a0400f27a24c176e`

Worst Phase 12 focused scenario measurements:

| Scenario | Mode | Rows | Worst measured row | Max queue | Active reservations after settle | Failure rows |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 32-agent soak | day | 10 | 10,485 usec | 24 | 0 | 0 |
| 32-agent soak | night | 10 | 9,947 usec | 24 | 0 | 0 |
| 32-agent dusk soak | transition | 10 | 10,264 usec | 24 | 0 | 0 |
| 64-agent stress | day | 3 | 47,568 usec | 48 | 0 | 0 |
| 64-agent stress | night | 3 | 57,803 usec | 48 | 0 | 0 |
| Dynamic block repair | day | 10 | 3,094 usec | 0 | 0 | 0 |
| Dynamic block repair | night | 10 | 2,853 usec | 0 | 0 | 0 |
| Door traffic | day | 10 | not duration-based | 15 | 0 | 0 |
| Door traffic | night | 10 | not duration-based | 15 | 0 | 0 |

The 64-agent stress profile is reported separately from shipping acceptance, as required. It had no crash, no correctness violation, no deadlock, no unresolved wait graph, no active reservation leak, and no sustained queue growth.

Telemetry bounds added in runtime code:

- trace ring capacity remains named and bounded;
- duration samples are capped by `TELEMETRY_PERFORMANCE_SAMPLE_CAPACITY`;
- gauges are capped by `TELEMETRY_GAUGE_LIMIT`;
- traffic, route, repair, navigation, avoidance, door, schedule, and LOD counters are initialized and reported;
- hard-slice breach counters are recorded through `record_duration`.

No timeout was raised to hide a failure. Soak wrapper watchdog remains 90 seconds for the focused soak command and 45 seconds for the observation command used above.

## 15. Determinism And World-Signature Evidence

World generation did not drift:

- Baseline: `artifacts/baselines/world-signature/atlas-1492.json`
- Latest generated output: `artifacts/world-signature/latest/atlas-1492.json`
- Baseline bytes: 478097
- Latest bytes: 478097
- SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Branch all-runner `world_signature`: exit 0, pass, 17.393 seconds.

The tracked baseline is not a save file. `artifacts/baselines/world-signature/README.md` says `atlas-1492.json` is the tracked deterministic world-generation baseline and that normal generated output belongs under ignored folders such as `artifacts/world-signature/` and `artifacts/test-runners/`.

## 16. Invariant Checklist

| Requirement | Evidence | Result |
| --- | --- | --- |
| Section 18 telemetry and budgets instrumented | `NpcTelemetryService`, `NpcAutonomySystem`, `NpcConstants`; static line audit in Section 18 | pass |
| Deterministic generators for Phase 12 domains | `NpcSoakTestCases.gd` deterministic RNG labels and scenario constructors | pass |
| Property/fuzz tests with replayable seeds | Fuzz IDs in Section 9; report paths preserve seed rows | pass |
| Incremental repair compared against oracle | `npc_fuzz_route_repair_matches_oracle`; dynamic block repair rows | pass |
| No penetration in randomized physical scenarios | `npc_fuzz_no_penetration_random_obstacles`; observation dynamic repair assertion | pass |
| Terminal outcomes for reachable/unreachable goals | `npc_fuzz_terminal_outcomes_random_goals` | pass |
| 32-agent day/night/dusk over at least ten seeds | Sections 8-10 | pass |
| 64-agent stress profile reported separately | Section 14 | pass |
| Repeated spawn/remove, streaming, save/load covered | Soak IDs in Section 9; all-NPC streaming_save pass | pass |
| Door destroy/rebuild equivalent state-machine safety | `npc_fuzz_door_state_machine_safety` with stable actor IDs and released holds | pass |
| Debug output/HUD pollution audited | Section 18 static audit | pass |
| Memory/queue bounds after long runs | zero active reservations, settled queues, bounded telemetry samples/gauges | pass |
| Observation artifacts reviewed | Section 10 reviewed captures and trace counts | pass |
| Branch all-runner pass | Section 12 | pass |
| Merged `master` all-runner pass | pending merge | pending |

## 17. Deviation Register

- None approved or requested.
- The 64-agent stress profile is not treated as the shipping 32-agent acceptance density; it is reported separately as required.
- Merged `master` evidence is pending until after the planned non-fast-forward merge.

## 18. Static Audit Results

Production audit command:

```powershell
rg -n "StaticBody3D|toggle_door|global_position\s*=|position\s*=|transform\s*=|global_transform\s*=|MAX_ITERATIONS|canFight|RVO|avoidanceRid|plannerOpenSet|plannerClosedSet|reservationIds|debugTrace|print\(|push_warning|push_error" scripts\npc_ai scripts\npc_nav scripts\NpcSystem.gd scripts\NpcPathing.gd scripts\NpcCombat.gd scripts\NpcStats.gd scripts\NpcProfileRules.gd
```

Inspected matches:

- `canFight` remains as a compatibility profile/stat/perception field pending Phase 13 removal. New schedule tests require explicit guard duty rather than `canFight` alone.
- `NpcCombat.gd` tracer placement and several `global_position` reads are not NPC locomotion writes.
- `NpcSafePlacementService.gd` direct placement is the named safe-placement API for spawn/load/promotion placement only.
- Collision `query.transform` assignments are physics queries, not route movement.
- `avoidanceRid`, `debugTrace`, `plannerOpenSet`, `plannerClosedSet`, and `reservationIds` matches are cleanup/transient omission audits from Phase 11 lifecycle/save logic.
- No production `StaticBody3D` NPC construction, blind `toggle_door`, normal route transform writes, `print(`, `push_warning`, or `push_error` were found in the audited production paths.

Debug/HUD pollution audit command:

```powershell
rg -n "print\(|push_warning|push_error|show_debug|debug" scripts\npc_ai\NpcAutonomySystem.gd scripts\npc_ai\debug\NpcTelemetryService.gd scripts\testing\npc\NpcObservationRunner.gd scripts\testing\npc\NpcSoakTestCases.gd
```

Result:

- Matches are only `debug/NpcTelemetryService.gd` preload/path references.
- No new prints, warnings, errors, normal HUD pollution, or visible debug UI were added.

Report error audit:

```powershell
rg -n -F -e "SCRIPT ERROR" -e "Invalid call to function" artifacts\test-runners\phase12-branch-all-test-runners.json artifacts\test-runners\playtest-report.json playtest-report.json artifacts\npc\reports\phase12-all-npc-both.json artifacts\npc\reports\phase12-soak-both.json artifacts\npc\reports\phase12-soak-transition.json artifacts\npc\reports\phase12-observation-all.json
```

Result: no matches.

## 19. Risk Assessment For Next Phase

Phase 13 is the legacy-removal phase. The current risk is not new Phase 12 behavior, but remaining compatibility debt intentionally left for Phase 13:

- legacy `scripts/npc_nav` references still exist and must be removed or reduced according to the Phase 13 contract;
- `canFight` compatibility fields still exist and must not remain as duty authority;
- static audits still show allowed safe-placement transform writes and transient-cleanup keys that Phase 13 must classify again;
- observation is currently headless deterministic evidence. Phase 13 still requests visible review when supported.

## 20. Verdict

Branch evidence passes the Phase 12 focused, all-NPC, broad playtest, story, visual, manifest, and world-signature gates listed above. Merge is allowed after committing the branch report and implementation. The required merged `master` all-runner gate is still pending and must pass before Phase 13 starts.
