# Story Phase 1B Report

Phase 1B adds the production story foundation: composed story systems,
deterministic region records, additive story save data, idempotent fact
ingestion, and source-operation event hooks. It does not add Gloam Hart quest
content, boss encounters, LLM integration, rewards, visual changes, objective
changes, or contract changes.

## Changed Files

- `docs/story/STORY_PHASE1B_REPORT.md`
- `scripts/MainCore.gd`
- `scripts/MainInterface.gd`
- `scripts/MainSaveState.gd`
- `scripts/MainWorldEntities.gd`
- `scripts/TutorialDialogueSystem.gd`
- `scripts/TutorialRescueSystem.gd`
- `scripts/story/RegionStoryGenerator.gd`
- `scripts/story/StoryDirector.gd`
- `scripts/story/StoryEventBus.gd`
- `scripts/story/StoryQuestSystem.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`

## New Story System Responsibilities

- `StoryEventBus.gd` builds schema-versioned story event envelopes from
  gameplay facts and emits one `story_event` signal.
- `StoryDirector.gd` owns campaign shell state, generated region records,
  current story region, bounded duplicate keys, bounded debug event history, and
  event counters. It ingests events idempotently and generates region records on
  first regional fact.
- `StoryQuestSystem.gd` provides the composed quest-state owner and save/restore
  surface. It intentionally has no active Gloam Hart quest content yet.
- `RegionStoryGenerator.gd` maps cells to stable region IDs with
  `TOWN_REGION_CELLS` floor division and creates deterministic generic
  `pending_worldmark` region records from world seed plus region ID.

The systems are instantiated as child nodes from `MainCore.setup_story_systems()`.
No `Main*.gd` inheritance layer was added.

## Event Hooks Added

All hooks emit from existing source operations after the underlying gameplay fact
is first recorded:

- `tutorial_final_rescue_complete` from
  `TutorialRescueSystem.complete_final_night()`
- `biome_discovered` from first biome discovery in
  `MainWorldEntities.update_exploration_state()`
- `town_discovered` from first town discovery in
  `MainWorldEntities.update_exploration_state()`
- `mine_discovered`, `ruin_discovered`, and `camp_discovered` from
  `MainWorldEntities.discover_landmark()`
- `shrine_discovered` from `MainWorldEntities.discover_shrine_cache()`
- `npc_spoken_to` from `TutorialDialogueSystem.interact_with()` for the current
  interactable tutorial NPCs

The hooks use stable dedupe keys such as `discover:mine:<key>`,
`tutorial:final_rescue_complete`, and `npc_spoken:<npc_id>`. HUD refresh does
not inspect or synthesize story state.

## Save/Load Behavior

- `SaveSystem.SAVE_VERSION` remains `1`.
- New snapshots include an optional additive `story` dictionary.
- `MainSaveState.apply_save_snapshot()` restores `story` when present.
- Saves without a `story` field restore valid empty story state.
- Generated region records are persisted in `story.regionRecords`; the story
  round-trip test verifies restored records match exactly.
- Dedupe keys are bounded to 512 entries, and debug recent events are bounded to
  24 entries.

## Deterministic Test Results

Command:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase1b-story-playtest-report.json
```

Result:

- Passed: true
- Result count: 12
- Failures: 0

Covered checks:

- same seed + same region gives identical region story record
- same seed + different region gives different region story record
- different seed + same region gives different region story record
- negative coordinates use floor-division region IDs
- duplicate events do not duplicate story effects
- story snapshot save/load preserves records exactly
- old save without story field loads successfully
- main scene instantiates with composed story systems

## Functional Playtest Results

Command:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase1b-playtest-report.json
```

Result from JSON report:

- Passed: true
- Result count: 166
- Failures: 0

Console note:

- The functional run still prints the pre-existing NPC freed-object script
  errors noted in earlier reports, but the JSON report passes.
- Godot still prints an `ObjectDB instances leaked at exit` warning for the
  headless runners.

## Risks And TODOs

- The region records are intentionally generic `pending_worldmark` records so
  this phase does not implement Gloam Hart quest content.
- The NPC spoken hook covers the current tutorial NPC interaction source.
  Generic town NPCs do not yet have a player dialogue interaction source.
- Region records are generated when a regional story fact is ingested; later
  story phases still need authored Worldmark selection, clue placement,
  overlays, quest stages, and aftermath.
- Existing world-signature baseline drift and NPC freed-object console errors
  remain separate known issues.
