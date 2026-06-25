# Phase 00 Report - Baseline Freeze, Focused Harness, and Controlling Documentation

## 1. Phase Identification

- Phase: 00 - Baseline Freeze, Focused Harness, and Controlling Documentation
- Branch: `npc-pathfinding/phase-00-baseline-harness`
- Base branch: `master`
- Base commit: `329416babe993377e6442cc77f9b3b2617302675`
- Branch implementation commit: `5e1a08aaea48a9740782fb192a6623db784ec983`
- Merge commit: `8ba638e4b6e4b1c445cef14973afe1f4640ff1a8`
- Dates: 2026-06-25
- Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`

## 2. Objective

Phase 00 creates deterministic NPC-focused test infrastructure, freezes pre-replacement behavior evidence, and updates controlling documentation before any NPC runtime movement, autonomy, door, route, save, visual, story, or world-generation behavior changes.

## 3. Pre-Phase State

- `git status --short` before Phase 00 edits showed one pre-existing modified tracked baseline: `artifacts/baselines/world-signature/atlas-1492.json`.
- That baseline artifact remained unstaged and outside the Phase 00 changes. SHA-256 at audit time: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.
- The legacy NPC stack still uses `StaticBody3D` NPC bodies, direct transform movement in `NpcLocomotionController.gd`, blind door toggles through `MainRuntimeTools.gd`, single-surface route search, frame-TTL reservations, and porch fallback home semantics.
- Detailed baseline architecture and file/line debt are recorded in `docs/npc_pathfinding/BASELINE_AUDIT.md`.

## 4. Implementation Summary

Phase 00 added a separate NPC-focused contract runner that runs through a dedicated scene and emits a fresh JSON report keyed by suite, case, time mode, seed, branch, commit, Godot version, artifacts, metrics, and run token. The runner supports day, night, both, and transition time modes, case filtering, deterministic seed input, watchdog timeout, trace/screenshot directories, and stale-report rejection.

The repository-wide all-runner gate now uses a machine-readable registry and attempts every required runner before returning failure. It records exit code, duration, report path, and report freshness for each runner.

No gameplay behavior was changed. The added contract tests characterize existing behavior and wrapper guarantees only.

## 5. Files Added, Changed, Or Removed

Documentation:

- Added `docs/npc_pathfinding/BASELINE_AUDIT.md`.
- Added `docs/npc_pathfinding/PHASE_00_REPORT.md`.
- Updated `AGENTS.md` to name `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md` as the controlling NPC implementation specification.
- Updated `CODEX_NPC_PATHFINDING_COMPLETION_PLAN.md` with a superseded notice.

Focused NPC harness:

- Added `scripts/testing/npc/NpcAutonomyTestRunner.gd`.
- Added `scripts/testing/npc/NpcTestAssertions.gd`.
- Added `scripts/testing/npc/NpcTestClock.gd`.
- Added `scenes/testing/npc/NpcAutonomyTest.tscn`.
- Added `tools/npc/run-npc-suite.ps1`.
- Added `tools/npc/run-npc-contract-tests.ps1`.
- Added `tools/npc/run-all-npc-tests.ps1`.
- Added `tools/npc/npc-suite-registry.json`.

Repository gate:

- Added `tools/test-runner-registry.json`.
- Added `tools/run-all-test-runners.ps1`.
- Updated `.gitignore` for ignored NPC and all-runner transient artifacts.

Removed files: none.

## 6. Data/API Contracts Introduced Or Changed

Focused NPC environment inputs:

- `VOXEL_NPC_TEST_SUITE`
- `VOXEL_NPC_TEST_CASE`
- `VOXEL_NPC_TIME_MODE`
- `VOXEL_NPC_TEST_SEED`
- `VOXEL_NPC_TEST_REPORT`
- `VOXEL_NPC_TEST_PROGRESS`
- `VOXEL_NPC_TEST_TRACE_DIR`
- `VOXEL_NPC_TEST_SCREENSHOT_DIR`
- `VOXEL_NPC_TEST_RUN_TOKEN`
- `VOXEL_NPC_TEST_WATCHDOG_SECONDS`
- `VOXEL_GIT_BRANCH`
- `VOXEL_GIT_COMMIT`

Focused report schema includes:

- `schemaVersion`, `suite`, `caseFilter`, `timeMode`, `seed`, `branch`, `gitCommit`, `engineVersion`, `startedUtc`, `finishedUtc`, `durationSeconds`, `resultCount`, `failureCount`, `results`, `metrics`, `artifacts`, `runToken`.

Registry contracts:

- `tools/npc/npc-suite-registry.json` lists every NPC suite implemented up to the active phase.
- `tools/test-runner-registry.json` lists the mandatory phase-boundary repository runners and command arguments.

## 7. Migration/Compatibility Behavior

No save migration or gameplay compatibility path was introduced. The save characterization contract records current version/default-load behavior so later phases can preserve additive save semantics.

The legacy focused NPC navigation runner remains callable and is registered in the repository all-runner gate.

## 8. Focused Test Evidence

Primary command:

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both
```

