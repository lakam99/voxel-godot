# Phase 6 Save, Continue, And Compatibility

## Objective

Preserve the tutorial town's generated-home authority and ordinary NPC orders across Save and Continue. A save may record durable semantic state, but it must never become an alternate source of world topology, actor placement, routes, or movement authority.

This report follows Phase 6 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`.

## Branch And Commit

- Branch: `codex/vox-76-save-continue-compatibility`
- Implementation commit: `c4e91a2` (`Preserve tutorial NPC intent through Continue`)
- Linear: `VOX-76`

## Production Contract

`TutorialTownSaveContract` is an additive save field under `tutorial.saveContract`.

- The town manifest is regenerated from the normal seed-driven startup path on Continue. The save stores only a manifest reference: schema version, town key, seed, generation revision, and each actor's stable home/door identity.
- Existing durable NPC facts carry the same semantic home identity (`homeKey`, `homeStableId`, `doorPortalId`) but no route request, route lease, probe, position correction, or movement state.
- Continue validates the saved reference and durable assignment against the regenerated startup authority. A mismatch is reported; it does not overwrite regenerated homes, door records, or player world edits.
- A missing `saveContract` is a normal additive-schema migration. The intro state derives one semantic intent from existing tutorial facts: `wait`, `go_home`, or `resume_schedule`.
- Restore retains an equivalent generic order, reissues `order_go_home(..., "tutorial_knock_complete")` only when no equivalent order is active, and resumes the ordinary schedule after strict interior arrival. Repeated reconciliation is idempotent.

No saved route or named tutorial movement behavior is replayed. `TutorialSystem` owns only tutorial facts and submits the existing generic order APIs through `NpcSystem`.

## Focused Verification

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\run-tutorial-save-compatibility-contract-tests.ps1 `
  -ReportPath artifacts\tutorial-town\tutorial-save-compatibility-contract-vox76.json
.\tools\npc\assert-npc-acceptance-runner-clean.ps1 `
  -RunnerPath scripts\testing\npc\NpcTutorialSaveContinueRunner.gd `
  -ReportPath artifacts\npc\reports\tutorial-save-continue-vox76.json `
  -TestId npc_tutorial_save_continue_playtest
```

Results:

- Compile smoke: passed.
- Save compatibility contract: 7/7 passed.
- Acceptance static guard: passed with zero forbidden calls.

The contract coverage proves deterministic reference validation, legacy migration, durable-home semantic state with no route transient, retained wait, one-time generic home reissue, post-arrival schedule resume without knock replay, and mismatch reporting without mutation of regenerated assignments.

## Headed Save And Continue Evidence

```powershell
.\tools\npc\run-tutorial-save-continue-playtest.ps1 `
  -ReportPath artifacts\npc\reports\tutorial-save-continue-vox76.json `
  -SavePathOverride artifacts\npc\saves\tutorial-save-continue-vox76.json `
  -TimeoutSeconds 360 -StaleProgressSeconds 90
```

This is an `integration` test, not an unflagged acceptance claim. It launches two real headed Godot processes:

1. Main Menu -> New Game -> physical player door/dialogue input -> save through the production `SaveSystem`.
2. Fresh Main Menu -> Continue -> passive observation of real NPC physics.

The only override is `VOXEL_SAVE_PATH_OVERRIDE`, explicitly scoped to isolate real SaveSystem files. `VOXEL_PLAYTEST` and `VOXEL_TEST_SEED` are unset; there is no teleport, direct tutorial progression, direct NPC movement, mocked route, or gameplay flag.

Seed: `atlas-76849299`

| Measure | Result |
| --- | ---: |
| Saved post-ack intent | `go_home`, `tutorial_knock_complete` |
| Restored order | generic `go_home`, active |
| Continue porch clearance | 1.600 s |
| Strict home arrival | true |
| Stage reports | passed |

Evidence:

- Aggregate: `artifacts/npc/reports/tutorial-save-continue-vox76.json`
- New Game stage: `artifacts/npc/reports/tutorial-save-continue-stage-new-game.json`
- Continue stage: `artifacts/npc/reports/tutorial-save-continue-stage-continue.json`
- New Game captures: `artifacts/npc/screenshots/tutorial-save-continue-stage-new-game/`
- Continue captures: `artifacts/npc/screenshots/tutorial-save-continue-stage-continue/`

Manual capture review confirmed the actual Main Menu/New Game and Main Menu/Continue transitions plus the in-game acknowledgement state. The fixed player camera is occluded by the house model after Continue, so it does not visually establish Mira's final interior position. The final-arrival claim in this phase comes from the real `CharacterBody3D` physics observation timeline and strict-interior predicate, not from that camera frame. Phase 7 must provide clearer observer framing for live acceptance.

## Regression Checks And Residual Failure

```powershell
.\tools\npc\run-npc-streaming-save-tests.ps1 -TimeMode Both
.\tools\run-world-signature.ps1
```

The streaming/save suite passed 38 of 40 runs and 90 of 92 assertions. The two failures are the day/night copies of `npc_save_world_signature_unchanged`; the direct world-signature command also failed.

Both compare the current `atlas-1492` generated world with `artifacts/baselines/world-signature/atlas-1492.json`. The current output differs in town block positions, elevations, and material types. Phase 6 does not modify terrain generation, structure generation, or the baseline, so this is recorded as an unrelated generated-world regression. The baseline was not changed to hide it.

This failure blocks a claim that the broad streaming/save suite is fully green. It does not invalidate the seven save-contract cases or the headed Save/Continue flow above. Its terrain-owner diagnosis belongs outside this focused phase and must be tracked before final release closure.

## Exit Decision

- Additive save contract: yes.
- Deterministic manifest regeneration with validation: yes.
- Valid saved home identity preserved without replacing regenerated authority: yes.
- Legacy save without manifest contract: passes semantic migration.
- Pre-ack wait, post-ack home, and post-arrival schedule behavior: covered and idempotent.
- Duplicate NPCs, doors, dialogue, rewards, or order replays: none observed in focused contract or headed flow.
- Headed post-ack Save/Continue flow: passed; porch clearance 1.600 seconds and strict home true.
- Broad streaming/save suite: not fully green due unrelated world-signature drift; baseline left unchanged.
- Phase 6: complete with the above residual recorded.
- Next sequential phase: Phase 7, `VOX-77`.
