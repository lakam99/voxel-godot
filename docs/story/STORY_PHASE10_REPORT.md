# Story Phase 10 Report

## Changed files

- `scripts/MainCore.gd`
- `scripts/MainInterface.gd`
- `scripts/MainSaveState.gd`
- `scripts/MainSetupScene.gd`
- `scripts/story/RegionAftermathSystem.gd`
- `scripts/story/SettlementStateSystem.gd`
- `scripts/story/StoryDialogueRouter.gd`
- `scripts/story/StoryJournalModel.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE10_REPORT.md`

## New story system responsibilities

- `RegionAftermathSystem` is a composed story node under `Main`, not a new `Main*.gd` inheritance layer.
- `RegionAftermathSystem` watches durable Worldmark resolution state and advances regional aftermath over deterministic in-game days.
- The aftermath state clears the storm, lowers hostile pressure, unlocks delayed settlement recovery, and records slay/release-specific regional flags.
- `SettlementStateSystem` is a composed story node under `Main` that keeps starter settlement recovery in the existing `StoryDirector.settlements` snapshot data.
- Settlement recovery upgrades the starter settlement from tier 0 struggling state to tier 1 secure state, records the chosen Gloam Hart resolution, opens trade/service/cozy-scene flags, and exposes resident activity, wildlife recovery, and guard mood.
- The implementation uses the current story dictionary data format instead of adding a separate settlement resource file.
- `StoryDialogueRouter` now reads post-resolution memory and aftermath settlement state for changed NPC lines.
- `StoryJournalModel` now surfaces storm, town, resident activity, and wildlife aftermath rows.

## Event hooks added

- No new global story events were added in Phase 10.
- Aftermath begins from the source-authored Worldmark resolution state written by the Phase 9 encounter controller.
- Time-based aftermath progression runs from `RegionAftermathSystem.update(delta)` and writes optional story state; HUD polling does not emit story events.
- Live NPC activity metadata is applied by the aftermath system to available NPC bodies after thresholds and after load reconstruction.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- All Phase 10 state is optional story data only.
- Region aftermath is saved under `story.regionRecords[regionId].worldmark.aftermathState`.
- Settlement recovery is saved through the existing `story.settlements.starter` snapshot field.
- Old saves without aftermath or settlement data load with no required migration.
- Loading after Worldmark resolution reconstructs settlement state and reapplies available live NPC activity metadata from durable story data.
- Beacon, rift, sanctuary, tutorial, objective, contract, visual, animation, and base save/load behavior are unchanged.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase10-story-playtest-report.json`
- Result: passed, 38 results, 0 failures.
- Added focused story tests for slay aftermath delayed settlement recovery, release aftermath wildlife/trade flags, dialogue memory, resident activity, and save/load reconstruction.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase10-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- Hostile pressure and route/service unlocks are currently durable story flags; later phases can wire them into spawning, map, service, or trading systems without changing the saved schema.
- Live NPC metadata after load depends on NPC bodies already being available; durable settlement `residentActivity` reconstructs even if no live NPC body is present at that instant.
- Broad playtest still prints existing shutdown warnings from unrelated NPC door cleanup/ObjectDB leak paths; the JSON report passes with 0 failures.