Evidence:

- Report path: `artifacts/npc/reports/contract-both.json`
- SHA-256: `96B271776430BD92A94862EF819C07B629C3F1D544C055F714407B3A00490318`
- Result count: 18
- Failure count: 0
- Godot report duration: 0.018 seconds
- Wrapper suite aggregate duration: 1.011 seconds in `artifacts/npc/reports/all-npc-both.json`
- Metrics: 10 selected cases, 18 selected runs, 50 assertions
- Run token: `70a23118e9cf41b28073aa116bd80e66`

Minimum Phase 00 IDs covered:

- `npc_contract_clock_day_snapshot`
- `npc_contract_clock_night_snapshot`
- `npc_contract_runner_filters`
- `npc_contract_report_freshness`
- `npc_contract_report_schema`
- `npc_contract_rng_stream_isolation_baseline`
- `npc_contract_player_motor_characterization_baseline`
- `npc_contract_existing_save_defaults_baseline`

Additional Phase 00 guard IDs:

- `npc_contract_existing_npc_navigation_runner_callable`
- `npc_contract_all_runner_registry_baseline`

Filter and failure behavior:

- `.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_report_schema -TimeMode Day`: exit 0, 1 result, 0 failures, fresh run token `3388b552699749028a04064e5c967b00`.
- `.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_report_schema -TimeMode Night`: exit 0, 1 result, 0 failures.
- `.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_report_schema -TimeMode Both`: exit 0, 2 results, 0 failures, fresh run token `a906193f5e2b4f8a8bd076f5c7d4d79b`.
- `.\tools\npc\run-npc-contract-tests.ps1 -Case npc_contract_intentional_missing_case -TimeMode Day`: returned nonzero as expected, produced 1 result and 1 failure with fresh run token `721f8a668b8c42bbbc4f73e9203133af`.

Check-only parser gate:

```powershell
C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe --headless --path . --check-only --script res://scripts/testing/npc/NpcAutonomyTestRunner.gd
```

Result: exit 0.

## 9. Day/Night Evidence

The focused contract suite ran in `Both` mode and generated separate day/night records for time-sensitive cases.

Day snapshot:

- ID: `npc_contract_clock_day_snapshot`
- `timeOfDay`: 0.25
- `clockPhase`: 0.5
- `displayHour`: 12.0
- `scheduleState`: `day`
- `frozen`: true

Night snapshot:

- ID: `npc_contract_clock_night_snapshot`
- `timeOfDay`: 0.75
- `clockPhase`: 0.0
- `displayHour`: 0.0
- `scheduleState`: `night`
- `frozen`: true

Both mode selected 18 runs across day and night. No screenshots were required for Phase 00 contract tests; trace and screenshot artifact directories are created by the wrapper for later phases.

