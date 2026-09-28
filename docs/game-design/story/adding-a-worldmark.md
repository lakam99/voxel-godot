# Adding A Worldmark

This checklist keeps new Worldmarks compatible with the composed story framework and save format.

## Definition

- Add a definition in `scripts/story/data/WorldmarkDefinition.gd`.
- Give it a stable `id`, `arcId`, `titleId`, `displayNameId`, `publicBeliefId`, and `hiddenTruthId`.
- Fill `archetype`, `conceptCore`, `domain`, `condition`, `desire`, `regionalConsequence`, and `humanHistory`.
- Choose traits only from `WorldmarkTraitCatalog.gd`.
- Run `WorldmarkCompatibilityRules.validate_definition()` or the story authoring validator before committing.
- Keep at least two resolution families.
- Add ordinary and historical signs. A first playable arc needs at least two ordinary clues and one optional historical clue.

## Sites

- Add site definitions in `StorySitePlacement.gd`.
- Every clue sign in the definition needs a matching site definition.
- Each site needs `id`, `kind`, `label`, `prompt`, and a `story.*` `textId`.
- Boundary and encounter sites must remain deterministic from the region record seed.
- Site placement must avoid water, beach, town cells, high local variation, and tight clustering.
- Keep visual cues color-independent: different mesh silhouettes or `Label3D` cue text are required, not color alone.

## Quest And Event Flow

- Emit story progress from source operations only: NPC interaction, region entry, site interaction, crafting/trading/processing, encounter controller, or aftermath systems.
- Do not poll HUD state to advance quests.
- Add new stage constants to the relevant quest system and keep an explicit stage order.
- Save quest progress as optional `story.quests` data only.
- Add a debug command in `StoryDebugTools.gd` if authors need to jump to the new stage.

## Encounter

- Encounter state must be recoverable from saved region story records.
- Runtime-only fields such as animation state, elapsed time, active projectiles, or transient bodies should not be serialized.
- Every animation state referenced by logic needs a fallback entry and a deterministic safe state.
- Expose `debug_state()` and `performance_state()` with node counts and budget status.

## Text

- Local authored fallback text is mandatory.
- Optional LLM text must go through `NarrativeTextProvider` validation and deterministic template fallback.
- Do not reveal hidden truth unless the request explicitly allows hidden facts.
- Generated prose belongs under optional story save data and must be clearable through debug tools.

## Validation

Before merging, run:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase14-story-playtest-report.json
.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase14-playtest-report.json
.\tools\run-visual-captures.ps1 -OutputDir artifacts\visual\phase14
```

The authoring validator reports missing definitions, missing text keys, missing animation states, invalid clue site coverage, incompatible traits, and fallback text gaps.
