# Story Phase 4 Report

## Changed files

- `scripts/story/data/StoryQuestState.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE4_REPORT.md`

## New story system responsibilities

- `StoryQuestState` validates and normalizes the dictionary-backed quest save format without changing the existing save schema.
- `StoryQuestSystem` remains the composed quest runtime under `StoryDirector`; it owns quest status, stage, tracked state, facts, optional objectives, and snapshot/restore behavior.
- `StoryDirector` remains the composed story coordinator under `Main`; it deduplicates source events, tracks event counts, and snapshots optional story data.
- `StoryPlaytestRunner` now has a dedicated Phase 4 source-event test instead of extending the broad `PlaytestRunner`.

## Event hooks added

- No new gameplay hook files were changed in this corrective Phase 4 patch; the source-operation hooks already exist and are now explicitly covered.
- Verified source-operation events:
  - `biome_discovered`
  - `town_discovered`
  - `mine_discovered`
  - `ruin_discovered`
  - `camp_discovered`
  - `shrine_discovered`
  - `tutorial_final_rescue_complete`
  - `npc_spoken_to`
- Verified `update_hud()` does not emit story events or mutate story event counts.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Story quest data remains optional under `story.quests`.
- Saves without story data continue to load through the existing empty/default story state path.
- Quest state snapshot/restore round-trips exactly for the validated quest dictionary.
- Restore reconstructs story state without replaying source events.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase4-story-playtest-report.json`
- Result: passed, 43 results, 0 failures.
- Added focused coverage for source-event ingestion, quest-state validation, quest snapshot/restore, shrine discovery event emission, and HUD refresh non-emission.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase4-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- This is a corrective forward Phase 4 artifact because later Gloam Hart work was already committed out of order.
- The broad playtest still prints existing shutdown warnings from unrelated NPC door cleanup/ObjectDB leak paths; the JSON report passes with 0 failures.
- Quest records remain dictionary-backed for compatibility with the existing optional story save shape.
