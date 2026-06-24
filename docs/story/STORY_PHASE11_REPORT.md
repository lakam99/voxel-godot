# Story Phase 11 Report

## Changed files

- `scripts/story/data/WorldmarkDefinition.gd`
- `scripts/story/data/WorldmarkTraitCatalog.gd`
- `scripts/story/WorldmarkCompatibilityRules.gd`
- `scripts/story/WorldmarkGenerator.gd`
- `scripts/story/RegionStoryGenerator.gd`
- `scripts/story/StoryDirector.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE11_REPORT.md`

## New story system responsibilities

- `WorldmarkTraitCatalog` formalizes the allowed movement, attack, defense, condition, and resolution families.
- `WorldmarkDefinition` owns authored, concept-first definitions for `gloam_hart`, `mire_bloom_colossus`, and `cinderwing_ember`.
- `WorldmarkCompatibilityRules` validates that definition traits match the conceptual core instead of independent trait rolls.
- `WorldmarkGenerator` chooses a Worldmark definition from concept and biome context, then emits a complete regional Worldmark record.
- `RegionStoryGenerator` now uses `WorldmarkGenerator` for region-specific Worldmark records instead of creating `pending_worldmark` trait soup.
- `StoryDirector.mark_gloam_hart_region()` now applies the reusable Gloam Hart definition while preserving existing durable state fields.

## Event hooks added

- No new event hooks were added in Phase 11.
- Existing source-operation hooks for tutorial completion, region entry, clue discovery, countermeasure preparation, boundary retuning, and Worldmark resolution are unchanged.
- HUD polling still does not emit story events.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Phase 11 adds optional static Worldmark metadata inside existing `story.regionRecords[regionId].worldmark` records.
- Existing durable fields are preserved when applying the Gloam Hart definition: `foundClueIds`, `preparationFlags`, `encounterState`, `resolution`, and `aftermathState`.
- Old saves without `story` still load with empty story defaults.
- Beacon, rift, sanctuary, tutorial, objective, contract, visual, animation, and base save/load behavior are unchanged.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase11-story-playtest-report.json`
- Result: passed, 41 results, 0 failures.
- Added focused story tests for trait catalog coverage, definition compatibility, concept-first swamp/ember generation, and Gloam Hart first-arc data contract preservation.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase11-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- The fungal/swamp and flying ember Worldmarks are data prototypes only. They do not yet have overlay placement, quest chains, encounter scenes, rewards, or aftermath runtime systems.
- The first Gloam Hart encounter still uses its dedicated controller and scene; reusable encounter components should only be extracted when another Worldmark shares real behavior.
- Regional Worldmark metadata is now richer, so future tests should keep transient-state assertions scoped to `encounterState` rather than scanning entire story snapshots for trait names.
- Broad playtest still prints existing shutdown warnings from unrelated NPC door cleanup/ObjectDB leak paths; the JSON report passes with 0 failures.
