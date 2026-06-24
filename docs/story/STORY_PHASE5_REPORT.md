# Story Phase 5 Report

## Changed files

- `scripts/story/arcs/GloamHartArc.gd`
- `scripts/story/StoryQuestSystem.gd`
- `scripts/MainSaveState.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE5_REPORT.md`

## New story system responsibilities

- `GloamHartArc` defines the authored opening contract for The Storm That Stays: quest ID, arc ID, Gloam Hart definition ID, the Mira/Sera/travel opening stages, and handoff facts.
- `StoryQuestSystem` now attaches the authored opening handoff metadata to the first quest while preserving the existing deterministic region selection and later arc behavior.
- `MainSaveState` now handles old completed-tutorial saves that predate story data by starting the first story quest once after tutorial restore.
- `StoryPlaytestRunner` has a dedicated Phase 5 regression for the opening handoff instead of expanding the broad playtest runner.

## Event hooks added

- No HUD polling hooks were added.
- The existing tutorial final rescue source event still starts `story.gloam_hart.storm`.
- Added a save-load source migration in `MainSaveState`: if an old save has completed the final tutorial rescue and has no first story quest, it emits `tutorial_final_rescue_complete` once through the normal story event path.
- Verified `npc_spoken_to` for Mira advances only from `speak_with_mira` to `speak_with_sera`.
- Verified `npc_spoken_to` for Sera advances only after Mira to `travel_to_affected_region`.
- Verified `story_region_entered` ignores unrelated regions and advances only when the selected affected region is entered.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Story data remains optional under the existing `story` save field.
- Old saves without story data and without completed tutorial state still load to empty story state.
- Old completed-tutorial saves without story data receive `story.gloam_hart.storm` once, then migrated saves preserve the quest without re-emitting the handoff.
- The selected affected region persists in campaign state as `firstAffectedRegionId` and is not reselected after save/load.
- Save/load round trips were verified at each opening stage: `speak_with_mira`, `speak_with_sera`, and `travel_to_affected_region`.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase5-story-playtest-report.json`
- Result: passed, 44 results, 0 failures.
- Phase 5 regression selected affected region `r:2,-1`, dominant biome `forest`, distance 1 from starter region `r:1,0`.
- The old completed-tutorial migration test loaded the old-style save, created exactly 1 first quest, saved the migrated state, reloaded it, and kept `tutorial_final_rescue_complete` at 1 event.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase5-playtest-report.json`
- Result: passed, 166 results, 0 failures.
- The command was rerun with a longer timeout after the first shell wrapper timed out just after writing a passing JSON report.

## Risks and TODOs

- This is a corrective forward Phase 5 artifact because later Gloam Hart phases were already committed out of order.
- The current branch already contains later clue, boundary-stone, encounter, journal, and aftermath content. The Phase 5 test therefore verifies the opening handoff and travel contract while accepting that entering the selected region now advances into the later `find_ordinary_clues` stage.
- The broad playtest exits 0 and the JSON report passes, but Godot still logs existing NPC freed-instance warnings during the broad run; no failing assertion is attached to those warnings.
- No separate manual interactive playthrough was performed beyond the automated tutorial final rescue and story handoff coverage.
