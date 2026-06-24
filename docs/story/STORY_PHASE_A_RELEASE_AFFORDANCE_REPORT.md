# Story Phase A Release Affordance Report

Date: 2026-06-24

## Scope

Implemented Phase A only: make the existing Gloam Hart release route reachable through normal player input during the active encounter.

No new Worldmarks, campaign content, visuals/assets, rewards, aftermath behavior, debug commands, or save schema changes were added.

## Changed Files

- `scripts/MainCore.gd`
  - Added story release input state evaluation.
  - Added the player-facing release prompt provider.
  - Added the normal input release attempt handler.
- `scripts/MainWorldEntities.gd`
  - Added `KEY_R` handling for the active Gloam Hart release affordance.
  - Added release prompt priority in `focused_interaction_prompt()`.
- `scripts/story/encounters/GloamHartEncounter.gd`
  - Split phase gating from release-route gating.
  - Shows `You do not know the old rite.` once the player reaches the release window without the historical clue.
- `scripts/story/testing/StoryPlaytestRunner.gd`
  - Added `gloam_hart_release_normal_input_affordance`.
  - Added a synthetic normal `KEY_R` input helper.
- `docs/story/STORY_PHASE_A_RELEASE_AFFORDANCE_REPORT.md`
  - This report.

## Release Affordance Responsibilities

- `MainCore.story_release_input_state()`
  - Reads existing encounter, quest fact, and Worldmark resolution state.
  - Determines whether the player is in an active encounter, phase 3 release window, has the historical clue, has completed boundary/countermeasure work, has `releaseRouteAvailable`, and has not already resolved the Worldmark.
- `MainCore.story_release_input_prompt()`
  - Returns `[R] Release rite ready` only when all release readiness conditions are true.
  - Does not emit story events.
- `MainCore.try_story_release_input()`
  - Consumes normal `R` input only during an active Worldmark encounter.
  - Blocks release before phase 3 with `The release rite is not ready`.
  - Blocks phase 3 release without the historical clue with `You do not know the old rite.`
  - Delegates successful release to the existing `try_release_story_worldmark()` source operation.

## Event Hooks Added

- No new story event types were added.
- No HUD polling event emission was added.
- Successful release still emits through the existing source operation:
  - `MainCore.try_release_story_worldmark()`
  - `WorldmarkEncounterController.try_release_active_encounter()`
  - `GloamHartEncounter.try_release()`
  - `WorldmarkEncounterController.resolve_region()`
  - existing `story_worldmark_resolved`

## Save/Load Behavior

- `SAVE_VERSION` remains `1`.
- No save payload shape changes were made.
- Release state continues to persist through the existing Worldmark encounter state and resolution fields.
- The new deterministic test saves after normal-input release, reloads the snapshot, and verifies:
  - `resolution == "release"`
  - `rewardsGranted == true`
  - release rewards remain stable after load.

## Deterministic Test Results

Command:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath .\artifacts\story\phase-a-release-affordance-story-playtest-report.json
```

Result:

- Passed: true
- Count: 48
- Failures: 0
- New test: `gloam_hart_release_normal_input_affordance`

New test coverage:

- Prompt hidden before phase 3.
- Release input before phase 3 does not resolve or grant rewards.
- Prompt hidden without historical clue.
- Phase 3 release input without historical clue shows `You do not know the old rite.`
- Prompt appears as `[R] Release rite ready` only when the release route is fully ready.
- Normal `KEY_R` input resolves release.
- Duplicate input after release does not duplicate rewards or resolution events.
- Slay route still works.
- Save/load after release remains stable.

## Functional Playtest Result

Command:

```powershell
.\tools\run-playtest.ps1 -ReportPath .\artifacts\story\phase-a-release-affordance-functional-playtest-report.json
```

Result:

- Passed: true
- Count: 171
- Failures: 0

## Visual Captures

Command:

```powershell
.\tools\run-visual-captures.ps1
```

Result:

- Exit code: 0
- Captures written: 10 cases in `artifacts/visual/latest`
- Report: `artifacts/visual/latest/visual-captures.json`

Observed warning:

- Godot emitted repeated existing `NpcSystem.update_forager_goal` freed-instance script errors during visual capture.
- This is outside the Phase A release path and was not changed here.

## Risks / TODOs

- The new release action uses `R`; the controls/tutorial text does not yet advertise this outside the encounter prompt.
- The release prompt is intentionally global during the valid encounter window rather than raycast-targeted, because the Hart release is an encounter-state action, not a block/NPC interaction.
- Visual capture emitted unrelated NPC freed-instance errors; consider a separate small bugfix pass for `NpcSystem.update_forager_goal`.
