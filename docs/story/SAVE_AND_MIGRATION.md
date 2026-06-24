# Story Save And Migration

The project save format remains `SAVE_VERSION = 1`. Story data is optional and nested under the existing save snapshot.

## Current Story Save Shape

`MainSaveState.create_save_snapshot()` writes:

```text
story.schemaVersion
story.campaign
story.campaignSpine
story.regionRecords
story.quests
story.settlements
story.processedDedupeKeys
story.generatedText
story.debugRecentEvents
story.eventCounts
story.currentStoryRegionId
```

All story fields are optional. Loading an older save with no `story` field restores an empty story director and keeps the rest of the save valid.

## Migration Rules

- Do not increment `SAVE_VERSION` for optional story additions.
- New story fields must have defensive defaults in `StoryDirector.restore()` or the owning system restore method.
- Do not move existing gameplay fields into story data.
- Do not serialize transient encounter details such as animation state, elapsed timers, active projectiles, temporary minions, or HUD state.
- Region story records should remain deterministic by seed and region id. Save only player-discovered or player-changed deltas.
- Generated prose is optional cache data under `story.generatedText`; gameplay logic must not depend on it.

## Tutorial Handoff

Older completed-tutorial saves are migrated by `ensure_story_handoff_for_completed_tutorial_save()`. If the tutorial final rescue is complete and the first story quest is absent, the loader emits the same source event used by the tutorial completion path:

```text
tutorial_final_rescue_complete
```

This keeps the transition into `The Storm That Stays` deterministic without hand-editing saves.

## Encounter Recovery

Worldmark encounters write durable recovery state to the affected region record:

```text
regionRecords[regionId].worldmark.encounterState.status
regionRecords[regionId].worldmark.encounterState.phase
regionRecords[regionId].worldmark.encounterState.entrancePosition
regionRecords[regionId].worldmark.encounterState.resolution
```

On load, `WorldmarkEncounterController.recover_after_load()` rebuilds the active encounter from durable state and moves the player to a safe recovery position.

## Compatibility Checklist

- Load a save with no `story` field.
- Save/load after every quest stage.
- Save/load during an active encounter.
- Save/load after slay and release resolutions.
- Confirm dedupe keys prevent repeated rewards and repeated story events.
- Confirm generated prose cache can be cleared without changing quest state.
