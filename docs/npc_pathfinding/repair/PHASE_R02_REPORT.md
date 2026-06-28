# Phase R02 Report - Active Motion Cadence and Real Tutorial Recovery

Branch: `npc-pathfinding/repair-02-active-motion-cadence`

Base stack commits:

- R00 characterization: `697e8af5731146d6f43b8fd8d189e30f0ab78b84`
- R01 stale smart-object lifetime fix: `d549bd279adb897120d61f1a4393d94fbee127c9`

Status: PASS for R02 branch acceptance gates. Merge to `master` is allowed after this report is committed.

## Implementation Summary

- Split NPC update cadence so active actors advance physical route motion every frame even when higher-level brain work is budgeted.
- Kept standalone NPC test updates in the same navigation frame path used by the main `update_npcs` loop.
- Repaired job/action motion continuity for active job phases, guard/home/job/idle phases, and route retry behavior for foragers.
- Tightened strict arrival handling for scripted and job goals so partial route progress is not silently treated as action success.
- Added navigation-derived resource approach slots and stale job reservation cleanup.
- Added live diagnostics for real tutorial NPC motion, including force/script metadata, route/corridor state, requested/applied velocity, collision contacts, and motor displacement.
- Fixed fresh zero-velocity avoidance callbacks by falling back to deterministic predictive avoidance when the callback is fresh but unusably zero.
- Added explicit cleanup for avoidance agents, route movement controllers, navigation coordinators, `NpcPathing`, and `NpcSystem`.
- Added audio shutdown cleanup so looped WAV/MP3 players stop, detach streams, and clear cached audio resources before exit. This preserves the wrapper's ObjectDB leak scan as a real gate.
- Hardened the real tutorial wrapper exit policy so it reports the wrapper exit code, report failure count, and script scan status explicitly.

## Failures Found and Fixed

- Full NPC gate initially failed on `real_tutorial_playthrough` because Mira's motion controller trusted a fresh `NavigationAgent3D` safe-velocity callback that returned `Vector3.ZERO`. Gameplay diagnostics showed route planning, brain ticks, and motion ticks were alive while requested/applied motor velocity stayed zero. The avoidance adapter now uses deterministic predictive fallback in this case and records `zeroCallbackFallbacks`.
- After the movement fix, the real tutorial gameplay report passed but the wrapper still failed on its forbidden log scan. Verbose Godot output identified leaked `AudioStreamWAV`, `AudioStreamMP3`, `AudioStreamPlaybackWAV`, and `AudioStreamPlaybackMP3` instances. `AudioEffectsSystem.shutdown_audio()` now stops all players, detaches stream references, and clears cached resources during `_exit_tree()`.
- The real tutorial wrapper then passed with no script-error or ObjectDB matches.

## Focused R02 Coverage

Focused real tutorial wrapper after movement fix:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\real-tutorial-r02-zero-callback-fix.json
```

Result:

- `passed=true`
- `failureCount=0`
- Mira moved about `70m`
- max flat speed `6.401`

Focused avoidance suite after zero-callback fallback:

```powershell
.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\avoidance-r02-zero-callback-fix.json
```

Result:

- `resultCount=32`
- `failureCount=0`
- New case: `npc_avoidance_zero_fresh_callback_falls_back`

Focused real tutorial wrapper after audio cleanup:

```powershell
.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\real-tutorial-r02-audio-cleanup.json
```

Result:

- wrapper exit code `0`
- `passed=true`
- `failureCount=0`
- `processExitCode=0`
- `processStopReason=completed`
- `scriptErrorScan.status=passed`
- `scriptErrorScan.matchCount=0`

## Full NPC Gate on Branch

Command:

```powershell
.\tools\npc\run-all-npc-tests.ps1 -TimeMode Both -Seed atlas-1492 -ReportPath artifacts\npc\reports\all-npc-r02-after-audio-cleanup.json
```

Result:

- wrapper exit code `0`
- `resultCount=13`
- `failureCount=0`
- failed suites: none

Real tutorial child report:

- Artifact: `artifacts/npc/reports/real_tutorial_playthrough-both.json`
- `passed=true`
- `failureCount=0`
- `processExitCode=0`
- `scriptErrorScan.status=passed`

## Repository All-Runner Gate on Branch

Command:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492 -ReportPath artifacts\test-runners\all-test-runners-r02-after-audio-cleanup.json
```

Registry:

- `tools/test-runner-registry.json`

Result:

- wrapper exit code `0`
- `resultCount=11`
- `failureCount=0`
- `stoppedEarly=false`

Runner evidence:

| Runner | Exit | Passed | Duration |
| --- | ---: | --- | ---: |
| `npc_focused` | 0 | true | 55.876s |
| `npc_observation_dusk` | 0 | true | 0.650s |
| `npc_observation_midnight` | 0 | true | 0.638s |
| `npc_observation_phase12` | 0 | true | 3.575s |
| `world_signature` | 0 | true | 12.853s |
| `visual_manifest` | 0 | true | 0.093s |
| `npc_navigation_integration` | 0 | true | 25.214s |
| `npc_real_tutorial_playthrough` | 0 | true | 28.369s |
| `story_playtest` | 0 | true | 61.773s |
| `visual_captures` | 0 | true | 48.107s |
| `playtest` | 0 | true | 141.362s |

Key report paths:

- `artifacts/test-runners/all-test-runners-r02-after-audio-cleanup.json`
- `artifacts/test-runners/world-signature-atlas-1492.json`
- `artifacts/test-runners/npc-navigation-report.json`
- `artifacts/test-runners/npc-real-tutorial-playthrough.json`
- `artifacts/test-runners/story-playtest-report.json`
- `artifacts/test-runners/visual/visual-captures.json`
- `artifacts/test-runners/playtest-report.json`

## Static Check

Command:

```powershell
git diff --check
```

Result:

- no whitespace errors
- Git reported LF-to-CRLF working-copy warnings for touched text files only

## Acceptance Mapping

- Real tutorial NPC regression is fixed: covered by `real-tutorial-r02-audio-cleanup.json`, `real_tutorial_playthrough-both.json`, and the all-runner `npc_real_tutorial_playthrough` row.
- Active NPCs continue physical route motion while brain work is budgeted: covered by the full playtest, focused NPC gate, real tutorial movement trace, and behavior/NPC focused suites inside `run-all-npc-tests.ps1`.
- Fresh zero-velocity avoidance callbacks no longer freeze an actor with a valid deterministic fallback: covered by `npc_avoidance_zero_fresh_callback_falls_back`.
- Wrapper leak and script-error scans remain strict: the ObjectDB audio leak was fixed in production cleanup rather than filtered from the scanner.
- World signature remains accepted and green under the registered all-runner gate.
- Story, visual capture, visual manifest, navigation integration, and broad playtest gates remain green on the branch.

## Master Verification

Pending at branch-report time. After merge, rerun:

```powershell
.\tools\run-all-test-runners.ps1 -Seed atlas-1492
```

and record the merged `master` result in the final handoff.

## Verdict

R02 branch gates pass. Merge is allowed.