## 10. Full All-Runner Evidence On Phase Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1
```

Final phase-branch report:

- Path: `artifacts/test-runners/all-test-runners-report.json`
- SHA-256: `F2E2106C42BEE34E639B3C932453BF94B1FC66F0FC41A3D82D110176E0AE3BA3`
- Started: `2026-06-25T14:27:48.1839450Z`
- Finished: `2026-06-25T14:34:07.1913488Z`
- Duration: 379.008 seconds
- Result count: 7
- Failure count: 0

Registered runner results:

| Runner | Exit | Passed | Duration seconds | Report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | true | 1.345 | `artifacts/npc/reports/all-npc-both.json` |
| `npc_navigation_legacy` | 0 | true | 50.168 | `artifacts/test-runners/npc-navigation-report.json` |
| `playtest` | 0 | true | 197.947 | `artifacts/test-runners/playtest-report.json` |
| `story_playtest` | 0 | true | 62.207 | `artifacts/test-runners/story-playtest-report.json` |
| `world_signature` | 0 | true | 14.246 | `artifacts/test-runners/world-signature-atlas-1492.json` |
| `visual_captures` | 0 | true | 52.995 | `artifacts/test-runners/visual/visual-captures.json` |
| `visual_manifest` | 0 | true | 0.047 | no JSON report |

Intermediate failure encountered and not hidden:

- The first repository-wide all-runner attempt reached all 7 runners and returned exit 1 because the broad `playtest` runner failed `held_torch_terrain_material_flickers`.
- Failed sample details: `range 6.86..6.86 delta 0.01 energy 3.62..3.62 delta 0.00`.
- The isolated rerun `.\tools\run-playtest.ps1 -ReportPath artifacts\test-runners\playtest-rerun-report.json` passed 181/181 results; the held torch assertion passed with `range 6.60..6.66 delta 0.06 energy 2.64..2.70 delta 0.06`.
- The final repository-wide all-runner attempt above passed with 7/7 registered runners. No code was changed to mask or retry that broad assertion.

## 11. Full All-Runner Evidence On Merged `master`

Merge command:

```powershell
git switch master
git merge --no-ff npc-pathfinding/phase-00-baseline-harness -m "Merge Phase 00: baseline NPC contract harness"
```

Master gate command:

```powershell
.\tools\run-all-test-runners.ps1
```

Merged `master` report:

- Merge commit: `8ba638e4b6e4b1c445cef14973afe1f4640ff1a8`
- Path: `artifacts/test-runners/all-test-runners-report.json`
- SHA-256: `CDC39E8DB6794F6501C5B6A6D62B65FA351F2DBC693C6F00909186BB39BBC6CA`
- Started: `2026-06-25T14:38:53.1523407Z`
- Finished: `2026-06-25T14:45:06.1771369Z`
- Duration: 373.026 seconds
- Result count: 7
- Failure count: 0

Registered runner results on merged `master`:

| Runner | Exit | Passed | Duration seconds | Report |
| --- | ---: | --- | ---: | --- |
| `npc_focused` | 0 | true | 1.275 | `artifacts/npc/reports/all-npc-both.json` |
| `npc_navigation_legacy` | 0 | true | 46.795 | `artifacts/test-runners/npc-navigation-report.json` |
| `playtest` | 0 | true | 195.781 | `artifacts/test-runners/playtest-report.json` |
| `story_playtest` | 0 | true | 63.028 | `artifacts/test-runners/story-playtest-report.json` |
| `world_signature` | 0 | true | 13.892 | `artifacts/test-runners/world-signature-atlas-1492.json` |
| `visual_captures` | 0 | true | 52.159 | `artifacts/test-runners/visual/visual-captures.json` |
| `visual_manifest` | 0 | true | 0.048 | no JSON report |

Merged `master` artifact details:

- Focused contract: 18 results, 0 failures, SHA-256 `F23D3A608DC1FAAD1082582FBFC59ABFB32A070D3A4F939B591EE1F77C8E07D8`.
- Legacy NPC navigation: 11 results, 0 failures, SHA-256 `937FCB88743ED7CD0B0665E96A15A1B4E6D5D3434467D51B502FE7923CC620A1`.
- Broad playtest: 181 results, 0 failures, SHA-256 `9479C8413DAE15C13AC952EA0CD06D8EA2061E7866D27D84E6226FB5980F940E`.
- Story playtest: 49 results, 0 failures, SHA-256 `6FC8C09595D4F3A17912E920928EB11CF815AB37B3B4F590903AF10CFBCDA7A5`.
- World signature: matched baseline, SHA-256 `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.
- Visual captures: 11 cases, SHA-256 `C38D2B6DB9092F3EFCA54C4EA2367E91330B55B5BC6C7B6D1AA7FAA4D1C083C1`.
- Broad held-torch assertion on merged `master`: passed with `range 6.85..6.95 delta 0.10 energy 2.67..2.74 delta 0.07`.

## 12. Performance And Boundedness Metrics

Focused NPC harness:

- Watchdog default: 45 seconds.
- `--fixed-fps 60` used by `tools/npc/run-npc-suite.ps1`.
- Contract `Both` report duration: 0.018 seconds inside Godot.
- NPC suite wrapper aggregate duration: 1.011 seconds.
- The runner deletes stale report/progress files before launch and rejects mismatched `runToken` values.

