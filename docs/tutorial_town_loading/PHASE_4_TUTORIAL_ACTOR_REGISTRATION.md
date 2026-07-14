# Phase 4 Tutorial Actor Registration

## Objective

Register tutorial actors once as ordinary NPCs from stable scenario data and the validated generated-town manifest. No actor may enter gameplay with guessed home coordinates, tutorial-only simulation privileges, or a profile repaired after spawn.

This phase follows Phase 4 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`. Generic tutorial orders and removal of the legacy intro hold APIs remain Phase 5 work.

## Branch And Commit

- Branch: `codex/vox-74-register-tutorial-actors`
- Implementation commit: `1971605` (`Register tutorial actors from town manifest`)
- Linear: `VOX-74`

## Production Contract

`TutorialSystem.tutorial_actor_scenarios()` now declares four separate concerns for each actor:

1. stable identity and presentation;
2. ordinary role, job, and capabilities;
3. semantic `homeKey` assignment;
4. optional initial generic order data.

Shared homes are explicit scenario assignments: Rowan, Sera, and Toma use home key 1; Niko and Lyra use home key 2; Mira uses home key 3. The player home remains manifest key 0.

Before body creation, `TutorialSceneBuilder.resolve_tutorial_actor_specs()` resolves every actor against the validated manifest. The resolved profile contains the exact manifest-owned home, porch, door, interior landing, interior bounds, route cells, stable home ID, door portal ID, town key, center, radius, and level. Missing or invalid assignments fail startup structurally before any actor body is created.

`spawn_tutorial_npcs()` registers each body once through `NpcSystem.register_npc()`. Nearby safe placement may adjust only the initial physical pose; it cannot rewrite the semantic home profile. The former production coordinate fallback and post-spawn home refresh pass have been removed.

Registration readiness now compares every registered actor profile to the manifest before gameplay can start. A mismatch fails with `tutorial_npc_manifest_profile_mismatch` rather than being repaired silently.

## Ordinary NPC Parity

- Tutorial presentation identity no longer implies `requiredVisibleScripted`.
- The tutorial role no longer selects a privileged schedule resource or fallback schedule.
- Canonical roles drive ordinary schedules: Civilian, Carpenter, Forager, and Guard.
- Generated-town NPC registration now carries the same `homeKey`, stable home ID, and door portal ID fields.
- Tutorial identity is not part of the NPC profile. The body carries only the story-layer `story_actor_scope=tutorial` presentation tag used by dialogue and quest orchestration.
- No actor-ID checks were added to generic NPC simulation code.

The Phase 5 legacy `holdIntroDoor` field remains temporarily for sequential compatibility. It does not alter the actor's manifest home, collision, route authority, or schedule contract, and Phase 5 owns its removal.

## Test Coverage

### Focused Contracts

```powershell
.\tools\run-project-compile-smoke.ps1 `
  -ReportPath artifacts\test-runners\project-compile-vox74-final.json

.\tools\run-tutorial-actor-registration-contract-tests.ps1 `
  -ReportPath artifacts\test-runners\tutorial-actor-registration-vox74-final.json

.\tools\run-startup-loading-readiness-contract-tests.ps1 `
  -ReportPath artifacts\test-runners\startup-readiness-vox74-final.json
```

Results:

- Compile smoke: passed.
- Tutorial actor registration: 7/7 passed.
- Startup readiness: 6/6 passed.
- Missing manifest home assignment fails before body creation.
- Generic generated-town registration retains a complete ordinary profile.
- Story presentation scope does not enter the generic NPC profile or change collision, motor, schedule, or LOD pin behavior.
- Static audit found no production home refresh, coordinate fallback, or tutorial schedule privilege.

### NPC And Registry Contracts

```powershell
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both `
  -ReportPath artifacts\test-runners\npc-contract-vox74-final.json

.\tools\test-evidence-registry-self-test.ps1
```

Results:

- NPC contract: 74 runs, 214 assertions, 0 failures.
- Evidence registry: 3/3 passed.
- The new runner is registered as contract evidence and makes no live-gameplay acceptance claim.

### Production New Game And Continue

```powershell
.\tools\run-main-menu-startup-readiness-smoke.ps1 `
  -ReportPath artifacts\test-runners\main-menu-startup-vox74.json

.\tools\run-main-menu-continue-readiness-smoke.ps1 `
  -ReportPath artifacts\test-runners\main-menu-continue-vox74.json
```

| Run | Result | Elapsed | Longest step | Domains | Actors | Profile mismatches |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| New Game | Passed | 65.86 s | 18.08 s | 19 | 6/6 | 0 |
| Continue | Passed | 95.19 s | 25.81 s | 19 | 6/6 | 0 |

The Continue report resolved and spawned all six actors from a ready four-home manifest. It retained four stable door portal IDs, reported zero resolution problems, and enabled physics for all six actors only after readiness.

The variable synchronous `tutorial_scene` startup stall remains tracked by `VOX-80`. This phase does not treat long elapsed time as actor-registration success, and it does not weaken readiness to improve timing.

## Behavior Suite Audit

The full behavior suite has four failing scripted-motion cases that expect calls to the removed legacy `NpcSystem.move_npc` loop. The focused normal-speed case reproduced identically on clean Phase 3 commit `914371b9` and on this branch:

```text
moveCalls=0
maxDistance=0.0000
assertions=2
failures=1
```

Production scripted movement uses `NpcPlanExecutor._execute_scripted_go_to_route_v2()` and Route Authority V2. Reintroducing the direct movement loop would violate the one-authority pathfinding architecture. `VOX-82` tracks replacing the four stale assertions with route lease, shared motor, profile-speed, and per-actor motion-tick evidence.

## Residual Phase Scope

- Phase 5 (`VOX-75`) owns generic wait/go-home orders and deletion of Mira/intro-specific movement APIs.
- Phase 6 (`VOX-76`) owns old-save migration, order persistence, repeated Continue idempotency, and completed-tutorial compatibility.
- Phase 7 (`VOX-77`) owns unflagged headed live New Game/tutorial acceptance and performance evidence.
- Phase 8 (`VOX-78`) owns compatibility cleanup, release verification, final documentation, and parent closure.
- `VOX-80` and `VOX-82` remain separately tracked and visible.

## Exit Decision

- All tutorial actors resolve manifest homes before spawn: yes
- Missing semantic home can enter gameplay: no
- Actors register once through the ordinary NPC contract: yes
- Runtime home refresh remains in production: no
- Generated-town NPC registration still passes: yes
- Tutorial identity changes collision, routing, LOD, or schedule behavior: no
- Live Mira return-home acceptance claimed by this phase: no
- Phase 4 tutorial actor registration: passed
- Next sequential phase: Phase 5, `VOX-75`
