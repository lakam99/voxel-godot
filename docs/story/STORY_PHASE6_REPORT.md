# Story Phase 6 Report

Phase 6 adds the first in-world Gloam Hart investigation layer. It places
deterministic story sites in the affected region, spawns them only while the
player is in that unresolved region, emits story events from direct interaction,
and keeps the regional influence as removable story state.

This phase does not add the Worldmark encounter, countermeasure crafting,
boundary-stone retuning, rewards, aftermath, new generated art assets, or a new
`Main*.gd` inheritance layer.

## Changed Files

- `docs/story/STORY_PHASE6_REPORT.md`
- `scenes/story/StoryInteractable.tscn`
- `scripts/MainCore.gd`
- `scripts/MainInterface.gd`
- `scripts/MainRuntimeTools.gd`
- `scripts/MainSaveState.gd`
- `scripts/story/StoryInteractable.gd`
- `scripts/story/StoryQuestSystem.gd`
- `scripts/story/StoryWorldOverlaySystem.gd`
- `scripts/story/WorldmarkInfluenceSystem.gd`
- `scripts/story/data/StorySitePlacement.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`

## Story System Responsibilities

- `StorySitePlacement` deterministically chooses seven regional story sites:
  three ordinary clues, one optional historical clue, two boundary stones, and
  one encounter marker.
- `StoryWorldOverlaySystem` owns the spawned story interactables for the current
  affected region and clears them when the player leaves.
- `StoryInteractable` is a small `StaticBody3D` scene with fallback primitive
  visuals, metadata, and collision for story inspection.
- `WorldmarkInfluenceSystem` tracks removable Gloam Hart regional influence:
  rain bias, ambience tag, and hostile-pressure metadata while the unresolved
  affected region is active.
- `StoryQuestSystem` now treats any two ordinary clues as enough to advance to
  `prepare_countermeasure_placeholder`; the historical clue remains optional.

## Event Hooks Added

- `MainRuntimeTools.use_or_place()` now checks `interact_story_node(collider)`
  after tutorial NPC interaction and before ordinary block/placement fallback.
- Story interactables emit only on direct use:
  `story_clue_found`, `story_boundary_stone_discovered`, and
  `story_encounter_marker_found`.
- Dedupe keys use `story_site:<site_id>`, so repeated use does not duplicate
  director effects.
- HUD text is updated from authored site text after interaction; no story events
  are emitted from HUD polling.

## Save/Load Behavior

- `SaveSystem.SAVE_VERSION` remains `1`.
- Story data remains optional under the existing additive `story` save field.
- Region records now optionally include `storySitesVersion` and `storySites`.
- Old saves without `story` still load as empty story state.
- Save/load tests verify the selected site cells, optional history clue state,
  and release-route flag survive round trip.

## Deterministic Test Results

Command:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase6-story-playtest-report.json
```

Result from JSON report:

- Passed: true
- Result count: 24
- Failures: 0

Phase 6 coverage includes site validity, deterministic placement, saved site
records, overlay spawn/cleanup, regional influence enter/exit cleanup, ordinary
clue dedupe and progression, optional history state, boundary-stone events,
encounter-marker events, and old-save compatibility.

## Functional Playtest Results

Command:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase6-playtest-report.json
```

Result from JSON report:

- Passed: true
- Result count: 166
- Failures: 0

## Risks And TODOs

- Story site visuals are fallback primitives until an authored/generated story
  asset pass replaces them.
- `WorldmarkInfluenceSystem` currently exposes structured influence metadata but
  does not yet drive full weather, audio, or hostile tuning systems.
- Boundary stones emit discovery events only; retuning is still deferred to the
  boundary mechanics phase.
- The encounter marker remains locked and informational until the encounter
  phase.
- Headless Godot story runs still print the existing `ObjectDB instances leaked
  at exit` warning in some runs; no Phase 6 assertions fail.