Repository gate:

- Attempts every registered runner before returning a failure code.
- Final branch duration: 379.008 seconds.
- Longest runner: broad playtest, 197.947 seconds.

## 13. Determinism/World-Signature Evidence

Pre-phase baseline:

- `artifacts/world-signature/latest/atlas-1492.json` SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.

Phase-branch all-runner world signature:

- Path: `artifacts/test-runners/world-signature-atlas-1492.json`
- SHA-256: `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`
- Result: matched baseline
- Seed: `atlas-1492`
- Loaded chunks: 49
- Terrain samples: 12
- Props: 1124
- Town home records: 1

Broad runner snapshots:

- Broad playtest report: 181 results, 0 failures, SHA-256 `E28287C8F3B82A3384DF3CC4C358940EB00AA921F7C48119C647F7FF5706ACE7`.
- Story playtest report: 49 results, 0 failures, SHA-256 `6FC8C09595D4F3A17912E920928EB11CF815AB37B3B4F590903AF10CFBCDA7A5`.
- Visual captures report: 11 cases, SHA-256 `C38D2B6DB9092F3EFCA54C4EA2367E91330B55B5BC6C7B6D1AA7FAA4D1C083C1`.

## 14. Invariant Checklist

- Focused harness can run one suite: evidenced by `run-npc-contract-tests.ps1`.
- Focused harness can run one case: evidenced by `-Case npc_contract_report_schema`.
- Focused harness can run day, night, and both: evidenced by day/night/both filter runs and `contract-both.json`.
- Injected failure produces nonzero runner result and fresh failure report: evidenced by `npc_contract_intentional_missing_case`.
- All-runner attempts and records every registered runner: evidenced by 7 result rows in `all-test-runners-report.json`.
- Existing focused NPC navigation tests pass unchanged: 11 results, 0 failures, SHA-256 `2846C917E53A8CAE7AEAA43BECC953A42376719DB8FE11436E3E91B0B600B7CE`.
- Broad playtest, story playtest, world signature, visual captures, and visual-manifest validation pass on the phase branch: evidenced in Section 10.
- No gameplay behavior changed: only test harness, docs, wrapper, registry, and ignore-list files were edited.
- Phase report contains baseline, phase-branch, and merged `master` evidence: yes.

## 15. Deviation Register

- None for implementation scope.
- Process note: Section 11 was populated after the branch commit, no-fast-forward merge, and required `master` all-runner gate because the merge hash and master evidence did not exist before those steps.

## 16. Known Issues/Debt

- Baseline NPC debt remains as documented in `BASELINE_AUDIT.md`: `StaticBody3D` NPCs, direct transform movement, blind door toggles, single-surface routing, small route cap, frame-TTL reservations, and porch fallback semantics.
- A transient broad playtest held-light flicker assertion failure occurred during the first all-runner attempt. It passed on isolated rerun and on the final all-runner attempt. This is recorded as a non-NPC broad-runner timing risk, not as a Phase 00 gate failure after the green branch run.
- The pre-existing modified tracked baseline artifact `artifacts/baselines/world-signature/atlas-1492.json` remains outside the Phase 00 staged set.

## 17. Static Audit Results

Static findings are recorded in `docs/npc_pathfinding/BASELINE_AUDIT.md` with file/line evidence for:

- NPC `StaticBody3D` creation and API use.
- Direct NPC transform movement.
- Door toggles and delayed close semantics.
- Scene-scan/hash navigation revision behavior.
- Route iteration cap and partial fallback semantics.
- Reservation TTL/local avoidance behavior.
- Guard duty and `canFight` conflation.

These are baseline findings for later phases, not Phase 00 implementation changes.

## 18. Risk Assessment For Next Phase

Phase 01 can start from merged `master` after this report update is committed.

Main risks for Phase 01:

- Runtime ownership changes can accidentally alter deterministic world generation or save/load behavior.
- Legacy NPC route dictionaries and new typed blackboard state must coexist without split authority.
- The broad playtest has one observed transient visual assertion; failures must still be inspected instead of bypassed.
- Later phases must keep NPC randomness isolated from terrain/town RNG.

## 19. Final Verdict

Phase 00 passes its branch and merged `master` gates. Phase 01 may begin from the updated green `master` after this report update is committed.
