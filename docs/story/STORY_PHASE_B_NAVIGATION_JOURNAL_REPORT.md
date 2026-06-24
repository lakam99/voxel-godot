# Story Phase B Navigation And Journal Report

Date: 2026-06-24

## Scope

Implemented Phase B only: navigation and journal clarity for the existing Gloam Hart first arc.

No new Worldmarks, campaign content, boss mechanics, rewards, aftermath behavior, generated art assets, save schema changes, or HUD polling story events were added.

## Changed Files

- `scripts/story/StoryJournalModel.gd`
  - Added derived waypoint, progress, preparation, and optional-history journal rows.
  - Kept `affectedRegionId` in journal state for debug/save compatibility, but added player-readable direction and distance text for the visible journal.
- `scripts/GameHudRenderer.gd`
  - Renders new `Waypoint`, `Progress`, and `Countermeasure` sections.
  - Removed the raw `Region: r:x,z` line from the main visible story journal.
  - Added accessibility prefixes for waypoint, boundary-stone, and preparation rows.
- `scripts/story/testing/StoryPlaytestRunner.gd`
  - Added deterministic Phase B journal coverage across the requested first-arc states.
- `docs/story/STORY_PHASE_B_NAVIGATION_JOURNAL_REPORT.md`
  - This report.

## Journal Behavior

- The travel stage now reads `Travel to the storm waypoint`.
- The visible waypoint row gives a direction and region-distance hint, for example:
  - `Storm waypoint: Follow the fixed forest storm north-east from town (1 region east, 1 region north).`
- After the player reaches the affected region, the waypoint row switches to a local search hint:
  - `Storm waypoint reached; search the forest region for signs, stones, and the hollow.`
- The raw affected region ID remains in `StoryJournalModel.state()["affectedRegionId"]` for existing debug/test consumers, but it is no longer rendered as the main player-facing travel hint.
- The `Progress` section now includes:
  - `Ordinary clues: N found, N remaining to prepare`
  - `Boundary stones: N retuned, N remaining`
- The `Countermeasure` section now explicitly lists:
  - `Survey Lens`
  - `Ward Lantern`
  - `Night Shard charge`
- The optional-history row now reads:
  - `Old compact record: may reveal another way to resolve the Hart`
- Before the historical clue is found, hidden truth dossier rows remain `???`.
- After the historical clue is found, the existing hidden-truth row is revealed through the same `historyClueFound` gate as before.

## Tests

Added deterministic story test:

- `phase_b_navigation_and_journal_clarity`

Covered states:

- Quest start.
- Mira handoff.
- Sera handoff.
- Affected region selection with non-raw waypoint text.
- One ordinary clue found.
- Two ordinary clues found.
- Historical clue not found.
- Historical clue found.
- One boundary stone retuned.
- Both boundary stones retuned.

Verification:

- Story suite:
  - Command: `.\tools\story\run-story-playtest.ps1 -ReportPath .\artifacts\story\phase-b-navigation-journal-story-playtest-report.json`
  - Passed: true
  - Results: 49
  - Failures: 0
- Functional playtest:
  - Command: `.\tools\run-playtest.ps1 -ReportPath .\artifacts\story\phase-b-navigation-journal-functional-playtest-report.json`
  - Passed: true
  - Results: 172
  - Failures: 0
- Diff hygiene:
  - `git diff --check` passed with only existing CRLF normalization warnings.

## Save And Event Behavior

- `SAVE_VERSION` remains `1`.
- No saved story payload shape was changed.
- New journal rows are derived from existing quest facts, region data, and inventory counts.
- No story events are emitted from HUD rendering or journal polling.
- NPC dialogue and hidden-truth knowledge scopes are unchanged.

## Risks / TODOs

- The waypoint is textual only. There is still no map marker, compass pin, or world-space beacon for the affected storm region.
- Countermeasure rows can show item availability, but they do not explain where to craft or acquire each item.
- Ordinary clue progress uses the two required clues for preparation while also noting remaining undiscovered regional clues; this is clearer than before, but a dedicated clue tracker would be better once story-site presentation improves.
