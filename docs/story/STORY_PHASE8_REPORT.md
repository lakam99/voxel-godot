# Story Phase 8 Report

## Changed files

- `scripts/MainCore.gd`
- `scripts/MainHudFlow.gd`
- `scripts/MainCharacterState.gd`
- `scripts/MainDiscoveryFlow.gd`
- `scripts/story/StoryQuestSystem.gd`
- `scripts/story/StoryWorldOverlaySystem.gd`
- `scripts/story/WorldmarkInfluenceSystem.gd`
- `scripts/story/StoryJournalModel.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE8_REPORT.md`

## New story system responsibilities

- `StoryWorldOverlaySystem` now owns boundary-stone retune interaction behavior for the first Gloam Hart arc.
- Existing `surveyLens` and `wardLantern` items are required and verified before retuning.
- Each successful stone retune consumes one `nightShard` through `InventorySystem.consume_costs`.
- No new countermeasure item was added; the existing item architecture is clear enough for the Phase 8 preparation loop.
- `StoryQuestSystem` now persists prepared countermeasure details, retuned stone IDs, storm weakening, encounter unlock, combat route, and release route availability.
- `WorldmarkInfluenceSystem` reads quest facts and reduces storm pressure after both stones are retuned.
- `StoryJournalModel` summarizes partial or complete boundary-stone preparation.

## Event hooks added

- `story_countermeasure_prepared`
  - Emitted from source operations when both `surveyLens` and `wardLantern` are present.
  - Hooked from crafting, utility processing, utility trades, dropped-pickup collection, contract rewards, and direct boundary-stone interaction.
- `story_boundary_stone_retuned`
  - Emitted only after a boundary-stone interaction verifies `surveyLens` and `wardLantern` and consumes a `nightShard`.
  - Uses stable stone IDs: `boundary_stone_north` and `boundary_stone_south`.
- HUD refreshes do not poll inventory to emit story events.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Phase 8 state is optional story data only, stored under the existing story snapshot.
- Retuned stone IDs, route flags, and storm weakening round-trip through existing story save/load.
- Old saves without a `story` field still load and reset story state through the existing missing-story path.

## Deterministic test results

- `tools/story/run-story-playtest.ps1 -ReportPath artifacts/story/phase8-story-playtest-report.json`
- Result: passed, 32 results, 0 failures.
- Added focused story tests for failed retune attempts, costs, duplicate stone interactions, persistence, storm weakening, history-clue gating, and old-save compatibility.

## Playtest result count/failures

- `tools/run-playtest.ps1 -ReportPath artifacts/story/phase8-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- Phase 8 unlocks the encounter stage but does not spawn the Gloam Hart encounter; Phase 9 owns encounter activation and resolution.
- The reduced storm is currently represented in story influence data. Applying that bias to fuller weather or hostile-spawn presentation can be expanded during the encounter phase.
- Tests isolate inventory and contracts for deterministic story assertions because normal contract rewards can add `nightShard`s when `wardLantern` appears.
