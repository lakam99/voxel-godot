# Story Phase 3 Report

## Changed files

- `scripts/story/data/RegionStoryRecord.gd`
- `scripts/story/data/WorldmarkState.gd`
- `scripts/story/RegionStoryGenerator.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE3_REPORT.md`

## New story system responsibilities

- `RegionStoryRecord` validates and normalizes the existing dictionary-backed regional story record format.
- `WorldmarkState` validates and normalizes the existing dictionary-backed Worldmark state format.
- `RegionStoryGenerator` now returns normalized region records with `schemaVersion`, `generationVersion`, deterministic region coordinates, seed, biome, Worldmark state, settlement state, and generated text.
- `StoryDirector` already owns snapshot, restore, reset, dedupe, event counts, region records, and campaign shell state from earlier work; this phase makes that baseline explicit and test-covered.

## Event hooks added

- No new event hooks were added for Phase 3.
- Phase 3 is persistence and deterministic record infrastructure only.
- Restore remains data reconstruction; it does not replay story events or duplicate progression.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- `MainSaveState` already stores optional `story` data through `StoryDirector.snapshot()`.
- Old saves without `story` still restore to empty/default story state.
- Generated region records are persisted once created and are not silently regenerated during restore.
- Reset clears runtime story records, dedupe keys, debug events, and event counts.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase3-story-playtest-report.json`
- Result: passed, 42 results, 0 failures.
- Added focused validation for normalized region/worldmark records, exact restore round trip, reset clearing, and restore not duplicating event counts or dedupe keys.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase3-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- Region and Worldmark state remain dictionary-backed by design to preserve the existing save shape and later phase code.
- The broad playtest provides the terrain/town signature guard for this corrective phase; story generation uses its own deterministic hash stream and does not consume terrain, town, structure, prop, hostile, or loot RNG.
- Broad playtest still prints existing shutdown warnings from unrelated NPC door cleanup/ObjectDB leak paths; the JSON report passes with 0 failures.
