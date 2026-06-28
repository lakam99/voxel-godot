# Mature Nav Phase 4: Behavior Authoring Maturity

Date: 2026-06-28
Branch: `codex/mature-navmesh-phase4-behavior-authoring`

## Scope

Phase 4 implements the behavior-authoring slice from `CODEX_MATURE_NAV_PLAN.md`:

- Resource-back the NPC action/task library.
- Convert forage, trader stall, guard post, home return, bed rest, and tutorial scripted actions to shared task definitions.
- Validate that every active NPC goal resolves to a semantic target with a reachable navmesh point, while preserving deferred target selection for goals that intentionally pick targets during execution.

## Implementation

- Added `NpcTaskCatalogResource` and `resources/npc_behavior/task_catalog.tres` as the resource-backed catalog for action definitions and goal sequences.
- Moved the default action definitions out of hardcoded `NpcActionLibrary.gd` registration and into the catalog resource.
- Added catalog validation for required action fields, duplicate IDs, and goal sequence references.
- Added shared goal sequences for scripted orders, tutorial scripted actions, home return/bed rest, guard duty, forage loops, trader stall work, generic work resources, and idle semantic anchors.
- Extended `NpcTaskPlanner` to build goal context, pick catalog-backed sequences, stamp `sequenceId`, `targetKind`, and `semanticTarget`, and reject explicit unreachable semantic targets.
- Kept selected-resource goals such as forage in a planned/pending semantic target state until their task action selects the concrete world target.
- Wired `NpcAutonomySystem` so navmesh backend planning validates against `NavmeshWorldService`, while the custom backend keeps the existing navigation service path.
- Added Phase 4 behavior tests for resource catalog loading, shared task coverage, reachable target validation, and the forager plan regression.

## Focused Verification

- `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -Case npc_behavior_task_catalog_resource_backed -ReportPath artifacts\npc\reports\phase4-task-catalog-resource-backed-both.json`
  - Passed: 1 result, 0 failures.
  - Catalog validation: 28 actions, 9 sequences.
- `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -Case npc_behavior_shared_task_definitions_cover_phase4_goals -ReportPath artifacts\npc\reports\phase4-shared-task-definitions-both.json`
  - Passed: 1 result, 0 failures.
- `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -Case npc_behavior_goal_target_validation_reachable_navmesh -ReportPath artifacts\npc\reports\phase4-goal-target-validation-both-rerun.json`
  - Passed: 1 result, 0 failures.
  - Verifies reachable semantic targets pass and unreachable explicit targets fail with `semantic_target_unreachable`.
- `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -Case npc_behavior_day_forager_goal_plan_shape -ReportPath artifacts\npc\reports\phase4-smoke-forager-catalog-both-final.json`
  - Passed: 1 result, 0 failures.
  - Verifies the forager plan now uses the shared resource-loop task sequence and keeps the forage source as a pending semantic target.

## Suite Verification

- `.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase4-behavior-both.json`
  - Passed: 40 results, 0 failures.
- `.\tools\npc\run-npc-interaction-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase4-interaction-both.json`
  - Passed: 33 results, 0 failures.
- `.\tools\npc\run-real-tutorial-playthrough.ps1 -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase4-real-tutorial-playthrough.json`
  - Passed: finished, 7 results, `failureCount=0`, process exit 0.
- `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase4-all-npc-both.json`
  - Passed: 13 child runners, `failureCount=0`.
- `.\tools\run-npc-navigation-tests.ps1`
  - Passed: 11 results, 0 failures.
- `.\tools\run-world-signature.ps1`
  - Passed: latest `atlas-1492` signature matched tracked baseline hash `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.
- `git diff --check`
  - Passed with CRLF warnings only.

## Branch Gate

- `.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure -ReportPath artifacts\test-runners\all-test-runners-phase4-branch.json`
  - Passed: 23 runners, 0 failures, `stoppedEarly=false`.
  - Duration: 533.331 seconds.
  - Broad playtest: 181 results, 0 failures.
  - NPC behavior tests, interaction tests, navigation integration, real tutorial wrapper, world signature, story playtest, visual captures, and broad playtest all passed inside the gate.
  - Real tutorial wrapper: `failureCount=0`, script scan passed in aggregate stdout.

## Notes

- Initial isolated behavior runs caught a GDScript type inference issue and an outdated forager plan-shape expectation before aggregate escalation.
- World signature remained unchanged; no atlas baseline update was required.
- Phase 5 remains open for tooling, scenario sandboxing, route/task/door/slot artifact export, and fast targeted runner additions.
