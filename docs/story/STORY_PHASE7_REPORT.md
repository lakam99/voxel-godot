# Story Phase 7 Report

Phase 7 adds a readable investigation surface and scoped NPC story reactions.
The story journal is a dedicated `L` panel built into the existing HUD/theme,
while contracts remain on `J` and objectives remain on `O`.

This phase does not add encounter mechanics, countermeasure crafting,
boundary-stone retuning, rewards, aftermath, or another `Main*.gd` inheritance
layer.

## Changed Files

- `docs/story/STORY_PHASE7_REPORT.md`
- `scripts/GameHud.gd`
- `scripts/GameHudLayoutBuilder.gd`
- `scripts/GameHudRenderer.gd`
- `scripts/MainCore.gd`
- `scripts/MainInterface.gd`
- `scripts/MainRuntimeTools.gd`
- `scripts/MainSetupScene.gd`
- `scripts/MainWorldEntities.gd`
- `scripts/TutorialDialogueSystem.gd`
- `scripts/story/StoryDialogueRouter.gd`
- `scripts/story/StoryJournalModel.gd`
- `scripts/story/data/NpcKnowledgeScope.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`

## Story System Responsibilities

- `StoryJournalModel` derives the visible journal state from `StoryDirector`
  and the active Gloam Hart quest.
- `StoryDialogueRouter` returns stage-aware NPC responses and emits scoped
  `npc_spoken_to` events for generated residents.
- `NpcKnowledgeScope` defines personal observation, public rumor,
  player-shared clue, role-specific, and post-resolution knowledge scopes.
- `GameHud` owns the story panel state and renders it only when opened or when
  refreshed while visible.

## Journal Behavior

- `L` opens/closes the story journal.
- `J` remains contracts.
- `O` remains objectives.
- The journal shows the tracked quest, current stage, dossier, found clues,
  optional old-compact objective, known preparation, affected region, and
  settlement pressure.
- Hidden dossier fields use `???` until the player finds the historical clue.
- The journal is derived from saved story state; no extra save version or
  required save field was added.

## NPC Knowledge Behavior

- Mira, Sera, Rowan, and Niko get stage-aware story reactions after the first
  Worldmark quest is active.
- Generated residents can respond through the narrow story dialogue hook when
  they are directly interacted with.
- NPC responses carry knowledge scopes and do not reveal the hidden compact
  truth before the historical clue is found.
- Generic NPC fallback remains public rumor or role-specific observation.

## Event Hooks Added

- `MainRuntimeTools.use_or_place()` now checks `interact_story_dialogue_node()`
  before story interactables and ordinary block/placement fallback.
- Generic NPC story dialogue emits `npc_spoken_to` with a stable
  `story_npc_spoken:<npc_id>:<stage>` dedupe key and knowledge-scope payload.
- Tutorial NPC story reactions reuse the existing tutorial interaction path and
  do not emit events from HUD polling.

## Save/Load Behavior

- `SaveSystem.SAVE_VERSION` remains `1`.
- Journal state is derived from the existing optional `story` field.
- Old saves without story still load with no active investigation.
- Story tests verify journal state round-trips after save/load.

## Deterministic Test Results

Command:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase7-story-playtest-report.json
```

Result from JSON report:

- Passed: true
- Result count: 29
- Failures: 0

Phase 7 coverage includes hidden dossier filtering, tracked quest journal
state, NPC knowledge scopes, generic dialogue fallback, journal save/load, and
story panel bounds at `1280x720` and `1920x1080`.

## Functional Playtest Results

Command:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase7-playtest-report.json
```

Result from JSON report:

- Passed: true
- Result count: 166
- Failures: 0

## Risks And TODOs

- The story panel is functional and themed, but still text-only. Later phases
  may want icons, tabs, or richer dossier grouping.
- Generated resident dialogue is intentionally sparse and scoped; broader NPC
  personality variation should wait until the Worldmark framework is generalized.
- `WorldmarkInfluenceSystem` remains metadata-only from Phase 6, so the journal
  reports pressure without full weather/audio mechanical integration.
- Headless Godot playtests still print the existing `ObjectDB instances leaked
  at exit` warning; no Phase 7 assertions fail.
