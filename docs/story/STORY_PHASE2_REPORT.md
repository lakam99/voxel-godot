# Story Phase 2 Report

Phase 2 implements The Storm That Stays quest skeleton on top of the Phase 1B
story foundation. It adds authored structured quest state, deterministic first
affected-region selection, Gloam Hart region marking, event-driven stage
progression, and debug dump support.

This phase does not add a Worldmark boss encounter, combat phases, rewards,
aftermath, LLM integration, new visuals, new animations, or major weather
overlays.

## Changed Files

- `docs/story/STORY_PHASE2_REPORT.md`
- `scripts/MainCore.gd`
- `scripts/MainInterface.gd`
- `scripts/MainSaveState.gd`
- `scripts/MainWorldEntities.gd`
- `scripts/TutorialDialogueSystem.gd`
- `scripts/story/RegionStoryGenerator.gd`
- `scripts/story/StoryDirector.gd`
- `scripts/story/StoryQuestSystem.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`

The current worktree also still contains the uncommitted Phase 1B production
story files and `STORY_PHASE1B_REPORT.md`.

## Quest Stages

The authored quest ID is `story.gloam_hart.storm`, labelled
`The Storm That Stays`. It starts only when
`tutorial_final_rescue_complete` is ingested by `StoryDirector`.

Implemented stage order:

- `speak_with_mira`
- `speak_with_sera`
- `travel_to_affected_region`
- `find_ordinary_clues`
- `optional_find_historical_clue`
- `prepare_countermeasure_placeholder`
- `retune_boundary_stones_placeholder`
- `encounter_locked_placeholder`

Progression is driven by story events:

- `npc_spoken_to` with `npcId=mira` advances only `speak_with_mira`.
- `npc_spoken_to` with `npcId=sera` advances only after Mira, during
  `speak_with_sera`.
- `story_region_entered` advances travel only for the selected affected region.
- `story_clue_found` with `clueKind=ordinary` counts unique ordinary clues.
- `story_clue_found` with `clueKind=historical` sets
  `historyClueFound`, `releaseRouteUnlocked`, and
  `optionalObjectives.learn_old_compact`.

Placeholder stages accept structured state only. They do not spawn clues,
boundary stones, encounters, rewards, or aftermath.

## Affected Region

The first affected region is selected deterministically from the starter region
using `seed_text`, stable region IDs, and pure terrain/biome queries. No base
terrain, town, prop, structure, loot, hostile, or gameplay RNG stream is
consumed or reordered.

For the tested default seed, the starter region is `r:1,0` and the selected
affected region is `r:2,-1`. The region record is marked with structured
Gloam Hart data:

- `arcId`: `storm_that_stays`
- `questId`: `story.gloam_hart.storm`
- `worldmark.definitionId`: `gloam_hart`
- `worldmark.domain`: `storm_and_light`
- `worldmark.condition`: `bound`
- `worldmark.desire`: `silence_the_old_lanterns`
- text IDs such as `story.gloam_hart.title` and
  `story.gloam_hart.stage.speak_with_mira`

## Debug Dump

`StoryDirector.debug_story_dump()` and `MainCore.debug_story_dump()` expose:

- current story region
- active quest ID
- current stage
- affected region
- ordinary clue count and IDs
- historical clue flag
- release unlock flag
- countermeasure/boundary placeholder flags
- recent story events

Pressing `F6` prints the structured dump to the console in debug play.

## Save/Load Behavior

- `SaveSystem.SAVE_VERSION` remains `1`.
- Story state remains optional under the additive `story` snapshot field.
- Old saves without `story` still restore empty/default story state.
- Quest state persists through `story.quests`.
- The selected affected region and marked Gloam Hart region persist through
  `story.campaign` and `story.regionRecords`.
- Dedupe remains in `StoryDirector`; quest facts also guard duplicate clue IDs
  and duplicate stage advancement.

## Story Test Results

Command:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase2-story-playtest-report.json
```

Result:

- Passed: true
- Result count: 19
- Failures: 0

Phase 2 coverage includes:

- old saves without story still load
- first arc does not start before tutorial completion
- `tutorial_final_rescue_complete` starts the first quest exactly once
- duplicate tutorial completion does not duplicate the quest
- Mira event advances only the Mira stage
- Sera event advances only after Mira
- entering another region does not advance travel
- entering the affected region advances travel
- ordinary clues count idempotently
- historical clue unlock flag persists
- quest save/load preserves state exactly
- debug story dump exposes quest, stage, affected region, found clues, and
  unlock flags

## Functional Playtest Results

Command:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase2-playtest-report.json
```

Result from JSON report:

- Passed: true
- Result count: 166
- Failures: 0

Console note:

- The functional run still prints the pre-existing NPC freed-instance errors
  noted in earlier reports.
- Godot still prints an `ObjectDB instances leaked at exit` warning for the
  headless runners.

## Risks And TODOs

- Generic town NPCs still do not have a player dialogue interaction source; the
  NPC quest hooks currently cover tutorial NPC interactions.
- Region entry is emitted from the exploration-state update path and is
  stateful, not from HUD state. It remains intentionally lightweight until a
  fuller exploration/story tracker exists.
- The quest uses structured placeholder stages for preparation, boundary stones,
  and encounter locking. Actual clue placement, countermeasure mechanics,
  boundary-stone interactions, encounter setup, rewards, and aftermath remain
  deferred.
- The selected region is marked as Gloam Hart data, but there are no new
  overlays, weather influence, visuals, animations, or boss content in this
  phase.
- Existing world-signature baseline drift and NPC freed-instance console errors
  remain separate known issues.
