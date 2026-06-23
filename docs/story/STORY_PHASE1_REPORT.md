# Story Phase 1 Report

Phase 1 added story canon documentation and an isolated story test harness. It
does not add runtime story progression.

## Changed Files

- `docs/story/STORY_CANON.md`
- `docs/story/STORY_DATA_CONTRACTS.md`
- `docs/story/FIRST_WORLDMARK_ARC.md`
- `docs/story/STORY_PHASE1_REPORT.md`
- `scenes/story_testing/StoryPlaytest.tscn`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `tools/story/run-story-playtest.ps1`

`artifacts/story/` was already ignored from Phase 0 and remains the local output
location for story reports and captures.

## New Story System Responsibilities

No production story system was added in this phase.

New documentation responsibilities:

- `STORY_CANON.md` defines tone, player identity, Worldmark constraints,
  civilization/wilderness framing, and prose-generation prohibitions.
- `STORY_DATA_CONTRACTS.md` defines initial event, region, quest, settlement,
  save, and generated-text cache contracts.
- `FIRST_WORLDMARK_ARC.md` defines The Storm That Stays and The Gloam Hart,
  including clues, preparation direction, slay/release outcomes, and aftermath.

New test harness responsibilities:

- `StoryPlaytestRunner.gd` bootstraps independently from `PlaytestRunner.gd`.
- It verifies key project scripts can load.
- It instantiates `Main.tscn` with `VOXEL_STORY_PLAYTEST=1` and
  `VOXEL_PLAYTEST=1`.
- It verifies the story artifacts directory can be written.
- It writes a JSON report and exits with `0` on success or `1` on failure.

## Event Hooks Added

None.

Phase 1 intentionally adds no source-operation hooks. Future phases should emit
story events from gameplay sources such as tutorial completion, discovery,
crafting, item acquisition, placement, and explicit interactions. No events
should be emitted from HUD polling.

## Save/Load Behavior

No save fields were added.

`SAVE_VERSION` remains `1`. Existing save/load behavior is unchanged. The story
data contract documents a future optional `story` field, but this phase does not
write or restore it.

## Deterministic Test Results

Story playtest:

```powershell
.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase1-story-playtest-report.json
```

Result:

- Passed: true
- Result count: 5
- Failures: 0
- Checks:
  - `story_runner_bootstraps`
  - `project_scripts_load`
  - `main_scene_story_test_mode_instantiates`
  - `story_artifacts_directory_writable`
  - `story_runner_exit_code_policy`

World signature:

```powershell
.\tools\run-world-signature.ps1
```

Result:

- Current output is deterministic across two fresh runs.
- Current hash:
  `D594F8D5DBECD06B1BE2BB81F83475AE0960C4EC08B05CF57AC5473ADABD5C9C`
- Repeat hash:
  `D594F8D5DBECD06B1BE2BB81F83475AE0960C4EC08B05CF57AC5473ADABD5C9C`
- Stored baseline hash:
  `3ADEDAECFEF7DBE341AF66B70CED23C6AC9B55E8B89D9D6E4B92D2C1439D3896`
- The wrapper reports a baseline mismatch because the tracked baseline differs
  from current generated prop records. Phase 1 did not touch production
  generation code, so the baseline was not updated in this phase.

## Functional Playtest Results

Command:

```powershell
.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase1-playtest-report.json
```

Result from JSON report and `playtest-progress.txt`:

- Passed: true
- Result count: 166
- Failures: 0
- Runner progress: `finished`
- Runner elapsed: 21.350 seconds

Console note:

- The unredirected shell command produced repeated pre-existing NPC freed-object
  script errors and the shell tool timed out after the JSON report had already
  been written.
- A rerun also wrote a passing JSON report, but redirecting the wrapper output
  caused PowerShell to treat Godot's shutdown `ObjectDB instances leaked`
  warning on stderr as a native-command error. The report itself remained
  passing.

## Risks And TODOs

- The tracked world-signature baseline no longer matches current deterministic
  output. Current output is stable across repeated runs, so this appears to be
  baseline drift rather than run-to-run nondeterminism. Decide separately
  whether to refresh the baseline.
- Full playtest console output includes repeated existing NPC freed-object
  errors around pending door closes and forager targets. The suite reports pass,
  but those errors should be fixed in a focused gameplay maintenance change.
- Godot still prints an `ObjectDB instances leaked at exit` warning for these
  headless runners.
- The story harness currently tests only Phase 1 bootstrap requirements. It
  does not yet test region IDs, event dedupe, story save data, quest state, or
  Worldmark generation; those belong to later phases.
