# Mature Nav Phase 5: Tooling And Scenario Sandbox

Date: 2026-06-28
Branch: `codex/mature-navmesh-phase5-tooling-scenarios`

## Scope

Phase 5 implements the tooling and deterministic scenario slice from `CODEX_MATURE_NAV_PLAN.md`:

- Add in-game debug overlay and artifact export for route, task, door, and slot state.
- Add deterministic scenario scenes for crowded doors, market workday, night shelter, terrain edit, prop removal, and tutorial automation.
- Add fast targeted runners so failures can be isolated before rerunning full aggregates.

## Implementation

- Added `NpcDebugStateExporter` as the shared route/task/door/slot export schema for observation artifacts and live runtime debug state.
- Extended `NpcObservationRunner` with the six Phase 5 scenarios and kept the existing six observation scenarios under `Scenario All`.
- Added observation assertions that every scenario emits route/task/door/slot debug data and nonempty overlay lines.
- Added deterministic scene entrypoints:
  - `NpcScenarioCrowdedDoors.tscn`
  - `NpcScenarioMarketWorkday.tscn`
  - `NpcScenarioNightShelter.tscn`
  - `NpcScenarioTerrainEdit.tscn`
  - `NpcScenarioPropRemoval.tscn`
  - `NpcScenarioTutorialAutomation.tscn`
- Added `tools/npc/run-npc-scenario-tests.ps1` as the fast Phase 5 scenario wrapper. `-Scenario All` runs exactly the six Phase 5 scenarios.
- Extended `tools/npc/run-npc-observation-tests.ps1` so the new scenarios can also be run individually through the existing observation harness.
- Wired runtime NPC debug state into the F3 performance HUD through `MainDiscoveryFlow.debug_performance_state()` and `GameHudRenderer.set_performance()`.
- Added broad playtest smoke coverage so `performance_playtest_debug_hud` now requires the live NPC debug overlay text and a valid route/task/door/slot export.

## Focused Verification

- `.\tools\npc\run-npc-scenario-tests.ps1 -Scenario TutorialAutomation -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase5-scenario-tutorial-automation-overlay.json`
  - Passed: 1 result, 0 failures.
  - Verifies tutorial automation debug export and overlay assertions.
- `.\tools\npc\run-npc-scenario-tests.ps1 -Scenario All -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase5-scenarios-all-overlay.json`
  - Passed: 6 Phase 5 scenarios, 0 failures.
  - Duration: 3.772 seconds.
- `.\tools\npc\run-npc-observation-tests.ps1 -Scenario All -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase5-observation-all-overlay.json`
  - Passed: 12 scenarios, 0 failures.
  - Review summary: 22 captures, 12 traces, 0 door safety failures, 0 schedule failures, 0 repair failures.
- Direct scene entrypoint check for `res://scenes/testing/npc/NpcScenarioPropRemoval.tscn`
  - Report: `artifacts\npc\reports\phase5-scene-prop-removal.json`.
  - Passed: 1 result, 0 failures.
- `.\tools\run-playtest.ps1 -Seed atlas-1492 -ReportPath artifacts\playtest-phase5-overlay.json`
  - Passed: 181 results, 0 failures.
  - Verifies the live F3 performance HUD includes valid NPC debug route/task/door/slot state.

## Suite Verification

- `.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase5-all-npc-branch.json`
  - Passed: 13 child runners, 0 failures.
  - Duration: 97.017 seconds.
- `.\tools\npc\run-real-tutorial-playthrough.ps1 -Seed atlas-1492 -ReportPath artifacts\npc\reports\phase5-real-tutorial-branch.json`
  - Passed: finished, 7 results, `failureCount=0`, process exit 0, script scan passed.
- `.\tools\run-npc-navigation-tests.ps1`
  - Passed: 11 results, 0 failures.
- `.\tools\run-world-signature.ps1`
  - Passed: latest `atlas-1492` signature matched the tracked baseline.
- `git diff --check`
  - Passed with CRLF warnings only.

## Branch Gate

- `.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -StopOnFailure -ReportPath artifacts\test-runners\all-test-runners-phase5-branch.json`
  - Passed: 23 runners, 0 failures, `stoppedEarly=false`.
  - Duration: 518.042 seconds.
  - Broad playtest: 181 results, 0 failures.
  - Real tutorial wrapper, NPC aggregate, navigation integration, world signature, story playtest, visual captures, and broad playtest all passed inside the gate.

## Notes

- A short `DayWork` runtime performance observation loaded the main scene and exercised `debug_performance_state()`, but it was not used as a Phase 5 acceptance gate because the existing strict performance thresholds failed on route graph spike metrics unrelated to the overlay wiring.
- World generation stayed deterministic; no world signature baseline update was required.
- Phase 6 remains open for legacy live-route removal and acceptance hardening.
