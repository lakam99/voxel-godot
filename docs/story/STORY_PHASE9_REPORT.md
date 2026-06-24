# Story Phase 9 Report

## Changed files

- `scenes/story/GloamHartEncounter.tscn`
- `scripts/MainCore.gd`
- `scripts/MainInterface.gd`
- `scripts/MainPropFactory.gd`
- `scripts/MainSaveState.gd`
- `scripts/MainSetupScene.gd`
- `scripts/PlayerProjectileSystem.gd`
- `scripts/story/StoryJournalModel.gd`
- `scripts/story/StoryQuestSystem.gd`
- `scripts/story/StoryWorldOverlaySystem.gd`
- `scripts/story/encounters/GloamHartEncounter.gd`
- `scripts/story/encounters/WorldmarkEncounterController.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE9_REPORT.md`

## New story system responsibilities

- `WorldmarkEncounterController` is a composed story node under `Main`, not a new `Main*.gd` inheritance layer.
- The controller starts the Gloam Hart from the existing encounter marker once both boundary stones are retuned.
- The controller owns durable encounter state, phase state, rewards, idempotent resolution, load recovery, and cleanup.
- `GloamHartEncounter` owns the active fight node: health, three-phase behavior, readable charge/sweep/pulse/vulnerable states, minion cleanup, slay, and release attempts.
- `GloamHartEncounter.tscn` uses a procedural fallback visual and animation-state fallback because no dedicated Gloam Hart animated asset exists yet.
- `StoryQuestSystem` now completes the first arc after `slay` or `release` and stores resolution facts.
- `StoryJournalModel` displays post-resolution status.

## Event hooks added

- `story_worldmark_encounter_started`
  - Emitted only when the encounter marker starts the active Worldmark encounter.
- `story_worldmark_encounter_phase`
  - Emitted by the encounter controller when the fight reaches a new saved phase.
- `story_worldmark_resolved`
  - Emitted by the encounter controller after `slay` or `release` grants rewards and writes durable region state.
- Melee and ranged Worldmark damage are source-operation hooks. HUD refresh/polling does not emit story events.
- Ranged Worldmark hits use a dedicated projectile signal so they do not award hostile XP or overwrite story messages through the hostile-hit path.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Encounter state is optional story data only, under `story.regionRecords[regionId].worldmark.encounterState`.
- Active encounter saves include only durable status, phase, entrance position, recovery flag, and resolution.
- Raw animation time, projectile state, and transient minion state are not saved.
- Loading an active encounter reconstructs the Gloam Hart at the start of the saved phase and moves the player to a nearby recovery position.
- Resolved Worldmarks are immutable; repeated resolution calls do not duplicate rewards.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase9-story-playtest-report.json`
- Result: passed, 36 results, 0 failures.
- Added focused story tests for phase progression, countermeasure pulse reduction, animation fallback, slay rewards, release gating, release rewards, save/load recovery, cleanup, and reward idempotency.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase9-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- The Gloam Hart visual is a procedural fallback. A dedicated generated animated asset can replace it later without changing encounter save data.
- Phase behavior is deterministic and test-covered, but full player-facing balance still needs manual tuning for damage cadence, telegraph timing, and arena readability.
- Broad playtest still prints existing shutdown warnings from unrelated NPC door cleanup/ObjectDB leak paths; the JSON report passes with 0 failures.
