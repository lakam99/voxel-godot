# Story Phase 14 Report

Phase 14 adds story polish, accessibility, authoring/debug tools, validation, documentation, and release gates. It keeps story systems composed as nodes, keeps `SAVE_VERSION` at `1`, and does not add story progress from HUD polling.

## Changed Files

- `scripts/MainInterface.gd`
- `scripts/MainCore.gd`
- `scripts/MainDiscoveryFlow.gd`
- `scripts/MainHudFlow.gd`
- `scripts/MainSaveState.gd`
- `scripts/GameHud.gd`
- `scripts/GameHudLayoutBuilder.gd`
- `scripts/GameHudOverlayController.gd`
- `scripts/GameHudPanelBuilder.gd`
- `scripts/GameHudRenderer.gd`
- `scripts/story/StoryAccessibilitySettings.gd`
- `scripts/story/StoryInteractable.gd`
- `scripts/story/StoryJournalModel.gd`
- `scripts/story/StoryWorldOverlaySystem.gd`
- `scripts/story/encounters/WorldmarkEncounterController.gd`
- `scripts/story/tools/StoryDebugTools.gd`
- `scripts/story/tools/StoryAuthoringValidator.gd`
- `scripts/story/testing/Phase14StoryPolishTests.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/ADDING_A_WORLDMARK.md`
- `docs/story/SAVE_AND_MIGRATION.md`
- `docs/story/STORY_PHASE14_REPORT.md`

## New Story System Responsibilities

- `StoryAccessibilitySettings`: composed runtime node for story text speed, subtitles, journal font scale, color-independent clue labels, replayable discovered text, and controller navigation.
- `StoryDebugTools`: debug/playtest-only composed node for authoring commands. It can jump quest stages, reveal clues, enter regions, start encounters, choose resolutions, advance aftermath days, dump region records, and clear generated prose cache.
- `StoryAuthoringValidator`: validates Worldmark definitions, text keys, animation states, clue site coverage, trait compatibility, fallback text coverage, and first-arc pacing.
- `Phase14StoryPolishTests`: dedicated story test helper so the broad `PlaytestRunner` remains unchanged.

## Event Hooks Added

- No new normal gameplay source hooks were required.
- Debug-only commands reuse existing story systems and existing source event types where useful, especially `story_clue_found` and `story_region_entered`.
- HUD polling still does not emit story events.

## Save/Load Behavior

- `SAVE_VERSION` remains `1`.
- Accessibility settings are runtime settings, not save data.
- Debug tools add no save fields.
- Generated prose remains optional story data under `story.generatedText`; debug tools can clear the narrative cache without changing quest state.
- Existing story save/load coverage still passes for old saves without story data, quest state, region records, and active encounter recovery.

## Deterministic Test Results

- Story suite: `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase14-story-playtest-report.json`
  - Passed: `true`
  - Results: `47`
  - Failures: `0`
  - Includes both Gloam Hart slay and release resolution playthroughs.
- Functional suite: `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase14-playtest-report.json`
  - Passed: `true`
  - Results: `166`
  - Failures: `0`
- Visual captures: `.\tools\run-visual-captures.ps1 -OutputDir artifacts\visual\phase14`
  - Cases: `10`
  - PNGs: `10`

## Playtest Result Count/Failures

- Dedicated story playtest: `47` results, `0` failures.
- Full functional playtest: `166` results, `0` failures.

## Risks And TODOs

- The broad functional suite still logs pre-existing NPC freed-instance warnings from `NpcSystem.update_forager_goal`; the JSON playtest report passes.
- The optional local LLM path remains disabled by default and is not required.
- Additional generated Worldmark definitions are validated and documented, but only the Gloam Hart has a bespoke encounter implementation in this milestone.
- Journal replay entries are authored summaries of discovered text, not a full transcript archive.
